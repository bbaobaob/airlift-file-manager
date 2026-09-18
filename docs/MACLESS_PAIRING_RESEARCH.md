# Macless Pairing & Transport Research (StikPair / StikDebug / StosVPN / Locus)

Status: research verified against public sources on 2026-09. Goal: determine
whether the Mac dependency of AirLift can be reduced or removed **legally and
technically**, and what this app may reuse. No bypass of system protections is
implemented or planned in this repository.

---

## 1. Projects examined (with sources)

| Project | What it does | License | Key sources |
|---|---|---|---|
| **StikPair** (`StikDebug/StikPair`) | Creates a lockdown pairing file **fully on-device** (iOS 27+ / tvOS 11+) | MIT, non-commercial | `App/PairingController.swift`, README |
| **StikDebug** (`StikDebug/StikDebug`) | On-device debugger/JIT enabler over idevice; talks to device services through the LocalDevVPN tunnel | GPL-3.0 (per repo) | `StikDebug/Device/DeviceConnectionContext.swift`, README |
| **StosVPN** (SideStore) | NEPacketTunnelProvider app mapping `10.7.0.1` back to the device's own services (lockdown 62078) | Open source | Same mechanism as LocalDevVPN |
| **Locus** | RemoteXPC-based on-device tooling (LocalDevVPN + pairing file) | — | referenced by ecosystem docs |
| **iloader** (`nab138/iloader`) | Older path: places a pairing file into apps **from a computer** (Mac/Win/Linux) | — | StikDebug-Guide `pairing_file.md` |

## 2. Verified findings

### 2.1 Pairing without a computer — YES on iOS 27 (with caveats)

- StikPair (SwiftUI app, Rust `idevice` FFI core named `StikPairFFI`) performs
  wireless pairing **on-device**: the user opens
  **Settings › Privacy & Security › Developer Mode › "Pair with StikPair"**,
  enters the PIN shown in a Live Activity, then exports
  `rp_pairing_file.plist` via ShareLink.

**Observed on-device format (verified 2026-09-18 against a real StikPair
export — structure only, no key material recorded):** the exported
`rp_pairing_file.plist` is a **RemotePairing (wireless pairing) record**, NOT
a classic lockdown record: `public_key` + `private_key` (32-byte raw keys),
`identifier` (UUID string), `alt_irk` (16 bytes). The app's validator accepts
this format (`PairingFormat.remotePairing`, strict type/length checks) alongside
the classic `HostPrivateKey`/`HostCertificate`/`DeviceCertificate` lockdown
format. Honest consequence: this credential suits RemotePairing-based flows;
it does not by itself enable classic trusted lockdown sessions (`StartService`), which remain unimplemented.

**Wireless chain status (this build):** the credential is now *used*, not just stored.
The app implements step 1 of the real idevice wireless chain — live mDNS discovery
of `_remotepairing._tcp` plus the exact authTag validation (`SipHash-2-4`, ported
from `idevice/src/remote_pairing/peer_device.rs`), surfaced as the
`wireless-pairing.discoverable` capability check. Steps 2–3 (encrypted
RemotePairing session handshake, then RSD → lockdown services) are implemented
in `AirLiftFileManager/AirLift/OnDevice/` as a direct port of the idevice flow
(pair-verify with X25519/HKDF-SHA512/ChaCha20Poly1305/Ed25519 via CryptoKit,
TLS 1.2 PSK-AES-CBC-SHA* client, CDTunnel handshake, XPC-over-HTTP/2 RSD,
AFC client) plus an in-app AFC write/read/remove self-test. All pure codecs
are unit-tested; the live handshake is verified on-device by running the
self-test (LocalDevVPN + valid pairing required, same gates as Start AirLift).
Direct TCP to 10.7.0.1 is used for every hop through the tunnel instead of a
userspace IPv6/TCP stack — if RSD/AFC ports turn out not to answer on
loopback, the self-test log pinpoints the exact hop and the fallback is a
minimal TCP-over-CDTunnel adapter.
(`StartService`), which remain unimplemented.
- Mechanism details verified from source: Bonjour discovery
  (`_remotepairing-manual-pairing._tcp.`) for Apple TV targets,
  `NetService` + Local Network permission, `BGContinuedProcessingTask`
  keep-alive, FFI session objects (`stikpair_apple_tv_session_new`).
