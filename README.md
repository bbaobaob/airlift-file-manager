# AirLift File Manager

A standalone iOS app (SwiftUI) that provides:

1. **AirLift tab** — activation status, honest capability reporting, real per-directory access probes, technical logs.
2. **Files tab** — a full-featured file manager over the app's real sandbox: browse, list/grid, sorting, selection mode, copy/move/rename/delete/duplicate/compress/extract/replace/share/import, QuickLook previews, Get Info, dark mode, Dynamic Type, VoiceOver labels.

The build output is an **unsigned IPA** you sign yourself (AltStore, Sideloadly, Xcode, TrollStore, etc.).

## Honest AirLift analysis (verified against the upstream repo)

Source analyzed: https://github.com/0xjohnnydev/airlift (`README.md`, `airlift.py`, `Sources/`, `Makefile`).

### What AirLift actually is

- A **macOS-side** exploit tool ("paired-Mac AirTraffic/ATAirlock sandbox escape") for iOS 27.0 (tested builds **24A435**/RC and **24A437**).
- Execution flow: `airlift.py` drives `xcrun devicectl` plus two **compiled macOS helpers** that link `MobileDevice.framework` and `AirTrafficHost.framework`.
- Device-side chain: `com.apple.streaming_zip_conduit` → `com.apple.afc` → `com.apple.atc` / `AirTrafficDevice` → Books sync client → `ATLegacyAssetLink` → `ATAirlock` → `NSFileManager`.
- **Verified write scope** (fresh-file writes): `/var/mobile`, `/var/mobile/Documents`, `/var/mobile/Library`, `/var/mobile/Library/Preferences`, `/var/mobile/Library/Caches`, `/var/mobile/Library/SpringBoard`, `/var/mobile/Library/SMS`, `/var/mobile/Library/Safari`, `/var/mobile/Containers`, `/var/mobile/Containers/Data/Application`, `/var/mobile/Containers/Shared/AppGroup`, `/var/tmp`.
- **Reads are indirect**: move a known file into Media, read it through AFC, move it back.
- Upstream is a PoC: it writes a random canary, verifies bytes, cleans up, and restores Books sync state.

### Consequences for this app (the rules we do not break)

- **In-app activation is not possible.** The exploit executes inside `AirTrafficHost.framework` on a paired Mac. A sandboxed iOS app cannot reach that framework or the device daemons in the chain. The AirLift tab therefore reports **Unsupported** with the exact technical reason instead of faking an Activated state.
- **No persistent "activation" exists to keep alive.** AirLift performs one-shot writes when the Mac-side tool runs. There is nothing to persist after closing the app — so the app persists only *observed facts* (last state, last verification time, last result) and **re-verifies on every launch**. A stored flag is never treated as proof that AirLift still works (unit-tested: stale `Activated` downgrades to `Disconnected`).
- **LocalDevVPN is not part of AirLift.** A code search of the upstream repo returns **0 matches** for `LocalDevVPN`; airlift uses the standard paired-device transport (USB/Wi-Fi) — no VPN tunnel, no extra pairing, no daemon to keep alive. The app displays this finding honestly instead of inventing a VPN integration.
- **/var/mobile access from the Files tab is honestly labeled.** The Files tab operates on the app's real sandbox via `FileSystemService`. The AirLift tab probes each spec directory (`/var/mobile`, `.../SMS`, `.../SpringBoard`, ...) and labels results `Accessible` / `Read-only` / `Restricted` / `Not Found` — in a sandboxed app the /var/mobile paths report **Restricted**, which is the truth. `AirLiftFileSystemAdapter` is the documented seam where a future Mac-host relay would plug in; it currently reports `Unsupported` rather than pretending.

### Tested target directories (spec §6)

All twelve directories are probed at runtime with real `FileManager` checks (existence, readability, writability, plus a create-and-remove probe file). Results appear in the AirLift tab with per-path explanations.

## Architecture

```
AirLiftFileManager/
├── App/            AirLiftFileManagerApp, AppState, RootTabView
├── Core/           Constants, Logging (AppLogger + Debug Logs screen), Formatters
├── AirLift/        AirLiftModels (9-state machine), AirLiftService, ActivationManager, AirLiftAdapter
├── LocalDevVPN/    Honest status service (not part of AirLift)
├── FileSystem/     FileModels, FileSystemService protocol, SandboxFileSystemService,
│                   FileSystemAdapter (AirLift seam), FileOperationManager,
│                   FileSelectionManager, ZipArchive (pure-Swift ZIP via Apple Compression)
├── Services/       PersistenceService, PermissionService, ErrorHandler
├── Features/
│   ├── AirLift/    AirLiftView, AirLiftViewModel, AirLiftLogView
│   └── Files/      FilesView, FilesViewModel, FileRowView/FileGridCellView,
│                   FileContextMenu, FileSupportViews (picker/info/share/QuickLook)
└── Resources/      Assets.xcassets (app icon, accent color)
Tests/              XCTest: file system, operations, ZIP round-trip, selection,
                    sorting, activation persistence, error handling
```

No third-party dependencies. ZIP compress/extract is implemented in pure Swift on Apple's `Compression` framework (method 0/8, CRC-32 validation, zip-slip protection).

## Building the unsigned IPA

Requirements: macOS with Xcode 16 (CI uses `macos-15`).

Local:

```bash
./Scripts/build.sh                                    # tests via run-tests.sh in CI
./Scripts/verify_ipa.sh build/AirLiftFileManager-unsigned.ipa
```

Or just push — GitHub Actions (`.github/workflows/build-unsigned-ipa.yml`) runs the XCTest suite on an iOS Simulator, builds with `CODE_SIGNING_ALLOWED=NO`, verifies the bundle has **no** `_CodeSignature` and **no** `embedded.mobileprovision`, and uploads the artifact.

Regenerate the Xcode project after adding files:

```bash
python3 Scripts/gen_pbxproj.py
```

### Signing state of the IPA

`AirLiftFileManager-unsigned.ipa` contains `Payload/AirLiftFileManager.app` with no code signature and no provisioning profile. `codesign -d` on it reports "code object is not signed at all" — exactly what sideloading tools expect before re-signing. Bundle ID: `com.bbaobaob.airliftfilemanager`, display name: **AirLift File Manager**.

## Testing status

- **Automated (GitHub Actions, iOS Simulator)**: 40+ XCTest cases across file system service, operations, ZIP round-trip + zip-slip rejection, selection logic, sorting, activation persistence/re-verification, error handling, permission probing.
- **Not performed**: no real-device testing has been done (no paired iPhone available in CI). Nothing here claims device testing.

## Future work

- Implement a macOS companion relay (`airlift serve`) + in-app client so the Files tab can browse/write the verified scope through the Mac. The `AirLiftFileSystemAdapter` seam is prepared for it.
- If AirLift upstream ever ships a device-side API, the AirLift tab's state machine can flip from `Unsupported` to real activation without UI changes.
