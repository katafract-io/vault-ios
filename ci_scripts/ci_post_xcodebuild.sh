#!/bin/bash
# Runs after xcodebuild archive, before Xcode Cloud exports+uploads to TestFlight.
# Writes the App Store Connect API key so xcodebuild's exportArchive step can
# authenticate without an Apple ID session.
#
# Set these in your Xcode Cloud workflow under Environment → Secrets:
#   ASC_KEY_ID       — Key ID from App Store Connect (Users & Access → Keys)
#   ASC_ISSUER_ID    — Issuer ID from the same page
#   ASC_KEY_CONTENT  — Full contents of the .p8 file (including BEGIN/END lines)

set -euo pipefail

if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" || -z "${ASC_KEY_CONTENT:-}" ]]; then
  echo "ci_post_xcodebuild: ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_CONTENT not set — skipping key setup."
  echo "  Set these as Xcode Cloud environment secrets to enable API key authentication."
  exit 0
fi

KEYS_DIR="$HOME/.appstoreconnect/private_keys"
mkdir -p "$KEYS_DIR"
printf '%s' "$ASC_KEY_CONTENT" > "$KEYS_DIR/AuthKey_${ASC_KEY_ID}.p8"
chmod 600 "$KEYS_DIR/AuthKey_${ASC_KEY_ID}.p8"

export APP_STORE_CONNECT_API_KEY_KEY_ID="$ASC_KEY_ID"
export APP_STORE_CONNECT_API_KEY_ISSUER_ID="$ASC_ISSUER_ID"
export APP_STORE_CONNECT_API_KEY_CONTENT="$ASC_KEY_CONTENT"

echo "ci_post_xcodebuild: ASC API key written (Key ID: ${ASC_KEY_ID})"