- Caveats verified from the ecosystem docs:
  - Requires **iOS 27+** for the "Pair with app" Developer Mode flow.
  - Pairing records are **device-specific and time-specific**; they can expire
    on OS update/reset (and occasionally at random) — replacement required.
  - The older computer-assisted path (iloader) still exists and is documented
    in the StikDebug guide.

**Conclusion:** pairing setup no longer requires a Mac on iOS 27. This app's
import flow (StikPair-style record → validation → Keychain) is aligned with a
real, working mechanism.

### 2.2 Transport without a Mac — YES (proven mechanism)

- StikDebug's `DeviceConnectionContext.defaultTargetIPAddress = "10.7.0.1"`
  confirms the on-device tools connect to device services through the
  LocalDevVPN/StosVPN packet tunnel.
- This app independently verified the same endpoint with a real lockdown
  plist exchange (`LockdownClient`, `10.7.0.1:62078`).
- LocalDevVPN is **not** part of upstream AirLift (0 code matches in the
  airlift repository); it is a separately distributed tunnel app.

### 2.3 What these tools can NOT do (as verified)

- **No AirTraffic/ATAirlock execution on iOS.** StikDebug/idevice talk to
  lockdown services that exist on the device (debugserver via trusted
  session, AFC, etc.). Nothing public executes the host-side
  `AirTrafficHost.framework` payload from an iPhone.
- **No out-of-sandbox filesystem access** via pairing files alone. A pairing
  record grants *trusted lockdown sessions* to services the device chooses to
  expose (`com.apple.afc` = Media folder; `com.apple.mobile.container_manager`
  = house-arrest containers). It does **not** grant `/var/mobile` at large.
- StikPair's license is **MIT but non-commercial**; StikDebug is GPL-3.0.
  Reuse implications: do not copy code wholesale; re-implement against public
  protocol behavior instead (this repo already does its own lockdown framing).

## 3. Reusable vs not reusable for AirLift File Manager

**Reusable (as mechanisms/protocols, no code copied):**
- On-device pairing export via StikPair → import + validate here (already
  implemented; `PairingRecordService` + `KeychainPairingStore`).
- `10.7.0.1:62078` lockdown transport over LocalDevVPN/StosVPN (already
  implemented and device-verified).
- Trusted-session concept: TLS client certificate from the pairing record
  (`LockdownClient` already carries the `clientIdentity` plumbing).

**Not reusable / not available:**
- The AirLift exploit path itself — host-only (see
  `AIRLIFT_ON_DEVICE_RESEARCH.md` §4).
- Any "Macless AirLift" claim — pairing being Macless does not make the
  exploit Macless. The marketing rule for this repo: the word *Macless* may
  describe **pairing and transport** only, never AirLift execution.

## 4. Feasibility verdict for this app

| Capability | Verdict |
|---|---|
| Import pairing file with no computer | ✅ Feasible now (StikPair export) — implemented |
| Lockdown transport with no computer | ✅ Feasible now (LocalDevVPN) — implemented & verified |
| Trusted lockdown session (`StartService`) | ⚠️ Plausible (StikDebug does equivalent work), **not yet implemented here** |
| Browse Media via AFC after trusted session | ⚠️ Plausible, next step; scope = Media folder only, must be labeled honestly |
| Out-of-sandbox writes (`/var/mobile`, SMS, SpringBoard…) | ❌ Requires the Mac-side AirLift tool (or a future `airlift serve` relay) |
| Full "Macless AirLift" | ❌ Not possible with any public mechanism |

