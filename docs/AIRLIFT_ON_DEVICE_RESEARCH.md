# AirLift On-Device Research (iOS 27)

Status: **research, verified against upstream sources on 2026-09**. This document
separates what is **proven**, what is **implemented in this app**, and what
remains **hypothesis**. The app's UI follows this document — nothing in the app
claims more than what is listed here as verified.

Upstream analyzed: https://github.com/0xjohnnydev/airlift
(`README.md`, `airlift.py`, `Sources/`, `Makefile`).

---

## 1. What AirLift actually is

AirLift is a **macOS-side** tool ("paired-Mac AirTraffic/ATAirlock sandbox
escape") for iOS 27.0 (builds 24A435/RC and 24A437):

- `airlift.py` drives `xcrun devicectl` plus two **compiled macOS helpers**
  linking `MobileDevice.framework` and `AirTrafficHost.framework`.
- Device-side chain: `com.apple.streaming_zip_conduit` → `com.apple.afc` →
  `com.apple.atc` / `AirTrafficDevice` → Books sync client → `ATLegacyAssetLink`
  → `ATAirlock` → `NSFileManager`.
- **Verified write scope** (fresh-file writes confirmed upstream): `/var/mobile`,
  `/var/mobile/Documents`, `/var/mobile/Library`, `/var/mobile/Library/Preferences`,
  `/var/mobile/Library/Caches`, `/var/mobile/Library/SpringBoard`,
  `/var/mobile/Library/SMS`, `/var/mobile/Library/Safari`,
  `/var/mobile/Containers`, `/var/mobile/Containers/Data/Application`,
  `/var/mobile/Containers/Shared/AppGroup`, `/var/tmp`.
- **Reads are indirect**: move a known file into Media, read it through AFC,
  move it back.
- Upstream is a PoC: writes a random canary, verifies bytes, cleans up,
  restores Books sync state.

## 2. Component-by-component portability

| Component | macOS-only? | iOS-feasible? | Evidence |
|---|---|---|---|
| `airlift.py` orchestration | Yes (drives devicectl + host helpers) | No — `devicectl` is a macOS binary | upstream Makefile/Sources |
| Host helper linking `MobileDevice.framework` | Yes | No — framework is not present on iOS | upstream Sources |
| Host helper linking `AirTrafficHost.framework` | Yes (exploit executes here) | No — private host framework, absent on iOS; also not callable from a sandboxed app even if present | upstream Sources |
| Trigger of device-side chain (`streaming_zip_conduit` → `afc` → `atc`) | Runs on device, but only reachable via the host transport | **Partially**: lockdown itself is reachable on-device via LocalDevVPN (implemented, see §3). The Books-sync trigger step that `ATAirlock` rides on is **not** implemented on-device by any public tool | this repo's lockdown probe (real plist exchange) |
| Pairing | Yes (classic: Mac pairs the iPhone) | **Yes on iOS 27**: StikPair pairs on-device via Developer Mode ("Pair with StikPair" + PIN) | StikDebug/StikPair README (verified) |
| Transport to device services | USB/Wi-Fi via usbmuxd | **Yes**: LocalDevVPN / StosVPN packet tunnel maps `10.7.0.1` back to this device; StikDebug uses exactly this (`DeviceConnectionContext.defaultTargetIPAddress = "10.7.0.1"`) | StikDebug source (verified) |

## 3. What this app has proven on a real device

1. **Tunnel reachability** — TCP connect to `10.7.0.1:62078` succeeds when
   LocalDevVPN/StosVPN is connected (`LocalDevVPNService.probeTunnel`).
2. **Lockdown exchange** — a real length-prefixed binary-plist
   `QueryType`/`GetValue` round trip over that tunnel
   (`LockdownClient`), returning live device facts (iOS version, product type).
3. **Pairing record import** — a StikPair-exported record validates
   (`PairingRecordService.validate`: `HostPrivateKey`, `HostCertificate`,
   `DeviceCertificate`) and is stored in the Keychain
   (`KeychainPairingStore`, `kSecClassGenericPassword`,
   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
4. **Sandbox scope truth** — the twelve spec paths are probed with real
   `FileManager` checks; from a sandboxed app they report `Restricted`
   (with the exact reason shown in the Files tab).

Items 1–3 together prove: **the transport hop of the AirLift chain is
reusable on-device.** They do **not** prove exploit access — see §5.

## 4. Why the full exploit cannot run in-app (technical causes)

1. `AirTrafficHost.framework` and `MobileDevice.framework` exist on macOS
   hosts, not on iOS. There is no in-process host framework to drive.
2. Even if the frameworks existed, a sandboxed app cannot spawn the
   privileged host helper or talk to usbmuxd (`/var/run/usbmuxd` is
   inaccessible from the app sandbox on iOS).
3. The exploit payload executes inside the host process; there is no
   device-side API exposed by upstream AirLift to trigger it remotely.
4. Code signing: an App Store/unsigned-sideloaded app cannot obtain the
   entitlements or the platform trust needed to load private host frameworks.

Conclusion: **a companion relay is required** for the exploit path —
either the existing Mac-side `airlift` tool, or a future `airlift serve`
daemon on macOS that this app talks to. The seam is prepared:
`AirLiftFileSystemAdapter` implements the full `FileSystemService`
protocol and honestly reports `Unsupported` until a relay exists.

## 5. Proven vs hypothesis (do not confuse them)

**Proven (PoC or implemented here):**
- On-device pairing export on iOS 27 (StikPair) — upstream evidence.
- On-device lockdown access via LocalDevVPN — implemented here, device-tested.
- Mac-side AirLift writes into the verified scope — upstream PoC.

**Hypothesis (not implemented, not verified anywhere public):**
- Triggering the Books-sync/`ATAirlock` chain **from on-device** through the
  tunnel (i.e., using lockdown as both ends). No public tool does this; the
  trigger lives on the host side today.
- Authenticated (trusted) lockdown session + `StartService com.apple.afc`
  from on-device using the imported pairing identity: plausible
  (StikDebug does equivalent trusted-session work with idevice for debug
  services) but **not yet implemented in this app** — the TLS client-identity
  plumbing exists in `LockdownClient`, the StartService flow does not.
- Filesystem access beyond the sandbox from a sandboxed app **without** the
  exploit: not possible; any UI implying otherwise would be fake.

## 6. Decision for this build

- Files tab = real sandbox backend + honest per-path probes (no fake rows).
- AirLift tab = honest 9-state activation machine that can only reach
  `Activated` on a real verified channel (never via a flag).
- Connection gate = the ladder in §3 (VPN → pairing → transport → capability),
  re-verified every launch; `ready` never persists as truth.
- Capability probe reports each capability independently; on-device exploit
  execution is reported **Not implemented**, trusted-session **Not
  implemented**, with the reasons above.

## 7. Safe next steps (ordered by risk/effort)

1. **Trusted lockdown session** — TLS client certificate from the imported
   pairing record, then `StartService com.apple.afc` over the tunnel. If it
   works, the Media folder (AFC scope) becomes browsable honestly, clearly
   labeled as AFC scope (not the full verified scope).
2. **AFC client** — implement the AFC read/write protocol on top of 1.
3. **Mac relay (`airlift serve`)** — implement the host-side daemon + JSON
   protocol; plug it in behind `AirLiftFileSystemAdapter` with its own
   backend kind and capability set.
4. **Research-only**: monitor upstream AirLift for any device-side trigger;
   re-evaluate §5 items before touching the state machine.
