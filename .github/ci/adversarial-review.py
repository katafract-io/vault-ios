#!/usr/bin/env python3
"""
adversarial-review.py — 5-axis adversarial review of a git diff via the `claude` CLI.

Phase 1 (STATIC): reasons adversarially about a unified diff across five axes, then an
adversarial verify pass that tries to REFUTE each finding (default REFUTED unless the
mechanism is provable). Emits a markdown report + JSON, and exits non-zero when a
high-severity finding is CONFIRMED — so it can gate a PR check.

The five axes mirror the app-driven Phase-2 harness (state/lifecycle, identity/keyspace,
connectivity/offline, trust-boundary/input, money/reconciliation). Phase 1 cannot drive
the app, so each lens hunts, in the diff, for code that would FAIL that axis' pass-bar.

Uses `claude -p` (headless, Max plan, unmetered) — never the metered API.
Designed to run on the self-hosted Mac runner (hephaestus) that has `claude` + `git`.

Usage:
  adversarial-review.py --diff <file>   [--out report.md] [--json out.json]
  git diff origin/main...HEAD | adversarial-review.py --diff -
"""
import argparse, json, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

MAX_DIFF_CHARS = 60000
MAX_FINDINGS_PER_LENS = 5
CLAUDE_TIMEOUT = 600
CONCURRENCY = 2

# Each axis = (key, adversarial thesis + attack playbook + pass bar). The lens hunts the
# diff for code that violates the pass bar under one of the listed attacks.
AXES = [
    ("state-lifecycle",
     "AXIS 1 — STATE & LIFECYCLE. Thesis: every state transition can be skipped, replayed, "
     "reversed, run twice concurrently, or interrupted mid-write. Attacks: skip a required "
     "step; submit the same step twice (double-tap/retry); go back to a completed step and "
     "resubmit; two actors on the same entity at once; kill mid-transaction and resume; reach "
     "step N with step N-1's data missing. PASS BAR: every transition idempotent; partial "
     "completion leaves no orphaned/half-wired state; re-entry resumes cleanly; concurrent "
     "actors converge to one correct state (no twin/duplicate)."),
    ("identity-keyspace",
     "AXIS 2 — IDENTITY, KEYSPACE & DATA INTEGRITY. Thesis: the id you hold is the wrong id, "
     "maps to two things, or to nothing. Attacks: pass a foreign/other-tenant id; disjoint "
     "keyspaces that must bridge; create a duplicate/twin of an existing entity; read a stale "
     "value after a write; leak data across site/tenant boundary. PASS BAR: every write "
     "reconciles through the authoritative bridge (loud-fail, never silent); one real-world "
     "entity = one active record (twin-guarded); reads from source of truth; hard tenant/site "
     "isolation."),
    ("connectivity-offline",
     "AXIS 3 — CONNECTIVITY & OFFLINE. Thesis: the network dies at the worst moment; the phone "
     "is a store-and-forward buffer, not a live client. Attacks: go offline mid-capture; queue "
     "offline then drain on reconnect; retry a submit that actually succeeded (dup); conflicting "
     "edits on two offline devices; clock skew; kill before the outbox flushes; partial upload. "
     "PASS BAR: offline capture durable and replays exactly-once; drains idempotent and "
     "conflict-resolved; server authoritative on time/order; no lost writes, no double writes."),
    ("trust-boundary",
     "AXIS 4 — TRUST BOUNDARY & ADVERSARIAL INPUT. Thesis: never trust the client; the actor is "
     "trying to self-elevate or tamper. Attacks: self-grant a staff-assigned privilege; tamper "
     "client-supplied amounts/ids/flags; replay a signed/captured request; spoof identity; inject "
     "malformed/hostile input; call an endpoint directly to bypass a client-side gate. PASS BAR: "
     "every privilege/amount/eligibility server-authoritative (client value ignored); role gates "
     "enforced server-side; inputs validated; replays rejected; PII/security respected."),
    ("money-reconciliation",
     "AXIS 5 — MONEY & RECONCILIATION. Thesis: cash-in must equal net-invoiced-revenue at every "
     "seam, or money is silently created/destroyed. Attacks: double-bill (two active leases/one "
     "home), double-pay, abuse a discount/prepay tranche, mis-apply a refund/forfeit, pay into "
     "arrears vs current, over/underpay, race a payment against invoice regeneration. PASS BAR: "
     "books balance at every seam; discounts/bonuses are contra-revenue netting to zero; no "
     "double-charge/double-credit; loud-fail before money is stranded; every cash movement "
     "audited and reversible-by-design. (If the diff touches no money/ledger/billing code, "
     "return no findings for this axis.)"),
]

FINDINGS_RX = re.compile(r'\{[\s\S]*\}')


def claude(prompt: str) -> str:
    try:
        r = subprocess.run(["claude", "-p", prompt], capture_output=True, text=True, timeout=CLAUDE_TIMEOUT)
        return r.stdout or ""
    except Exception:
        return ""


def parse_json_block(text: str):
    fenced = re.search(r'```(?:json)?\s*([\s\S]*?)```', text)
    cand = fenced.group(1) if fenced else text
    m = FINDINGS_RX.search(cand)
    if not m:
        return None
    try:
        return json.loads(m.group(0))
    except Exception:
        return None


