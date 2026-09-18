# AirLift File Manager

A standalone iOS app (SwiftUI) that provides:

1. **AirLift tab (slim)** — launch gate status (LocalDevVPN / Pairing File /
   AirLift), Start AirLift, Recheck, tunnel + lockdown one-liners, Access
   Status link, an **on-device RSD+AFC self-test** (write/read/remove a marker
   file through the real chain, gated by the same VPN+pairing requirements),
   and the StikPair pairing guide. No Version Info, no static lists, no
   legacy activation buttons.
2. **Files tab** — a Directory Hub that probes each target location with real
   `FileManager` checks and only opens paths the sandbox can genuinely reach,
   plus a full-featured file browser over the app's real sandbox: list/grid,
   sorting, selection mode, copy/move/rename/delete/duplicate/compress/extract/
   replace/import/share, QuickLook, Get Info, progress + cancel for operations,
   conflict handling, dark mode, Dynamic Type, VoiceOver labels.

The build output is an **unsigned IPA** you sign yourself (AltStore, Sideloadly,
Xcode, TrollStore, etc.).

## Honest AirLift analysis (verified against the upstream repo)

Source analyzed: https://github.com/0xjohnnydev/airlift (`README.md`,
`airlift.py`, `Sources/`, `Makefile`). Full details:
[docs/AIRLIFT_ON_DEVICE_RESEARCH.md](docs/AIRLIFT_ON_DEVICE_RESEARCH.md).

### What AirLift actually is

