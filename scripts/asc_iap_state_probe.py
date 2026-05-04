#!/usr/bin/env python3
"""
Probe ASC state for Vaultyx IAP/SUB review screenshot status.

Checks that all capacity tier subscriptions (100GB, 1TB, 5TB × monthly/yearly)
and sovereign.forever IAP are OUT of MISSING_METADATA state.

Usage:
  python scripts/asc_iap_state_probe.py [--fail-on-missing]

Exit code: 0 if all required SKUs have review screenshots, non-zero otherwise.
"""
import sys
import os

# Add parent dir to path so we can import services
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from services.asc_screenshot_upload import _asc_token, _h, ASC_BASE
import requests


def probe_vaultyx_iap_state(fail_on_missing: bool = True) -> bool:
    """
    Check ASC state for Vaultyx IAP/SUB review screenshots.
    Returns True if all required SKUs have screenshots, False otherwise.
    """
    token = _asc_token()
    app_id = "6762418528"  # vaultyx

    # Expected SKUs
    required_subs = {
        "100gb.monthly": "com.katafract.vault.100gb.monthly",
        "100gb.yearly": "com.katafract.vault.100gb.yearly",
        "1tb.monthly": "com.katafract.vault.1tb.monthly",
        "1tb.yearly": "com.katafract.vault.1tb.yearly",
        "5tb.monthly": "com.katafract.vault.5tb.monthly",
        "5tb.yearly": "com.katafract.vault.5tb.yearly",
    }
    required_iaps = {
        "sovereign.forever": "com.katafract.vault.sovereign.forever",
    }

    missing_review_shots = []

    # Check subscriptions
    print("Checking subscriptions...")
    sg = requests.get(f"{ASC_BASE}/v1/apps/{app_id}/subscriptionGroups",
                      headers=_h(token), timeout=15).json()
    sub_by_id = {}
    for g in sg["data"]:
        subs = requests.get(f"{ASC_BASE}/v1/subscriptionGroups/{g['id']}/subscriptions",
                            headers=_h(token), timeout=15).json()
        for sub in subs["data"]:
            sub_by_id[sub["attributes"]["productId"]] = sub["id"]

    for short_name, full_id in required_subs.items():
        if full_id not in sub_by_id:
            print(f"  ⚠️  {short_name:20s} NOT FOUND in ASC")
            missing_review_shots.append(short_name)
            continue

        sub_id = sub_by_id[full_id]
        rs = requests.get(f"{ASC_BASE}/v1/subscriptions/{sub_id}/appStoreReviewScreenshot",
                          headers=_h(token), timeout=15)
        has_shot = rs.status_code == 200 and rs.json().get("data")
        status = "✓" if has_shot else "✗ MISSING"
        print(f"  {status:20s} {short_name}")
        if not has_shot:
            missing_review_shots.append(short_name)

    # Check IAPs
    print("Checking in-app purchases...")
    iap = requests.get(f"{ASC_BASE}/v2/apps/{app_id}/inAppPurchases",
                       headers=_h(token), timeout=15).json()
    iap_by_id = {p["attributes"]["productId"]: p["id"] for p in iap.get("data", [])}

    for short_name, full_id in required_iaps.items():
        if full_id not in iap_by_id:
            print(f"  ⚠️  {short_name:20s} NOT FOUND in ASC")
            missing_review_shots.append(short_name)
            continue

        iap_id = iap_by_id[full_id]
        rs = requests.get(f"{ASC_BASE}/v2/inAppPurchases/{iap_id}/appStoreReviewScreenshot",
                          headers=_h(token), timeout=15)
        has_shot = rs.status_code == 200 and rs.json().get("data")
        status = "✓" if has_shot else "✗ MISSING"
        print(f"  {status:20s} {short_name}")
        if not has_shot:
            missing_review_shots.append(short_name)

    # Summary
    print()
    if missing_review_shots:
        print(f"❌ {len(missing_review_shots)} SKUs missing review screenshots:")
        for sku in missing_review_shots:
            print(f"   - {sku}")
        if fail_on_missing:
            return False
    else:
        print("✅ All required capacity SUBs + sovereign.forever have review screenshots")
        return True

    return len(missing_review_shots) == 0


if __name__ == "__main__":
    fail_on_missing = "--fail-on-missing" in sys.argv or True  # default to failing
    success = probe_vaultyx_iap_state(fail_on_missing=fail_on_missing)
    sys.exit(0 if success else 1)
