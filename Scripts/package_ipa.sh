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
( cd "$OUT" && zip -qry "AirLiftFileManager-unsigned.ipa" Payload )

echo "[package] Wrote $IPA"
ls -la "$IPA"
