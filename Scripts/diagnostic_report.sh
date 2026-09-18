#!/bin/bash
# Emits a build diagnostic report (build facts + honest capability matrix).
# The report is uploaded as its own CI artifact next to the unsigned IPA.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/DIAGNOSTIC_REPORT.md}"
mkdir -p "$(dirname "$OUT")"

{
echo "# AirLift File Manager — Diagnostic Report (build)"
echo
echo "Generated (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
if command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode: $(xcodebuild -version | head -n1 | tr '\n' ' ')"
  echo "iOS SDK: $(xcodebuild -showsdks 2>/dev/null | grep -m1 -i iphoneos | xargs)"
fi
echo "Bundle ID: com.bbaobaob.airliftfilemanager"
echo "Deployment target: iOS 26.0 build floor, runtime-gated to iOS 27.x (iOS27Gate)"
echo "Signing: unsigned IPA (re-sign with AltStore/Sideloadly/Xcode/TrollStore)"
echo
echo "## Capability matrix (verified facts, not claims)"
echo
echo "| Capability | Status | Evidence |"
echo "|---|---|---|"
echo "| Sandbox Files tab (browse/read/write/zip/…) | Implemented | SandboxFileSystemService + XCTest suite |"
echo "| Per-path access probes (12 spec paths) | Implemented | PermissionService real FileManager probes |"
echo "| LocalDevVPN tunnel probe (10.7.0.1:62078 TCP) | Implemented | LocalDevVPNService.probeTunnel |"
echo "| Lockdown plist exchange (QueryType/GetValue) | Implemented | LockdownClient over the tunnel |"
echo "| StikPair-style pairing import + Keychain storage | Implemented | PairingRecordService + KeychainPairingStore |"
echo "| Connection gate state machine (VPN→pairing→transport→capability) | Implemented | ConnectionGate + unit tests |"
echo "| Trusted lockdown session (StartService com.apple.afc) | NOT implemented | TLS client identity plumbed; StartService flow missing |"
echo "| AFC file access (Media folder) | NOT implemented | depends on trusted session |"
echo "| AirLift on-device exploit execution | NOT possible in-process | AirTrafficHost/MobileDevice are macOS host frameworks (see docs/AIRLIFT_ON_DEVICE_RESEARCH.md) |"
echo "| AirLift writes to verified scope | Requires paired Mac (upstream airlift) | upstream PoC; relay seam: AirLiftFileSystemAdapter |"
echo
echo "## Interpretation rules enforced by the app"
echo
echo "- A TCP connect proves tunnel reachability only."
echo "- A lockdown exchange proves transport only."
echo "- A pairing record enables trusted sessions; it is NOT proof of filesystem access."
echo "- Build success is NOT proof that any AirLift feature works."
echo
echo "See docs/AIRLIFT_ON_DEVICE_RESEARCH.md and docs/MACLESS_PAIRING_RESEARCH.md."
} > "$OUT"

echo "[diag] report written to $OUT"
