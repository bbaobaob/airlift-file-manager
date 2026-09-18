# Attribution

This app's on-device pairing and tunnel code is an **original Swift port** of
publicly documented protocols. No third-party source code is copied into this
repository. Protocol behavior was verified against the following open-source
projects, which are credited here with their licenses:

## Upstream projects studied

- **idevice** (`github.com/jkcoxson/idevice`) — remote-pairing handshake,
  TLS-PSK tunnel, CDTunnel, XPC/RSD framing, AFC packet layer, SRP pair-setup
  responder flow, OPACK codec, SipHash authTag algorithm.
  License: **MIT** (Copyright 2026 Jackson Coxson).
- **idevice-srp** (`github.com/jkcoxson/idevice-srp`) — SRP-6a formulas and
  the G_3072 (RFC 5054) group parameters this port follows.
  License: **MIT**.
- **StikPair** (`github.com/StikDebug/StikPair`) — the on-device pairing
  ceremony this app reproduces (advertise → Developer Mode → PIN → export),
  the `rp_pairing_file.plist` format, and the `supportedContentTypes` set
  used by the document picker.
  License: **MIT, Non-Commercial** (Copyright (c) 2026 StephenDev0).
- **StikDebug** (`github.com/StikDebug/StikDebug`) — the `10.7.0.1` tunnel
  endpoint convention.
  License: **GPL-3.0**.
- **AirLift** (`github.com/0xjohnnydev/airlift`) — the Mac-side exploit this
  app honestly reports on but does not reimplement.
  (See its repository for its license.)

## Scope of use in this repository

- Only **protocol facts** (message layouts, constants, algorithm steps) were
  carried over, re-expressed as original Swift code.
- The in-app pairing responder and the RSD/AFC chain are clean-room Swift
  implementations of those protocols; where behavior was uncertain, the
  implementation follows the upstream source line-by-line and says so in
  comments.
- Consistent with StikPair's non-commercial terms, this app is a personal,
  non-commercial sideloaded utility. Do not commercialize this codebase
  without reviewing the upstream licenses above.
