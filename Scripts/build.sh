#!/bin/bash
# Build AirLift File Manager (unsigned) and package an IPA. macOS + Xcode 16 required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
APP_NAME="AirLiftFileManager"

echo "[build] Checking environment..."
case "$(uname -s)" in
  Darwin) ;;
  *) echo "ERROR: iOS build requires macOS. Current OS: $(uname -s)"; exit 2 ;;
esac
command -v xcodebuild >/dev/null || { echo "ERROR: xcodebuild not found"; exit 2; }
xcodebuild -version

echo "[build] Building for generic iOS device (CODE_SIGNING_ALLOWED=NO)..."
xcodebuild -project "$ROOT/AirLiftFileManager.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$OUT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  build

# Deterministic path: the device build must come from Release-iphoneos.
# (Do NOT fuzzy-find: after simulator test runs, Products also contains a
# Debug-iphonesimulator app — packaging that one makes the IPA crash at launch
# with "incompatible platform (have 'iOS-simulator', need 'iOS')".)
APP="$OUT/DerivedData/Build/Products/Release-iphoneos/$APP_NAME.app"
test -d "$APP" || { echo "ERROR: .app not found after build"; exit 1; }
echo "[build] Built app: $APP"

"$ROOT/Scripts/package_ipa.sh" "$APP"
