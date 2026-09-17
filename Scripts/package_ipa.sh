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
# Keep the binary exactly as Xcode produced it.
# Rationale: the SDK floor (iOS 26.5) already satisfies iOS 27's install check,
# and a vtool-patched minos (27.0) with an unpatched sdk (26.5) makes an
# out-of-spec Mach-O that/iOS may kill at launch. Info.plist carries the gate.
echo "[package] MinimumOSVersion -> $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")"
if command -v vtool >/dev/null; then
  echo "[package] Mach-O (as built): $(vtool -show-build "$OUT/Payload/AirLiftFileManager.app/AirLiftFileManager" 2>/dev/null | grep -E 'minos|sdk' | tr '\n' ' ')"
fi

( cd "$OUT" && zip -qry "AirLiftFileManager-unsigned.ipa" Payload )

echo "[package] Wrote $IPA"
ls -la "$IPA"
