#!/usr/bin/env bash
# Record a Tek-device-smoke attestation for the current target version.
#
# Usage:
#   scripts/release-readiness/attest.sh "iPhone 15 Pro" "Photo backup + manual upload + album toggle all OK"
#
# Reads release.current_target_version from .katafract/config.yaml and writes
# .katafract/attestations/<version>.json. The release-readiness workflow's
# tek_device_smoke gate checks for this file's freshness.

set -eo pipefail

DEVICES="${1:-}"
NOTES="${2:-}"

if [ -z "$DEVICES" ]; then
  echo "usage: $0 \"<device(s) comma-separated>\" \"<notes>\"" >&2
  exit 1
fi

VERSION=$(python3 -c "import yaml; print(yaml.safe_load(open('.katafract/config.yaml'))['release']['current_target_version'])")
SHA=$(git rev-parse --short HEAD)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SMOKED_BY=$(git config --get user.email || whoami)

ATT_DIR=".katafract/attestations"
mkdir -p "$ATT_DIR"
OUT="$ATT_DIR/$VERSION.json"

# Convert comma-separated devices to JSON array
DEVICES_JSON=$(python3 -c "
import json, sys
devices = [d.strip() for d in '''$DEVICES'''.split(',') if d.strip()]
print(json.dumps(devices))
")

cat > "$OUT" <<EOF
{
  "version": "$VERSION",
  "git_sha": "$SHA",
  "smoked_at": "$NOW",
  "smoked_by": "$SMOKED_BY",
  "devices": $DEVICES_JSON,
  "notes": "$NOTES"
}
EOF

echo "wrote $OUT"
cat "$OUT"
