#!/bin/bash
# Run unit tests on an iOS simulator. Picks the first available iPhone automatically.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "[tests] Locating an available iPhone simulator..."
DEST="$(python3 - <<'EOF'
import json, subprocess
out = subprocess.run(["xcrun","simctl","list","devices","available","-j"],
                     capture_output=True, text=True, check=True).stdout
data = json.loads(out)
name = None
for runtime, devices in data.get("devices", {}).items():
    for d in devices:
        if d.get("isAvailable") and d.get("name","").startswith("iPhone"):
            name = d["name"]; break
    if name: break
print(name or "generic/platform=iOS Simulator")
EOF
)"
echo "[tests] Destination: $DEST"

xcodebuild test \
  -project "$ROOT/AirLiftFileManager.xcodeproj" \
  -scheme AirLiftFileManager \
  -destination "platform=iOS Simulator,name=$DEST" \
  -derivedDataPath "$ROOT/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
