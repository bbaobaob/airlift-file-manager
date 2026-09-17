#!/bin/bash
# Build unsigned IPA for AirLift File Manager (Companion Viewer + Sandbox Demo).
# Honest scope: unsigned IPA only (CODE_SIGNING_ALLOWED=NO). No fake signed IPA.
# Requires macOS runner with Xcode 16. Will NOT work on Termux/Linux local.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
APP="$OUT/Build/Products/Release-iphoneos/AirLiftManager.app"
PAYLOAD="$OUT/Payload"
IPA="$OUT/AirLiftManager-unsigned.ipa"

echo "[export-ipa] Building (CODE_SIGNING_ALLOWED=NO)..."
xcodebuild -project "$ROOT/AirLiftManager.xcodeproj" \
  -scheme AirLiftManager \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$OUT/DerivedData" \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  build

if [ ! -d "$APP" ]; then
  # Fallback path check
  APP="$(find "$OUT/DerivedData" -name "AirLiftManager.app" -type d | head -n 1)"
fi
echo "[export-ipa] App: $APP"
test -d "$APP" || { echo "ERROR: .app not found"; exit 1; }

rm -rf "$PAYLOAD" "$IPA"
mkdir -p "$PAYLOAD"
cp -R "$APP" "$PAYLOAD/"
cd "$OUT"
zip -r -y "AirLiftManager-unsigned.ipa" Payload > /dev/null
echo "[export-ipa] Wrote $IPA"
unzip -l "$IPA" | head -n 30
