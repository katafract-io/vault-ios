#!/usr/bin/env python3
"""
Print the next CFBundleVersion to stdout.

Queries App Store Connect for the highest build number on a given marketing
version (preReleaseVersion train) for an app, and emits max+1. Used by both
Xcode Cloud (`ci_pre_xcodebuild.sh`) and self-hosted GitHub Actions
(`ship.yml`) so build numbers stay strictly monotonic across runners.

Required env (any source — ASC API key):
  ASC_KEY_ID
  ASC_ISSUER_ID
  one of:
    ASC_KEY_PATH        — absolute path to .p8 file
    ASC_KEY_CONTENT     — full contents of the .p8 (XCC's standard env)
    ASC_PRIVATE_KEY     — same as ASC_KEY_CONTENT (artemis-style env)

Args:
  --app-id    ASC numeric app id (e.g., 6761637680 for Wraith VPN)
  --train     CFBundleShortVersionString (e.g., "1.2")
  --floor     optional minimum starting value if no builds exist on the train
              (default: 1). Useful when bumping marketing versions and you
              want the new train to start above some legacy floor.
  --offset    optional addend (default: 1). Effective value = max + offset.

Exits 0 with the next build number on stdout. Exits non-zero with a message
on stderr if the API can't be reached, in which case the caller should
fall back to a deterministic local formula (CI_BUILD_NUMBER + offset).
"""
import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error

ASC_BASE = "https://api.appstoreconnect.apple.com"

# ----- ES256 JWT minting (no third-party deps) ------------------------------
# Apple requires ES256 (ECDSA over P-256 with SHA-256) on the App Store
# Connect API. We do this without PyJWT/cryptography by shelling out to
# `openssl` (always present on macOS runners and Linux self-hosted runners).

def _b64url(b: bytes) -> str:
    import base64
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")

def _der_to_jose(der: bytes) -> bytes:
    """Convert OpenSSL ECDSA DER signature to JOSE r||s (64 bytes)."""
    # DER: 0x30 len 0x02 rlen r 0x02 slen s
    if der[0] != 0x30:
        raise ValueError("not a DER SEQUENCE")
    # Skip outer header
    idx = 2
    if der[1] & 0x80:
        idx = 2 + (der[1] & 0x7F)
    # r
    assert der[idx] == 0x02
    rlen = der[idx + 1]
    r = der[idx + 2: idx + 2 + rlen]
    idx = idx + 2 + rlen
    # s
    assert der[idx] == 0x02
    slen = der[idx + 1]
    s = der[idx + 2: idx + 2 + slen]
    # Strip leading zero bytes (sign padding) and left-pad to 32 bytes each.
    r = r.lstrip(b"\x00").rjust(32, b"\x00")
    s = s.lstrip(b"\x00").rjust(32, b"\x00")
    if len(r) != 32 or len(s) != 32:
        raise ValueError(f"unexpected r/s lengths {len(r)}/{len(s)}")
    return r + s

def mint_jwt(key_id: str, issuer: str, key_pem: str) -> str:
    import subprocess, tempfile
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    signing_input = (
        _b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + _b64url(json.dumps(payload, separators=(",", ":")).encode())
    )
    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as kf:
        kf.write(key_pem)
        kf.flush()
        try:
            sig_der = subprocess.check_output(
                ["openssl", "dgst", "-sha256", "-sign", kf.name],
                input=signing_input.encode(),
                stderr=subprocess.PIPE,
            )
        finally:
            os.unlink(kf.name)
    sig = _der_to_jose(sig_der)
    return signing_input + "." + _b64url(sig)

# ----- ASC API call ---------------------------------------------------------

def asc_get(token: str, path: str) -> dict:
    req = urllib.request.Request(ASC_BASE + path)
    req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())

def fetch_max_build(app_id: str, train: str, token: str) -> int:
    body = asc_get(
        token,
        f"/v1/builds?filter[app]={app_id}&filter[preReleaseVersion.version]={train}&sort=-version&limit=1",
    )
    items = body.get("data", [])
    if not items:
        return 0
    return int(items[0]["attributes"]["version"])

def load_key() -> str:
    if "ASC_KEY_PATH" in os.environ and os.path.isfile(os.environ["ASC_KEY_PATH"]):
        return open(os.environ["ASC_KEY_PATH"]).read()
    for var in ("ASC_KEY_CONTENT", "ASC_PRIVATE_KEY"):
        v = os.environ.get(var)
        if v:
            return v
    raise SystemExit("error: ASC_KEY_PATH or ASC_KEY_CONTENT/ASC_PRIVATE_KEY required")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app-id", required=True)
    ap.add_argument("--train", required=True)
    ap.add_argument("--floor", type=int, default=1)
    ap.add_argument("--offset", type=int, default=1)
    args = ap.parse_args()

    key_id = os.environ.get("ASC_KEY_ID")
    issuer = os.environ.get("ASC_ISSUER_ID")
    if not key_id or not issuer:
        raise SystemExit("error: ASC_KEY_ID and ASC_ISSUER_ID required")

    key_pem = load_key()
    token = mint_jwt(key_id, issuer, key_pem)

    cur = fetch_max_build(args.app_id, args.train, token)
    nxt = max(cur + args.offset, args.floor)
    sys.stdout.write(str(nxt) + "\n")

if __name__ == "__main__":
    main()