- A **macOS-side** exploit tool ("paired-Mac AirTraffic/ATAirlock sandbox
  escape") for iOS 27.0 (tested builds **24A435**/RC and **24A437**).
- Execution flow: `airlift.py` drives `xcrun devicectl` plus two **compiled
  macOS helpers** that link `MobileDevice.framework` and
  `AirTrafficHost.framework`.
- Device-side chain: `com.apple.streaming_zip_conduit` → `com.apple.afc` →
  `com.apple.atc` / `AirTrafficDevice` → Books sync client →
  `ATLegacyAssetLink` → `ATAirlock` → `NSFileManager`.
- **Verified write scope** (fresh-file writes): the twelve paths listed under
  `AppConstants.AirLift.verifiedWriteScope` (e.g. `/var/mobile`,
  `/var/mobile/Library/SMS`, `/var/tmp`, …).
- **Reads are indirect**: move a known file into Media, read it through AFC,
  move it back.

### Consequences for this app (the rules we do not break)

- **In-app activation is not possible.** The exploit executes inside
  `AirTrafficHost.framework` on a paired Mac. The AirLift tab therefore reports
  **Unsupported** with the exact technical reason instead of faking an
  Activated state, and no button merely flips a state variable.
- **No persistent "activation" exists to keep alive.** The app persists only
  *observed facts* (last state, last verification time, last result) and
  **re-verifies on every launch**. A stored flag is never treated as proof
  that AirLift still works (unit-tested: stale `Activated` downgrades).
- **LocalDevVPN is real and relevant** (but not part of upstream AirLift —
  0 code matches). SideStore's StosVPN implements the identical
  `NEPacketTunnelProvider` mechanism mapping `10.7.0.1` back to this device,
  which is exactly what StikDebug uses (`DeviceConnectionContext`
  `defaultTargetIPAddress = "10.7.0.1"`). This app performs a **live TCP
  probe** of `10.7.0.1:62078` **and a real lockdown plist exchange**
  (`QueryType`/`GetValue`) through it. That proves *transport* — never
  filesystem access.
- **Pairing is Macless on iOS 27** (StikPair: Developer Mode → "Pair with
  StikPair" → export). This app imports and validates that record and stores
  it in the **Keychain** — never in plain files, never logged. See
  [docs/MACLESS_PAIRING_RESEARCH.md](docs/MACLESS_PAIRING_RESEARCH.md).
  The word *Macless* describes pairing and transport only — **not** AirLift
  execution, which still requires a paired Mac.

## AirLift launch guard (startup requirements)

AirLift may only launch when **LocalDevVPN is connected** AND a **valid Pairing
File is imported** — and it launches only through the guard; the UI never
starts AirLift directly. On launch (and via *Recheck Connection*) the app runs
the preflight ladder and shows **AirLift Setup Required** until all gates pass:

```
1. LocalDevVPN connected?   → not connected ⇒ AirLift Locked
2. Pairing File imported?   → missing       ⇒ AirLift Locked
3. Pairing File valid?      → invalid/unsupported ⇒ AirLift Locked
4. Transport reachable?     → lockdown did not answer ⇒ AirLift Locked
5. Device responds?         → no plist exchange      ⇒ AirLift Locked
all pass                    ⇒ AirLift: Ready to Start
```

- Statuses are shown independently: LocalDevVPN (`Connected` / `Disconnected`
  / `Checking` / `Permission Required`), Pairing File (`Not Imported` /
  `Imported` / `Invalid` / `Expired` / `Unsupported` when determinable),
  AirLift (`Locked` / `Ready to Start` / `Starting` / `Running` / `Failed` /
  `Disconnected`).
- **Every** launch re-runs the full preflight — no cached permission. A failed
  gate refuses the launch, shows the exact reason, and logs it to Technical
  Logs; the user can retry.
- A tunnel watchdog stops everything safely if LocalDevVPN drops while
  running — no fake success state is ever shown.
- Start AirLift executes the real on-device chain (pair-verify → tunnel → RSD → AFC self-test) and reports exactly what was verified (AFC scope only)
- In-app pairing: the app advertises itself, shows the PIN, runs SRP pair-setup and saves the record (audio keep-alive scoped to pairing so iOS does not suspend the session)
- Dọn Books: Books sync-state cleanup + exploit staging (Airlock archive + conduit streaming + AFC verify) with the reference transcript; the AirTraffic sync trigger is a documented pending seam
  (the exploit executes on a paired Mac) instead of pretending to run; a real
  executor plugs in behind the `AirLiftExecuting` seam.
- Pairing records live in the Keychain and are never logged; a TCP connect,
  an import, or a tunnel is never treated as proof that AirLift is active.

## Files tab (Directory Hub)

- Each of the twelve spec paths is probed with real existence/read/write
  checks (including a create-and-remove probe file) and shown as
  `Accessible` / `Read-only` / `Restricted` / `Not Found` — in a sandboxed app
  the `/var/mobile` paths report **Restricted**, which is the truth.
- Only genuinely reachable paths open a browser; the rest show their verified
  status instead of fake content.
- The browser operates through the `FileSystemService` abstraction:
  `SandboxFileSystemService` (real), `AirLiftFileSystemAdapter` (honest
  `Unsupported` seam for a future Mac relay), capability-driven UI
  (`FileSystemCapabilities`) so unsupported actions are never offered.

## Logging

`AppLogger` is the single shared logging service: ring buffer (bounded RAM),
categories (App/AirLift/VPN/Files/Filesystem/Permissions/Network/Pairing/
Security), levels (Debug/Info/Warning/Error), event names, real-time viewer
with search/level/category filters, row selection + Select All, Copy
Selected/All, Share, Clear, Export TXT/JSON, pause/resume. **Every message
passes `Redactor`** — key material and long token runs are replaced with
`[REDACTED]` at record time; pairing data, file contents, tokens and private
keys are never logged.

## Architecture

```
AirLiftFileManager/
├── App/            AirLiftFileManagerApp, AppState, RootTabView (+ iOS27Gate)
├── AirLift/OnDevice/ RPPairing + pair-verify, TLS-PSK 1.2, CDTunnel,
│                   XPC/HTTP2, RSD, AFC clients + self-test chain
├── Core/           Constants, Logging (AppLogger + Redactor + LogViewer),
│                   Formatters
├── AirLift/        AirLiftModels (9-state machine), AirLiftService,
│                   ActivationManager, AirLiftAdapter,
│                   LockdownClient, PairingRecordService,
│                   KeychainPairingStore, ConnectionGate (+ machine/VM),
│                   CapabilityProbe
├── LocalDevVPN/    Honest status service (not part of AirLift)
├── FileSystem/     FileModels, FileSystemService protocol, SandboxFileSystemService,
│                   FileSystemAdapter (AirLift seam), FileSystemCapabilities,
│                   FileOperationManager (progress + cancel), FileSelectionManager,
│                   ZipArchive (pure-Swift ZIP via Apple Compression)
├── Services/       PersistenceService, PermissionService, ErrorHandler
├── Features/
│   ├── AirLift/    AirLiftView, AirLiftViewModel, ConnectionSetupView,
│   │               AccessStatusView (diagnostics), LogViewerView, LocalDevVPNSection
│   └── Files/      DirectoryHubView(+VM), FilesView, FilesViewModel,
│                   FileRowView/FileGridCellView, FileContextMenu,
│                   FileSupportViews (picker/info/share/QuickLook)
└── Resources/      Assets.xcassets (app icon, accent color)
Tests/              XCTest: filesystem, operations, ZIP round-trip + zip-slip,
                    selection, sorting, activation persistence, error handling,
                    capability gating, connection gate ladder, pairing import,
                    log filtering/export/redaction, operation cancellation
docs/               AIRLIFT_ON_DEVICE_RESEARCH.md, MACLESS_PAIRING_RESEARCH.md
```

No third-party dependencies. ZIP compress/extract is implemented in pure Swift
on Apple's `Compression` framework (method 0/8, CRC-32 validation, zip-slip
protection).

## Building the unsigned IPA

Requirements: macOS with Xcode 26 (CI uses `macos-26`).

Local:

```bash
./Scripts/run-tests.sh                                # XCTest on a simulator
./Scripts/build.sh                                    # unsigned IPA
./Scripts/verify_ipa.sh build/AirLiftFileManager-unsigned.ipa
./Scripts/diagnostic_report.sh build/DIAGNOSTIC_REPORT.md
```

Or just push — GitHub Actions (`.github/workflows/build-unsigned-ipa.yml`)
runs the XCTest suite on an iOS Simulator, builds with
`CODE_SIGNING_ALLOWED=NO`, verifies the bundle has **no** `_CodeSignature`,
**no** `embedded.mobileprovision` and a **non-simulator** Mach-O, then uploads
two artifacts: the unsigned IPA and a diagnostic report.

Regenerate the Xcode project after adding files:

```bash
python3 Scripts/gen_pbxproj.py
```

### Signing state of the IPA

`AirLiftFileManager-unsigned.ipa` contains `Payload/AirLiftFileManager.app`
with no code signature and no provisioning profile. Bundle ID:
`com.bbaobaob.airliftfilemanager`, display name: **AirLift File Manager**.

## Testing status

- **Automated (GitHub Actions, iOS Simulator)**: 70+ XCTest cases covering the
  filesystem service, operations, ZIP round-trip + zip-slip rejection,
  selection logic, sorting, activation persistence/re-verification, error
  handling, permission probing, capability gating, the connection-gate ladder
  (with injected probes), pairing validation, log filtering/export/redaction,
  and operation cancellation.
- **Device-tested by the owner on iOS 27 beta** (iPhone): app installs and
  launches; tunnel/lockdown probes require LocalDevVPN to be connected on the
  device at run time.

## Future work

1. Trusted lockdown session (TLS client identity from the pairing record) +
   `StartService com.apple.afc` → honest AFC-scope browsing (Media folder).
2. macOS companion relay (`airlift serve`) + in-app client so the Files tab
   can browse/write the verified scope through the Mac — the
   `AirLiftFileSystemAdapter` seam is prepared.
3. If AirLift upstream ever ships a device-side API, the state machine can
   flip from `Unsupported` to real activation without UI changes.
