#!/bin/bash
# Package a built .app into an unsigned IPA: build/AirLiftFileManager-unsigned.ipa
# Usage: ./Scripts/package_ipa.sh /path/to/AirLiftFileManager.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
APP="${1:-$(find "$OUT/DerivedData/Build/Products" -name "AirLiftFileManager.app" -type d | head -n 1)}"
IPA="$OUT/AirLiftFileManager-unsigned.ipa"

test -d "$APP" || { echo "ERROR: .app not found: $APP"; exit 1; }

# Guard: refuse to ship a signed bundle (spec: unsigned IPA only).
if [ -d "$APP/_CodeSignature" ]; then
  echo "ERROR: $APP contains _CodeSignature — refusing to call this unsigned."
  exit 1
fi

rm -rf "$OUT/Payload" "$IPA"
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"

# iOS 27-only gate: MinimumOSVersion 27.0 (build uses SDK 26.6 — newest on runners).
PLIST="$OUT/Payload/AirLiftFileManager.app/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MinimumOSVersion 27.0" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string 27.0" "$PLIST"
echo "[package] MinimumOSVersion -> $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")"

# Patch Mach-O LC_BUILD_VERSION (minos/sdk -> 27.0) so signing tools and the
# installer read a consistent iOS 27 floor. Verifiable, no silent failure.
BIN="$OUT/Payload/AirLiftFileManager.app/AirLiftFileManager"
if command -v vtool >/dev/null; then
  echo "[package] Before: $(vtool -show-build "$BIN" 2>/dev/null | grep -E 'minos|sdk' | tr '\n' ' ')"
  if vtool -set-build-version ios 27.0 27.0 -replace -output "$BIN" "$BIN"; then
    echo "[package] After:  $(vtool -show-build "$BIN" 2>/dev/null | grep -E 'minos|sdk' | tr '\n' ' ')"
  else
    echo "[package] WARNING: vtool patch failed; binary keeps SDK minos" >&2
    exit 1
  fi
else
  echo "[package] WARNING: vtool not found; Info.plist gate only" >&2
fi

( cd "$OUT" && zip -qry "AirLiftFileManager-unsigned.ipa" Payload )

echo "[package] Wrote $IPA"
ls -la "$IPA"
