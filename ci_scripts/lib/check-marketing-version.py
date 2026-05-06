#!/usr/bin/env python3
"""
Verify that the given marketing version train is not behind the max
preReleaseVersion already in App Store Connect.  Exit 1 if stale, 0 if OK.
Non-blocking (exit 0) when ASC credentials are missing or the call fails.
"""
import argparse, json, os, sys, time, urllib.request, subprocess, tempfile

ASC_BASE = "https://api.appstoreconnect.apple.com"


def _b64url(b: bytes) -> str:
    import base64
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _der_to_jose(der: bytes) -> bytes:
    if der[0] != 0x30:
        raise ValueError("not DER")
    idx = 2
    if der[1] & 0x80:
        idx = 2 + (der[1] & 0x7F)
    assert der[idx] == 0x02
    rlen = der[idx + 1]
    r = der[idx + 2: idx + 2 + rlen]
    idx2 = idx + 2 + rlen
    assert der[idx2] == 0x02
    slen = der[idx2 + 1]
    s = der[idx2 + 2: idx2 + 2 + slen]
    r = r.lstrip(b"\x00").rjust(32, b"\x00")
    s = s.lstrip(b"\x00").rjust(32, b"\x00")
    return r + s


def mint_jwt(key_id: str, issuer: str, key_pem: str) -> str:
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
    return signing_input + "." + _b64url(_der_to_jose(sig_der))


def load_key() -> str | None:
    if "ASC_KEY_PATH" in os.environ and os.path.isfile(os.environ["ASC_KEY_PATH"]):
        return open(os.environ["ASC_KEY_PATH"]).read()
    for var in ("ASC_KEY_CONTENT", "ASC_PRIVATE_KEY"):
        v = os.environ.get(var)
        if v:
            return v
    return None


def version_tuple(v: str) -> tuple:
    return tuple(int(x) for x in v.split("."))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app-id", required=True)
    ap.add_argument("--train", required=True)
    args = ap.parse_args()

    key_id = os.environ.get("ASC_KEY_ID")
    issuer = os.environ.get("ASC_ISSUER_ID")
    key_pem = load_key()

    if not (key_id and issuer and key_pem):
        print("::warning::ASC credentials missing — skipping marketing version check")
        sys.exit(0)

    try:
        token = mint_jwt(key_id, issuer, key_pem)
        req = urllib.request.Request(
            f"{ASC_BASE}/v1/apps/{args.app_id}/preReleaseVersions?limit=50",
            headers={"Authorization": f"Bearer {token}"},
        )
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.loads(r.read())

        ios_versions = [
            v["attributes"]["version"]
            for v in data.get("data", [])
            if v["attributes"]["platform"] == "IOS"
        ]

        if not ios_versions:
            print(f"No existing preReleaseVersions — train {args.train} is fine")
            sys.exit(0)

        max_ver = max(ios_versions, key=version_tuple)
        if version_tuple(args.train) < version_tuple(max_ver):
            print(
                f"::error::MARKETING_VERSION {args.train} is behind ASC max {max_ver}. "
                f"Bump MARKETING_VERSION in project.pbxproj to at least {max_ver} before shipping."
            )
            sys.exit(1)

        print(f"Marketing version {args.train} OK (ASC max: {max_ver})")
    except Exception as e:
        print(f"::warning::Could not verify marketing version against ASC: {e}")
        sys.exit(0)


if __name__ == "__main__":
    main()
