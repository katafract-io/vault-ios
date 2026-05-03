#!/usr/bin/env python3
"""Evaluate the release-readiness gates declared in .katafract/config.yaml.

Outputs a structured JSON document and a Markdown summary.

Each gate runs an evaluator and reports one of:
  - green     gate passed
  - yellow    gate failed but severity == warn (or check unimplemented)
  - red       gate failed and severity == blocker
  - deferred  gate's evaluator is not yet implemented (marked yellow)

The CI step that calls this script fails the run iff any blocker is red.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

import requests
import yaml


GH_API = "https://api.github.com"
ASC_API = "https://api.appstoreconnect.apple.com"


# ---------- helpers ---------------------------------------------------------


def gh_get(path: str, token: str) -> Any:
    r = requests.get(f"{GH_API}{path}", headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
    }, timeout=15)
    r.raise_for_status()
    return r.json()


def asc_jwt() -> str:
    """Mint a short-lived ASC JWT from env vars."""
    import jwt as pyjwt
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    private_key = os.environ["ASC_PRIVATE_KEY"]
    now = int(time.time())
    payload = {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    headers = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    return pyjwt.encode(payload, private_key, algorithm="ES256", headers=headers)


def asc_get(path: str, jwt: str) -> Any:
    r = requests.get(f"{ASC_API}{path}", headers={
        "Authorization": f"Bearer {jwt}",
    }, timeout=20)
    r.raise_for_status()
    return r.json()


# ---------- gate evaluators -------------------------------------------------


def gate_pr_check_main_green(cfg: dict) -> tuple[str, str]:
    return _gate_workflow_main_green(cfg, "pr-check.yml")


def gate_ship_yml_main_green(cfg: dict) -> tuple[str, str]:
    return _gate_workflow_main_green(cfg, "ship.yml")


def _gate_workflow_main_green(cfg: dict, workflow_filename: str) -> tuple[str, str]:
    repo = os.environ["GITHUB_REPOSITORY"]
    token = os.environ["GH_TOKEN"]
    runs = gh_get(
        f"/repos/{repo}/actions/workflows/{workflow_filename}/runs"
        f"?branch=main&per_page=5",
        token,
    )["workflow_runs"]
    if not runs:
        return "yellow", f"no runs found for {workflow_filename} on main"
    latest = runs[0]
    if latest["conclusion"] == "success":
        return "green", f"#{latest['run_number']} success ({latest['head_sha'][:7]})"
    return "red", f"#{latest['run_number']} {latest['conclusion']} ({latest['head_sha'][:7]})"


def gate_app_group_entitlement_present(cfg: dict) -> tuple[str, str]:
    file = cfg["ci"]["signing"].get("entitlements_file")
    groups = cfg["ci"]["signing"].get("app_groups", [])
    if not file:
        return "yellow", "no entitlements_file configured"
    p = Path(file)
    if not p.is_file():
        return "red", f"{file} not found"
    contents = p.read_text(errors="replace")
    missing = [g for g in groups if g not in contents]
    if missing:
        return "red", f"missing in entitlements: {', '.join(missing)}"
    return "green", f"all {len(groups)} app group(s) present"


def gate_signing_cert_valid_60d(cfg: dict) -> tuple[str, str]:
    return _gate_signing_cert_valid_n_days(60)


def gate_signing_cert_valid_30d(cfg: dict) -> tuple[str, str]:
    return _gate_signing_cert_valid_n_days(30)


def _gate_signing_cert_valid_n_days(days: int) -> tuple[str, str]:
    try:
        jwt = asc_jwt()
    except Exception as e:
        return "yellow", f"could not mint ASC JWT: {e}"
    certs = asc_get("/v1/certificates?filter[certificateType]=DISTRIBUTION", jwt)["data"]
    if not certs:
        return "red", "no Apple Distribution certificate found"
    horizons = []
    for c in certs:
        exp = c["attributes"].get("expirationDate")
        if not exp:
            continue
        # Apple format: 2026-08-01T12:34:56.000+00:00
        d = datetime.fromisoformat(exp.replace("Z", "+00:00"))
        horizons.append(d)
    if not horizons:
        return "red", "no cert had expirationDate"
    soonest = min(horizons)
    days_left = (soonest - datetime.now(timezone.utc)).days
    if days_left >= days:
        return "green", f"soonest Apple Distribution cert expires in {days_left} days"
    return "red", f"soonest cert expires in {days_left} days (need ≥ {days})"


def gate_asc_version_metadata_complete(cfg: dict) -> tuple[str, str]:
    try:
        jwt = asc_jwt()
    except Exception as e:
        return "yellow", f"could not mint ASC JWT: {e}"
    app_id = cfg["asc"]["app_id"]
    versions = asc_get(
        f"/v1/apps/{app_id}/appStoreVersions"
        f"?filter[appStoreState]=PREPARE_FOR_SUBMISSION,READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW"
        f"&limit=5",
        jwt,
    )["data"]
    if not versions:
        return "yellow", "no draft or in-review version found"
    v = versions[0]
    vid = v["id"]
    locs = asc_get(f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations", jwt)["data"]
    if not locs:
        return "red", f"version {v['attributes']['versionString']} has no localizations"
    missing = []
    for loc in locs:
        a = loc["attributes"]
        for k in ("description", "keywords", "whatsNew"):
            if not a.get(k):
                missing.append(f"{a.get('locale','?')}.{k}")
    if missing:
        return "red", f"missing fields: {', '.join(missing[:5])}{'…' if len(missing) > 5 else ''}"
    return "green", f"version {v['attributes']['versionString']} metadata complete in {len(locs)} loc(s)"


def gate_asc_iap_metadata_complete(cfg: dict) -> tuple[str, str]:
    try:
        jwt = asc_jwt()
    except Exception as e:
        return "yellow", f"could not mint ASC JWT: {e}"
    app_id = cfg["asc"]["app_id"]
    expected_subs = {s["product_id"] for s in cfg["asc"].get("subscriptions", [])}
    expected_iaps = {i["product_id"] for i in cfg["asc"].get("iaps", [])}

    # Subscriptions live under subscription groups
    groups = asc_get(f"/v1/apps/{app_id}/subscriptionGroups?limit=20", jwt)["data"]
    found_subs: dict[str, dict] = {}
    for g in groups:
        gid = g["id"]
        subs = asc_get(f"/v1/subscriptionGroups/{gid}/subscriptions?limit=200", jwt)["data"]
        for s in subs:
            pid = s["attributes"].get("productId")
            if pid in expected_subs:
                found_subs[pid] = s
    missing_subs = expected_subs - set(found_subs)

    # In-app purchases (v2 endpoint)
    iaps = asc_get(f"/v2/apps/{app_id}/inAppPurchases?limit=200", jwt)["data"]
    found_iaps = {i["attributes"].get("productId"): i for i in iaps}
    missing_iaps = expected_iaps - set(found_iaps)

    issues: list[str] = []
    if missing_subs:
        issues.append(f"missing subs in ASC: {', '.join(sorted(missing_subs))}")
    if missing_iaps:
        issues.append(f"missing iaps in ASC: {', '.join(sorted(missing_iaps))}")

    # Spot-check localizations on subs (full review-screenshot check is V2 — many subs share screenshots).
    incomplete_subs = []
    for pid, s in found_subs.items():
        sid = s["id"]
        locs = asc_get(f"/v1/subscriptions/{sid}/subscriptionLocalizations?limit=20", jwt)["data"]
        if not locs:
            incomplete_subs.append(pid)
            continue
        en = next((l for l in locs if l["attributes"].get("locale", "").startswith("en")), None)
        if not en or not en["attributes"].get("name") or not en["attributes"].get("description"):
            incomplete_subs.append(pid)
    if incomplete_subs:
        issues.append(f"incomplete EN localization on subs: {', '.join(incomplete_subs[:5])}")

    if issues:
        return "red", " | ".join(issues)
    return "green", f"{len(found_subs)} subs + {len(found_iaps)} iaps metadata OK"


def gate_screenshots_fresh(cfg: dict) -> tuple[str, str]:
    """Screenshots present + UPLOAD_COMPLETE + version recent enough."""
    try:
        jwt = asc_jwt()
    except Exception as e:
        return "yellow", f"could not mint ASC JWT: {e}"
    app_id = cfg["asc"]["app_id"]
    freshness_days = cfg.get("screenshots", {}).get("freshness_days", 30)
    expected_devices = set(cfg.get("screenshots", {}).get("devices", []))
    expected_locales = cfg.get("screenshots", {}).get("locales", ["en-US"])

    versions = asc_get(
        f"/v1/apps/{app_id}/appStoreVersions"
        f"?filter[appStoreState]=PREPARE_FOR_SUBMISSION,READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW"
        f"&limit=1",
        jwt,
    )["data"]
    if not versions:
        return "yellow", "no draft or in-review version to check screenshots against"
    v = versions[0]
    vid = v["id"]
    vstr = v["attributes"].get("versionString", "?")

    # Freshness via lastModifiedDate of the version (best proxy without per-screenshot upload date)
    last_modified = v["attributes"].get("createdDate") or v["attributes"].get("lastModifiedDate")
    age_days_label = ""
    if last_modified:
        d = datetime.fromisoformat(last_modified.replace("Z", "+00:00"))
        age_days = (datetime.now(timezone.utc) - d).days
        age_days_label = f" (version touched {age_days}d ago, freshness window {freshness_days}d)"
        if age_days > freshness_days:
            return "red", f"version {vstr} unchanged for {age_days}d > freshness window {freshness_days}d{age_days_label}"

    locs = asc_get(f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations", jwt)["data"]
    target_locs = [l for l in locs if l["attributes"].get("locale") in expected_locales]
    if not target_locs:
        return "red", f"version {vstr} missing localizations for {expected_locales}"

    found_devices: set[str] = set()
    incomplete: list[str] = []
    for loc in target_locs:
        sets = asc_get(
            f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets",
            jwt,
        )["data"]
        for s in sets:
            display = (s["attributes"].get("screenshotDisplayType") or "").lower()
            found_devices.add(display)
            shots = asc_get(f"/v1/appScreenshotSets/{s['id']}/appScreenshots", jwt)["data"]
            for shot in shots:
                state = shot["attributes"].get("assetDeliveryState", {})
                if state.get("state") != "COMPLETE":
                    incomplete.append(f"{display}/{shot['id'][:8]}")

    if incomplete:
        return "red", f"version {vstr} has {len(incomplete)} screenshot(s) not COMPLETE: {', '.join(incomplete[:3])}"

    # Map config device slugs to ASC display types (best-effort substring match)
    slug_to_asc = {
        "iphone-67": "app_iphone_67",
        "iphone-65": "app_iphone_65",
        "iphone-61": "app_iphone_61",
        "ipad-13": "app_ipad_pro_3gen_129",
        "ipad-11": "app_ipad_pro_3gen_11",
    }
    missing_devices = []
    for slug in expected_devices:
        asc_type = slug_to_asc.get(slug, slug)
        if not any(asc_type in d for d in found_devices):
            missing_devices.append(slug)
    if missing_devices:
        return "red", f"version {vstr} missing screenshots for: {', '.join(missing_devices)}"

    # IAP / subscription review screenshots — every configured product needs one
    # attached, in COMPLETE delivery state, before App Review will accept the build.
    iap_issues = _check_iap_review_screenshots(cfg, app_id, jwt)
    if iap_issues:
        return "red", f"version {vstr} IAP review screenshots: {iap_issues}"

    sub_count = len(cfg["asc"].get("subscriptions", []))
    iap_count = len(cfg["asc"].get("iaps", []))
    iap_label = f" + IAP review shots OK ({sub_count} subs, {iap_count} iaps)" if (sub_count or iap_count) else ""
    return "green", f"version {vstr} screenshots complete for {len(expected_devices)} device class(es){iap_label}{age_days_label}"


def _check_iap_review_screenshots(cfg: dict, app_id: str, jwt: str) -> str:
    """Returns empty string if all IAP/sub review screenshots are present + COMPLETE.

    Otherwise returns a one-line summary of issues for inclusion in the gate detail.
    """
    expected_subs = {s["product_id"] for s in cfg["asc"].get("subscriptions", [])}
    expected_iaps = {i["product_id"] for i in cfg["asc"].get("iaps", [])}
    if not expected_subs and not expected_iaps:
        return ""

    missing_attached: list[str] = []
    incomplete_state: list[str] = []

    # Subscriptions: appStoreReviewScreenshot relationship is per-product.
    if expected_subs:
        groups = asc_get(f"/v1/apps/{app_id}/subscriptionGroups?limit=20", jwt)["data"]
        for g in groups:
            try:
                payload = asc_get(
                    f"/v1/subscriptionGroups/{g['id']}/subscriptions"
                    f"?limit=200&include=appStoreReviewScreenshot",
                    jwt,
                )
            except Exception as e:
                return f"sub group {g['id']}: include fetch failed: {e}"
            data = payload.get("data", [])
            included = {x["id"]: x for x in payload.get("included", []) if x.get("type") == "subscriptionAppStoreReviewScreenshots"}
            for s in data:
                pid = s["attributes"].get("productId")
                if pid not in expected_subs:
                    continue
                rel = (s.get("relationships", {}).get("appStoreReviewScreenshot", {}) or {}).get("data")
                if not rel:
                    missing_attached.append(f"sub:{pid}")
                    continue
                shot = included.get(rel["id"])
                if shot:
                    state = (shot["attributes"].get("assetDeliveryState") or {}).get("state")
                    if state != "COMPLETE":
                        incomplete_state.append(f"sub:{pid}({state or '?'})")

    # IAPs (v2): same relationship name.
    if expected_iaps:
        try:
            payload = asc_get(
                f"/v2/apps/{app_id}/inAppPurchases"
                f"?limit=200&include=appStoreReviewScreenshot",
                jwt,
            )
        except Exception as e:
            return f"iap include fetch failed: {e}"
        data = payload.get("data", [])
        included = {x["id"]: x for x in payload.get("included", []) if "appStoreReviewScreenshot" in (x.get("type") or "").lower() or "reviewScreenshot" in (x.get("type") or "")}
        for i in data:
            pid = i["attributes"].get("productId")
            if pid not in expected_iaps:
                continue
            rel = (i.get("relationships", {}).get("appStoreReviewScreenshot", {}) or {}).get("data")
            if not rel:
                missing_attached.append(f"iap:{pid}")
                continue
            shot = included.get(rel["id"])
            if shot:
                state = (shot["attributes"].get("assetDeliveryState") or {}).get("state")
                if state != "COMPLETE":
                    incomplete_state.append(f"iap:{pid}({state or '?'})")

    parts: list[str] = []
    if missing_attached:
        parts.append(f"missing on {len(missing_attached)} product(s): {', '.join(missing_attached[:5])}")
    if incomplete_state:
        parts.append(f"not COMPLETE on {len(incomplete_state)} product(s): {', '.join(incomplete_state[:5])}")
    return " | ".join(parts)


def gate_marketing_truth_audit(cfg: dict) -> tuple[str, str]:
    """Grep ASC version description/keywords/whatsNew for any forbidden phrase."""
    mt = cfg.get("marketing_truth", {})
    forbidden = mt.get("unshipped_forbidden_phrases", [])
    if not forbidden:
        return "yellow", "no unshipped_forbidden_phrases configured — audit no-op"

    try:
        jwt = asc_jwt()
    except Exception as e:
        return "yellow", f"could not mint ASC JWT: {e}"
    app_id = cfg["asc"]["app_id"]
    versions = asc_get(
        f"/v1/apps/{app_id}/appStoreVersions"
        f"?filter[appStoreState]=PREPARE_FOR_SUBMISSION,READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,READY_FOR_DISTRIBUTION"
        f"&limit=1",
        jwt,
    )["data"]
    if not versions:
        return "yellow", "no draft or in-review version to audit"
    v = versions[0]
    vid = v["id"]
    vstr = v["attributes"].get("versionString", "?")

    locs = asc_get(f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations", jwt)["data"]
    en = next((l for l in locs if l["attributes"].get("locale", "").startswith("en")), None)
    if en is None:
        return "yellow", "no en-* localization to audit"

    a = en["attributes"]
    haystack = " | ".join(filter(None, [
        a.get("description", ""),
        a.get("keywords", ""),
        a.get("whatsNew", ""),
        a.get("promotionalText", ""),
        a.get("marketingUrl", ""),
    ])).lower()

    hits: list[str] = []
    for entry in forbidden:
        feature = entry.get("feature", "?")
        for phrase in entry.get("phrases", []):
            if phrase.lower() in haystack:
                hits.append(f"{feature}:'{phrase}'")
    if hits:
        return "red", f"version {vstr} description contains {len(hits)} forbidden phrase(s): {', '.join(hits[:3])}"
    return "green", f"version {vstr} description clean against {sum(len(e.get('phrases', [])) for e in forbidden)} forbidden phrase(s)"


# Build provenance: genuinely waiting on Mission Control primitive (WP #45-66).
def gate_build_provenance_clean(cfg: dict) -> tuple[str, str]:
    return "yellow", "deferred — build-provenance primitive (Mission Control) not yet shipped"


def gate_tek_device_smoke(cfg: dict) -> tuple[str, str]:
    """File-based attestation in .katafract/attestations/<version>.json.

    Schema:
        {
          "version": "1.0",
          "build_number": "415",
          "git_sha": "e2b554c",
          "smoked_at": "2026-05-03T15:30:00Z",
          "smoked_by": "tek",
          "devices": ["iPhone 15 Pro"],
          "notes": "..."
        }
    """
    rel = cfg.get("release", {})
    version = rel.get("current_target_version")
    if not version:
        return "yellow", "release.current_target_version not configured"
    att_dir = Path(rel.get("attestation_dir", ".katafract/attestations"))
    freshness = rel.get("attestation_freshness_days", 30)

    f = att_dir / f"{version}.json"
    if not f.is_file():
        return "red", f"no attestation found at {f} (run scripts/release-readiness/attest.sh after smoke)"
    try:
        att = json.loads(f.read_text())
    except Exception as e:
        return "red", f"attestation {f} is not valid JSON: {e}"

    if att.get("version") != version:
        return "red", f"attestation version mismatch: file says {att.get('version')!r}, config says {version!r}"

    smoked_at_str = att.get("smoked_at")
    if not smoked_at_str:
        return "red", f"attestation missing smoked_at"
    try:
        smoked_at = datetime.fromisoformat(smoked_at_str.replace("Z", "+00:00"))
    except Exception as e:
        return "red", f"attestation smoked_at not parseable: {e}"
    age_days = (datetime.now(timezone.utc) - smoked_at).days
    if age_days > freshness:
        return "red", f"attestation is {age_days}d old (freshness window {freshness}d) — re-smoke and update {f.name}"

    smoked_by = att.get("smoked_by", "?")
    devices = ", ".join(att.get("devices", []) or ["?"])
    return "green", f"v{version} smoked by {smoked_by} {age_days}d ago on {devices}"


GATE_TABLE: dict[str, Callable[[dict], tuple[str, str]]] = {
    "pr_check_main_green": gate_pr_check_main_green,
    "ship_yml_main_green": gate_ship_yml_main_green,
    "screenshots_fresh": gate_screenshots_fresh,
    "marketing_truth_audit": gate_marketing_truth_audit,
    "app_group_entitlement_present": gate_app_group_entitlement_present,
    "asc_version_metadata_complete": gate_asc_version_metadata_complete,
    "asc_iap_metadata_complete": gate_asc_iap_metadata_complete,
    "signing_cert_valid_60d": gate_signing_cert_valid_60d,
    "signing_cert_valid_30d": gate_signing_cert_valid_30d,
    "build_provenance_clean": gate_build_provenance_clean,
    "tek_device_smoke": gate_tek_device_smoke,
}


# ---------- driver ----------------------------------------------------------


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--config", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--summary", default=None)
    args = p.parse_args()

    cfg = yaml.safe_load(Path(args.config).read_text())

    results = []
    for gate in cfg.get("readiness_gates", []):
        gid = gate["id"]
        sev = gate["severity"]
        fn = GATE_TABLE.get(gid)
        if fn is None:
            results.append({
                "id": gid, "severity": sev, "status": "yellow",
                "detail": "no evaluator registered for this gate id",
            })
            continue
        try:
            status, detail = fn(cfg)
        except Exception as e:
            status, detail = "red", f"evaluator crashed: {type(e).__name__}: {e}"
        # Demote red→yellow if severity is warn (warns never block)
        if status == "red" and sev == "warn":
            status = "yellow"
        results.append({"id": gid, "severity": sev, "status": status, "detail": detail})

    payload = {
        "schema_version": 1,
        "slug": cfg.get("slug"),
        "evaluated_at": datetime.now(timezone.utc).isoformat(),
        "git_sha": os.environ.get("GITHUB_SHA", "")[:12],
        "gates": results,
        "summary": _summary_counts(results),
    }
    Path(args.output).write_text(json.dumps(payload, indent=2))

    if args.summary:
        _write_markdown_summary(args.summary, payload)

    # Print a compact terminal summary for the run log
    for g in results:
        marker = {"green": "✅", "yellow": "🟡", "red": "🔴"}.get(g["status"], "?")
        print(f"{marker} [{g['severity']:7}] {g['id']:42} {g['detail']}")


def _summary_counts(results: list[dict]) -> dict:
    counts = {"green": 0, "yellow": 0, "red": 0}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    return counts


def _write_markdown_summary(path: str, payload: dict) -> None:
    lines = [
        f"## Release Readiness — {payload['slug']}",
        "",
        f"Evaluated at `{payload['evaluated_at']}` · sha `{payload['git_sha']}`",
        "",
        f"**Summary:** 🟢 {payload['summary'].get('green',0)} · 🟡 {payload['summary'].get('yellow',0)} · 🔴 {payload['summary'].get('red',0)}",
        "",
        "| Status | Severity | Gate | Detail |",
        "|---|---|---|---|",
    ]
    for g in payload["gates"]:
        marker = {"green": "🟢", "yellow": "🟡", "red": "🔴"}.get(g["status"], "?")
        lines.append(f"| {marker} | {g['severity']} | `{g['id']}` | {g['detail']} |")
    with open(path, "a") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
