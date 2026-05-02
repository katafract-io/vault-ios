#!/bin/zsh -e
# Xcode Cloud CI pre-build: set CFBundleVersion on all targets via agvtool.

# ----- 1. Bump CFBundleVersion -----
# Build number selection: query App Store Connect for max(CFBundleVersion)
# on the current marketing version (CFBundleShortVersionString train) and
# add 1. Same helper is used by self-hosted GH Actions ship.yml so both
# runners produce strictly monotonic numbers regardless of which runs first.
#
# Falls back to CI_BUILD_NUMBER + offset if the helper fails (network blip,
# ASC API outage). Floor of 1 keeps the first build on a fresh marketing
# train sane.
APP_ID="6762418528"   # Vaultyx
TRAIN=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$CI_PRIMARY_REPOSITORY_PATH/Sources/App/Vaultyx.plist" 2>/dev/null \
  | sed 's/\$(MARKETING_VERSION)//' || echo "")
# plist uses $(MARKETING_VERSION) — extract the literal value from
# pbxproj (all targets share it; first match is fine).
if [ -z "$TRAIN" ] || [ "$TRAIN" = "\$(MARKETING_VERSION)" ]; then
  TRAIN=$(grep -m1 "MARKETING_VERSION = " "$CI_PRIMARY_REPOSITORY_PATH/Vaultyx.xcodeproj/project.pbxproj" \
    | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/')
fi
echo "  marketing train: $TRAIN"

BUILD_NUM=""
if [ -n "$TRAIN" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && \
   { [ -n "${ASC_KEY_CONTENT:-}" ] || [ -n "${ASC_PRIVATE_KEY:-}" ]; }; then
  if BUILD_NUM=$(python3 "$CI_PRIMARY_REPOSITORY_PATH/ci_scripts/lib/next-build-number.py" \
                   --app-id "$APP_ID" --train "$TRAIN" --floor 1 2>&1); then
    echo "  ASC-resolved next build: $BUILD_NUM"
  else
    echo "  ASC helper failed: $BUILD_NUM"
    BUILD_NUM=""
  fi
fi
if [ -z "$BUILD_NUM" ]; then
  BUILD_NUM=$((CI_BUILD_NUMBER + 100))
  echo "  fallback formula: CI_BUILD_NUMBER + 100 = $BUILD_NUM"
fi
echo "ci_pre_xcodebuild: setting CFBundleVersion to $BUILD_NUM on all targets"
cd "$CI_PRIMARY_REPOSITORY_PATH"
XCPROJ=$(ls -d *.xcodeproj 2>/dev/null | head -1)
if [ -z "$XCPROJ" ]; then
  echo "  no .xcodeproj at repo root, searching..."
  XCPROJ=$(find . -maxdepth 3 -name "*.xcodeproj" | head -1)
fi
echo "  target project: $XCPROJ"
if [ -n "$XCPROJ" ]; then
  cd "$(dirname "$XCPROJ")"
  if ! agvtool new-version -all "$BUILD_NUM"; then
    echo "  agvtool failed, falling back to PlistBuddy on all Info.plists"
    cd "$CI_PRIMARY_REPOSITORY_PATH"
    find . -name "*.plist" -not -path "*/Pods/*" -not -path "*/fastlane/*" -not -path "*/Tests*" -not -path "*/UITests*" | while read p; do
      if /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$p" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$p" && echo "    bumped: $p"
      fi
    done
  fi
fi
echo "ci_pre_xcodebuild: done"
