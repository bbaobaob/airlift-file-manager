# AirLift File Manager — Companion Viewer + Sandbox Demo (Honest Scaffold)

> **No on-device exploit.** This app does NOT jailbreak, escalate sandbox, or access `/var/mobile/*` on-device.
> It is a **Companion Viewer** (verifies Mac-produced `TetherResult` JSON) + **Sandbox Demo** (real CRUD inside its own `Documents/`).

## Honest Limits
- `ActivationManager` ONLY verifies `TetherResult` JSON fields: `udid`, `iosBuild`, `timestamp`, `sha256`, `cleanupConfirmed`. Missing/invalid → `VerificationFailed`. No fake boolean success.
- On-device reachable states only: `NotActivated` / `TetherRequired` / `VerificationPending` / `VerifiedViaTether` / `Unsupported`. Other 4 enum cases are Mac-side/informational.
- `SandboxFileSystemService`: real list/read/write/delete/mkdir confined to `Documents/`, blocks `..` (symlink-escape protection).
- `TetheredReadOnlyService`: `list()` from snapshot JSON only; `write/read-through/delete/mkdir` always throw `UnsupportedOnDevice`. Any `/var/mobile/*` access is labeled `Requires Mac / UnsupportedOnDevice` and never executed on-device.
- No fake IPA/log. IPA is built **unsigned** (`CODE_SIGNING_ALLOWED=NO`) on a macOS runner. Local Termux/Linux **cannot** build IPA (no Xcode).
- ZIP export in Files scaffold currently throws `UnsupportedOnDevice` until verified with `Compression` framework on Mac runner. List/grid, sort, select, context menu are real SwiftUI.

## Requirements
- iOS 17+, Swift 5, SwiftUI (no private API).
- macOS 15 + Xcode 16 runner for `.ipa` (see Actions).

## Structure
```
AirLiftManager/App/            AirLiftManagerApp.swift, ContentView.swift (2 tabs)
AirLiftManager/Core/Activation/ ActivationState.swift, TetherResult.swift, ActivationManager.swift
AirLiftManager/Core/FileSystem/ FileSystemService.swift, SandboxFileSystemService.swift, TetheredReadOnlyService.swift
AirLiftManager/Core/Logging/   Logger.swift
AirLiftManager/Features/Activation/ ActivationView.swift, ActivationViewModel.swift
AirLiftManager/Features/Files/ FilesView.swift, FilesViewModel.swift
Scripts/export-ipa.sh  Scripts/verify_ipa.sh
.github/workflows/build-unsigned-ipa.yml
```

## Push + Trigger Actions (run on macOS runner)
```bash
# first time (Termux local, no build):
git remote add origin <YOUR_GITHUB_URL>
git branch -M main
git push -u origin main
# Then: GitHub → Actions → build-unsigned-ipa → Download artifact AirLiftManager-unsigned
```

Local verify (Termux, no Xcode):
```bash
ls -R
git status
# IPA build skipped locally — requires macOS runner (see above)
```

## Scripts
- `Scripts/export-ipa.sh`: `xcodebuild CODE_SIGNING_ALLOWED=NO` → `Payload/` → `zip` unsigned IPA.
- `Scripts/verify_ipa.sh`: `unzip -l`, `codesign -d` (expected unsigned), Bundle ID check.