## 5. Safe next steps

1. Implement the trusted lockdown session + `StartService com.apple.afc`
   probe behind a capability flag (off by default; honestly reported as
   *Not implemented* until it verifies on-device).
2. If AFC works: add an `AFCFileSystemAdapter` implementing
   `FileSystemService`, scoped to the AFC root, with its own backend kind and
   a read/write capability set measured by real probes.
3. Keep the pairing expiry handling: detect rejected trusted sessions and
   guide the user to re-export from StikPair.
4. Re-verify everything on each iOS 27 beta bump; pairing behavior and
   Developer Mode options change between betas.

## In-app pairing host (this build)

The app now implements the responder side itself (port of
`idevice/src/remote_pairing/responder.rs`): it advertises
`_remotepairing-pairable-host._tcp`, shows the 6-digit PIN, runs SRP
pair-setup M1–M6 and saves the fresh record — no separate StikPair app
needed. Two device realities shaped the implementation:

- **Background suspension.** iOS suspends our sockets seconds after the user
  leaves for Settings, so the device could never connect back (no PIN ever
  appeared). A scoped audio + background-task keep-alive runs only during
  pairing (same approach as StikPair itself).
- **Start AirLift runs the real chain.** The old "Transport unavailable"
  refusal is gone: Start now executes pair-verify → tunnel → RSD → AFC
  self-test through the guarded preflight and reports exactly what was
  verified (AFC scope). The Mac-side AirTraffic path stays out of scope.

## Books / Airlock write path (upstream airlift, verified in source)

Upstream `airlift.py` + `device_helper.m` + `airtraffic_host.m` show the full
write flow this app ports step by step:

- **Archive** (`build_archive`): streaming zip with `p0/p1/p2/link` symlink
  to `../../../<target>`, `0x5A53` extra field carrying unix modes,
  `META-INF/com.apple.ZipMetadata.plist`. Ported byte-exactly to
  `AirlockArchive` (unit-tested).
- **Delivery**: the archive is streamed to `com.apple.streaming_zip_conduit`
  (`{"MediaSubdir": source}` + raw bytes — standard service framing), NOT
  through AFC. Ported to `StreamingZipConduit`; works only if RSD advertises
  the conduit port, which the app reports live.
- **Books state** (`snapshot-books`/`finish`): tracked paths
  (`Books/Books.plist`, `Books/Sync/*`, `OutstandingAssets_4.sqlite*`),
  snapshot/restore, absent-checks. Ported to `BooksState`; the "Dọn Books"
  screen reproduces the reference transcript (`books[...] = absent` →
  CLEAN → BOOKS DONE ✓).
- **Trigger (pending seam)**: the AirTraffic sync (`SyncAllowed` →
  HostInfo → SyncRequest → ReadyForSync → MetadataSyncFinished → assets →
  AssetCompleted) runs inside AirTrafficHost.framework; its ATCFMessage wire
  framing is private with no public implementation anywhere (every known
  implementation, e.g. aid/iTunes, loads the framework). Modeled as
  `AirTrafficTriggering` so a future trigger plugs in; until then the app
  stages/verifies/cleans honestly and says exactly where it stopped.

## Tunnel TCP adapter (this build)

Device evidence settled the transport question: pair-verify, TLS-PSK and the
CDTunnel handshake all succeed over direct TCP to 10.7.0.1, the handshake
returns a live RSD port — but direct TCP to that port times out. RSD/AFC
listen on the CDTunnel IPv6 endpoint only, not on loopback. So every
post-handshake connection now runs packet-layer TCP through the held-open
tunnel (the idevice Adapter role): IPv6 + TCP codec, SYN/ACK handshake with
MSS, sliding window with cumulative ACKs, RTO retransmit, FIN/RST handling —
with direct TCP kept as a 3-second first attempt per connection (it wins
wherever the bridge reaches). The tunnel stays open for the whole session.