def run_lens(key, axis, diff):
    prompt = (
        f"You are an ADVERSARIAL reviewer. Assume an intelligent adversary (flaky network, "
        f"hostile user, half-crashed phone, double-tap, stale cache) is actively trying to break "
        f"this change. Your job is to find where it BREAKS, not to approve.\n\n"
        f"{axis}\n\n"
        f"Review ONLY the unified diff below (reason about the enclosing functions it touches). "
        f"Report code that would VIOLATE this axis' pass bar under one of the listed attacks. "
        f"For each real defect: file, line, severity (high|medium|low), one-line summary, and a "
        f"concrete failure scenario (attack -> wrong outcome). Real bugs >> style. If the diff "
        f"does not touch anything relevant to this axis, return an empty list.\n"
        f"Return up to {MAX_FINDINGS_PER_LENS} of your MOST concrete findings as STRICT JSON ONLY:\n"
        f'{{"findings":[{{"file":"","line":0,"severity":"high","summary":"","scenario":""}}]}}\n'
        f"If nothing real, return {{\"findings\":[]}}.\n\nDIFF:\n{diff}\n"
    )
    out = parse_json_block(claude(prompt)) or {}
    fs = out.get("findings", []) if isinstance(out, dict) else []
    for f in fs:
        f["axis"] = key
    return fs[:MAX_FINDINGS_PER_LENS]


def verify(f, diff):
    prompt = (
        f"Adversarially VERIFY this code-review finding by reading the diff. Try to REFUTE it.\n"
        f"FINDING [{f.get('severity')}] {f.get('file')}:{f.get('line')} — {f.get('summary')}\n"
        f"Scenario: {f.get('scenario')}\n\n"
        f"Return CONFIRMED only if you can name the inputs/state and the wrong outcome; PLAUSIBLE "
        f"if the mechanism is real but the trigger is uncertain; REFUTED if the code does not do "
        f"this or it is guarded elsewhere. Default to REFUTED unless the mechanism is provable. "
        f"Return STRICT JSON ONLY: {{\"verdict\":\"CONFIRMED|PLAUSIBLE|REFUTED\",\"reason\":\"\"}}\n\nDIFF:\n{diff}\n"
    )
    v = parse_json_block(claude(prompt)) or {}
    f["verdict"] = (v.get("verdict") or "UNKNOWN").upper()
    f["why"] = v.get("reason", "")
    return f


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--diff", required=True)
    ap.add_argument("--out", default="adversarial-review.md")
    ap.add_argument("--json", default="adversarial-review.json")
    a = ap.parse_args()

    diff = sys.stdin.read() if a.diff == "-" else open(a.diff).read()
    truncated = len(diff) > MAX_DIFF_CHARS
    if truncated:
        diff = diff[:MAX_DIFF_CHARS] + "\n...[diff truncated for review]..."
    if not diff.strip():
        print("No diff to review."); open(a.out, "w").write("No diff to review.\n"); sys.exit(0)

    with ThreadPoolExecutor(max_workers=CONCURRENCY) as ex:
        cand = [f for fs in ex.map(lambda x: run_lens(x[0], x[1], diff), AXES) for f in fs]

    seen, deduped = set(), []
    for f in cand:
        k = (f.get("file"), f.get("line"), (f.get("summary") or "")[:40])
        if k in seen:
            continue
        seen.add(k); deduped.append(f)

    with ThreadPoolExecutor(max_workers=CONCURRENCY) as ex:
        verified = list(ex.map(lambda f: verify(f, diff), deduped))
    kept = [f for f in verified if f.get("verdict") in ("CONFIRMED", "PLAUSIBLE")]
    order = {"high": 0, "medium": 1, "low": 2}
    kept.sort(key=lambda f: (order.get(f.get("severity"), 3), 0 if f.get("verdict") == "CONFIRMED" else 1))

    high_confirmed = [f for f in kept if f.get("severity") == "high" and f.get("verdict") == "CONFIRMED"]

    lines = ["## 🔪 Adversarial review (5-axis, static)", ""]
    if truncated:
        lines.append("> ⚠️ diff truncated to first %d chars for review.\n" % MAX_DIFF_CHARS)
    lines.append(f"{len(cand)} candidates → **{len(kept)} not-refuted** "
                 f"({len(high_confirmed)} high-severity confirmed).\n")
    if not kept:
        lines.append("No surviving findings. ✅")
    for f in kept:
        badge = "🔴" if f["severity"] == "high" else ("🟠" if f["severity"] == "medium" else "🟡")
        lines.append(f"### {badge} [{f['verdict']}/{f['severity']}] `{f.get('file')}:{f.get('line')}` ({f.get('axis')})")
        lines.append(f"{f.get('summary')}")
        lines.append(f"- **Scenario:** {f.get('scenario')}")
        if f.get("why"):
            lines.append(f"- **Verify:** {f.get('why')}")
        lines.append("")
    report = "\n".join(lines)
    open(a.out, "w").write(report + "\n")
    json.dump({"candidates": len(cand), "kept": kept, "highConfirmed": len(high_confirmed)},
              open(a.json, "w"), indent=2)
    print(report)
    print(f"\n[adversarial-review] high-confirmed={len(high_confirmed)} kept={len(kept)}", file=sys.stderr)
    sys.exit(1 if high_confirmed else 0)


if __name__ == "__main__":
    main()
