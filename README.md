# MacRemoteApp

MacRemoteApp is a LAN-first macOS application remote-view and control tool.
An Intel Mac acts as the Host and an Apple Silicon Mac acts as the Viewer. The
Viewer sees and interacts with one selected macOS application window on the
Host; this is deliberately not a full remote-desktop product.

## Current status

The M0 Repository Foundation and M1 RemoteProtocol wire contract are complete.
The Host target is validated for both `x86_64` and `arm64` builds; the V1
physical Host target remains Intel, while the Viewer target is Apple Silicon.
The M2 secure LAN session implementation, PKCS#12/Keychain identity
provisioning, and real loopback mutual-TLS/session smoke test are complete.
The repository now includes a repeatable physical Intel Host to Apple Silicon
Viewer Bonjour/TLS/capability smoke harness and signed app-bundle packaging;
the actual two-machine run remains an environment evidence gate. M3 now
contains the Host window catalog
and ScreenCaptureKit capture foundation with deterministic fake-provider tests
and a successful M5 live frame smoke test. M4 now contains bounded H.264
VideoToolbox encode/decode adapters, decoder-generation recovery rules, and a
Viewer Metal presentation surface with deterministic layout/queue tests. The
repository still contains no clipboard product capability implementation. M5
adds the Viewer-side typed input foundation and authenticated event transport.
M6 now adds Host-side authorization-aware coordinate mapping and typed
CoreGraphics/Accessibility injection adapters with deterministic fake-adapter
tests. Actual OS event posting remains an explicit local evidence step.

The repository root is:

```text
MacRemoteApp/
├── README.md
├── Package.swift
├── Apps/
│   ├── Host/
│   └── Viewer/
├── Packages/
│   ├── RemoteProtocol/
│   ├── CaptureCore/
│   ├── CodecCore/
│   ├── TransportCore/
│   ├── InputCore/
│   └── SecurityCore/
├── Tests/
├── Resources/
│   ├── Host-Info.plist
│   ├── Viewer-Info.plist
│   └── MacRemoteAppIcon.svg
└── docs/
    ├── ARCHITECTURE.md
    ├── DEVELOPMENT_PLAN.md
    ├── M0_FOUNDATION.md
    ├── M1_PROTOCOL.md
    ├── M2_SESSION.md
    ├── M2_PHYSICAL_SMOKE.md
    ├── M3_CAPTURE.md
    ├── M4_CODEC.md
    ├── M5_INPUT.md
    ├── M6_INPUT_INJECTION.md
    ├── PRODUCT_SPEC.md
    ├── PROTOCOL.md
    └── SECURITY.md
```

The implementation repository is expected to grow toward this shape, while
keeping the package boundaries described in `docs/ARCHITECTURE.md`:

```text
MacRemoteApp/
├── Package.swift
├── Apps/
│   ├── Host/
│   └── Viewer/
├── Packages/
│   ├── RemoteProtocol/
│   ├── CaptureCore/
│   ├── CodecCore/
│   ├── TransportCore/
│   ├── InputCore/
│   └── SecurityCore/
└── Tests/
```

The exact M0 toolchain and architecture matrix are recorded in
`docs/M0_FOUNDATION.md`. The repeatable foundation validation uses Swift
Package Manager commands from the repository root.

## Physical M2 test

Use [`docs/M2_PHYSICAL_SMOKE.md`](docs/M2_PHYSICAL_SMOKE.md) to build the
universal Host/arm64 Viewer bundles, generate non-secret public certificate
files, and run the two-machine Bonjour/TLS smoke. The packaging source icon is
[`Resources/MacRemoteAppIcon.svg`](Resources/MacRemoteAppIcon.svg); generated
`.icns`, app bundles, and test identities stay outside version control.

## V1 in one paragraph

The Host discovers shareable applications/windows, lets the local user select
one window, captures it with ScreenCaptureKit, encodes H.264 with VideoToolbox,
and streams it over an authenticated LAN session. The Viewer discovers and
connects to the Host, renders the stream with Metal, and sends mouse and
keyboard events back to the selected foreground app. Both sides may exchange
text clipboard content according to the consent and privacy rules. The initial
target is 1080p at up to 60 fps with low measured latency.

## Technology baseline

- Swift 6 with strict concurrency checks.
- ScreenCaptureKit for Host-side window capture.
- VideoToolbox for H.264 encode/decode.
- Metal for Viewer-side frame presentation.
- Network.framework for LAN discovery and transport.
- CoreGraphics and Accessibility APIs for authorized input handling.
- Keychain-backed trust records through `SecurityCore`.

V1 does not include Internet NAT traversal, WebRTC, audio, file transfer, iPad
support, simultaneous multi-window control, background control, or
locked-screen control.

## Documents and authority

Read the documents in this order before implementation:

1. `docs/PRODUCT_SPEC.md` — user-visible behavior and acceptance targets.
2. `docs/ARCHITECTURE.md` — components, boundaries, and dependencies.
3. `docs/PROTOCOL.md` — session, framing, media, input, and clipboard design.
4. `docs/SECURITY.md` — threats, pairing, permissions, and privacy controls.
5. `docs/DEVELOPMENT_PLAN.md` — M0-M10 scope and verification gates.

The user's current request and later explicit corrections take precedence over
stale assumptions. Any resulting design change should be recorded in the
appropriate document before implementation.

## Roadmap

| Milestone | Outcome |
| --- | --- |
| M0 | Repository Foundation and build/test skeleton |
| M1 | RemoteProtocol types, framing, codec tests, and versioning |
| M2 | Secure LAN discovery, pairing, and session lifecycle |
| M3 | Host window discovery and ScreenCaptureKit capture |
| M4 | H.264 encode/decode and Metal presentation (complete; hardware smoke is opt-in) |
| M5 | Viewer mouse/keyboard capture and event transport (complete) |
| M6 | Host-side focus-aware input mapping and injection (implementation/test gate complete; OS evidence pending) |
| M7 | Text clipboard synchronization and session UX |
| M8 | Latency, frame-rate, backpressure, reconnect, and resilience work |
| M9 | Security hardening, permission/error review, and release readiness |
| M10 | Intel-to-Apple-Silicon V1 integration pilot and acceptance |

Each milestone is independently scoped in `docs/DEVELOPMENT_PLAN.md`. Do not
skip a gate because a later feature appears easy to prototype.
