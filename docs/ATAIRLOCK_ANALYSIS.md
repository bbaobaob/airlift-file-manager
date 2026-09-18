# ATAirlock Primitive Analysis (from upstream README)

Source: `0xjohnnydev/airlift` README ("ATAirlock path validation" section).
This document maps the exact vulnerable logic to this app's modules and
gives the honest on-device feasibility verdict per piece.

## 1. The exact primitive (quoting upstream)

```
source      = /var/mobile/Media/Airlock/Book + asset.identifier   // UNCHECKED (.. allowed)
destination = [/var/mobile/Media/ + asset.path] standardized      // must prefix Media/…
if (![destination hasPrefix:@"/var/mobile/Media/"]) return;
[fileManager moveItemAtPath:source toPath:destination]            // follows ancestor symlinks
```

Plus: "StreamingZip accepts the relative symlink while it is still contained
in its extraction directory. The first move relocates it below Media; the
second uses it as part of the destination and writes the payload outside
Media."

Consequences for our port:

| Upstream element | Our module | Status |
|---|---|---|
| `p0/p1/p2/link → ../../../<target>` symlink | `AirlockArchive.entries` | ✅ exact port, tested |
| `0x5A53` extra + ZipMetadata.plist | `AirlockArchive` | ✅ exact port, tested |
| Books manifest identifiers (`../../<source>/…`, relpath target) | `BooksAttempt.plan` | ✅ exact port, tested |
| `asset.identifier` with `..` → unchecked source | manifest `targetIdentifier` | ✅ carried through |
| `asset.path` → string-checked destination | manifest `destinations` | ✅ carried through |
| Stream archive to `com.apple.streaming_zip_conduit` | `StreamingZipConduit` | ✅ implemented, needs RSD-advertised port on-device |
| Books snapshot / absent-check / restore | `BooksState` + Dọn Books UI | ✅ implemented, video-format log |
| AirTraffic sync trigger (the two moves + recovery) | `AirTrafficTriggering` seam | ❌ pending (see §2) |
| Indirect reads (move to Media, AFC read, move back) | — | ❌ needs trigger result first |

## 2. Why the trigger is the only missing piece ("Grappa")

The 3105 developer community calls the Mac-side sync machinery "Grappa":
Airlift needs it, hence macOS. Porting "Grappa" = reimplementing the
AirTraffic Books sync host (SyncAllowed → HostInfo → SyncRequest →
ReadyForSync → MetadataSyncFinished → assets → AssetCompleted) on-device.
The message NAMES and parameters are public (upstream `airtraffic_host.m`,
`aid/ATH.cpp`); the **ATCFMessage wire framing is private** (inside
AirTrafficHost.framework) with **zero public implementations anywhere**
(verified by code search: every known tool loads the framework binary).
That framing is the single unknown — everything around it is implemented
and tested in this repo.

## 3. On-device pathways, honestly ranked

1. **Conduit-direct (implemented, awaiting device verdict).** IF RSD
   advertises `com.apple.streaming_zip_conduit`, stream the archive there
   and verify staging via AFC. The app attempts this and reports exactly
   what happens — including whether the port exists at all.
2. **Full sync trigger (pending).** Blocked on ATCFMessage framing (§2).
   The seam is ready; no fake sync is or will be shown.
3. **Alternative triggers (hypotheses, NOT claims).** E.g. conduit
   processing on file arrival, Books app launch effects, reboot effects.
   Each is testable on-device with the staging + verify tools in this app;
   none is assumed to work.
4. **What others are doing.** The 3105 developer is porting the same sync
   host ("Grappa") with no public code yet. If their framing work surfaces,
   this app's seam accepts it directly.

## 4. Scope notes from upstream, honored here

- Tested builds 24A435 + 24A5390f (24A437 expected); other builds run with
  a warning, not a block. This app warns (never blocks) on untested builds
  in the DonBooks flow.
- "Does not work on the MobileGestalt plist" — the app does not special-case
  it; writes there are expected to fail like upstream.
- Fresh-file writes only (never overwrite existing system files); the
  target-leaf safety checks from `finish` (canary pattern, size limits)
  apply to any staging this app attempts.
- Reads stay indirect (AFC) — no direct out-of-sandbox reads are claimed.
