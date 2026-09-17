#!/bin/bash
# Verify IPA structure and signing state. Prints REAL codesign/plutil output.
# Usage: ./Scripts/verify_ipa.sh [path/to/.ipa]
set -euo pipefail
IPA="${1:-build/AirLiftFileManager-unsigned.ipa}"
echo "[verify] IPA: $IPA"
test -f "$IPA" || { echo "ERROR: IPA not found: $IPA"; exit 1; }

echo "--- unzip listing ---"
unzip -l "$IPA" | head -n 25

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unzip -q "$IPA" -d "$TMP"
APP="$(find "$TMP" -name "*.app" -maxdepth 3 -type d | head -n 1)"
test -d "$APP" || { echo "ERROR: no .app inside IPA"; exit 1; }

echo "--- binary + bundle checks ---"
BIN="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null || plutil -extract CFBundleExecutable raw "$APP/Info.plist")"
test -f "$APP/$BIN" || { echo "ERROR: main executable missing"; exit 1; }
file "$APP/$BIN"

if [ -d "$APP/_CodeSignature" ]; then
  echo "SIGNING: _CodeSignature present"
else
  echo "SIGNING: no _CodeSignature (unsigned bundle)"
fi
if [ -f "$APP/embedded.mobileprovision" ]; then
  echo "SIGNING: embedded.mobileprovision present"
else
  echo "SIGNING: no embedded.mobileprovision"
fi

echo "--- codesign -d (expected: code object is not signed) ---"
codesign -d "$APP" 2>&1 || true

echo "--- bundle identity ---"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null \
  || plutil -extract CFBundleIdentifier raw "$APP/Info.plist"
echo "MinimumOSVersion: $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP/Info.plist" 2>/dev/null || echo 'not set')"
BIN_MACHO="$APP/$BIN"
if command -v vtool >/dev/null; then
  echo "--- Mach-O build version (LC_BUILD_VERSION) ---"
  vtool -show-build "$BIN_MACHO" | grep -E "minos|sdk" || true
fi
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Info.plist" 2>/dev/null \
  || plutil -extract CFBundleDisplayName raw "$APP/Info.plist" || true

echo "[verify] done"
