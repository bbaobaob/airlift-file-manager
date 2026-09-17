#!/bin/bash
# Verify unsigned IPA contents. No fake log: shows real unzip + codesign output.
# Usage: ./Scripts/verify_ipa.sh [path/to/.ipa]
set -euo pipefail
IPA="${1:-build/AirLiftManager-unsigned.ipa}"
echo "[verify] IPA: $IPA"
test -f "$IPA" || { echo "ERROR: IPA not found: $IPA"; exit 1; }
echo "--- unzip -l ---"
unzip -l "$IPA"
echo "--- Payload check ---"
TMP="$(mktemp -d)"
unzip -q "$IPA" -d "$TMP"
APP="$(find "$TMP" -name "*.app" -maxdepth 3 | head -n 1)"
echo "App: $APP"
ls -la "$APP"
echo "--- codesign -d (expected: unsigned / no signature) ---"
codesign -d "$APP" 2>&1 || true
echo "--- Info.plist Bundle ID ---"
/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist" 2>&1 || plutil -p "$APP/Info.plist" 2>&1 | head -n 20 || true
rm -rf "$TMP"
echo "[verify] done"
