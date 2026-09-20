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
Viewer Bonjour/TLS/capability smoke harness, signed app/DMG packaging, and
role-specific install/uninstall scripts;
the actual two-machine run remains an environment evidence gate. M3 now
contains the Host window catalog
and ScreenCaptureKit capture foundation with deterministic fake-provider tests
and a successful M5 live frame smoke test. M4 now contains bounded H.264
VideoToolbox encode/decode adapters, decoder-generation recovery rules, and a
Viewer Metal presentation surface with deterministic layout/queue tests. M5
adds the Viewer-side typed input foundation and authenticated event transport.
M6 adds Host-side authorization-aware coordinate mapping and typed
CoreGraphics/Accessibility injection adapters with deterministic fake-adapter
tests. M7 now adds the opt-in text clipboard coordinator, bounded Offer/ACK/
Text flow, echo/conflict handling, explicit session UX projection, and Host/
Viewer AppKit string-pasteboard bridges. Physical OS event posting and the
two-machine clipboard walkthrough remain environment evidence steps. M8 now
includes the authenticated clock-sync/percentile model, deterministic
performance harness, bounded-queue stress coverage, and reconnect/keyframe
resilience evidence. M9 adds release-only debug gating, hardened-runtime
artifact audit, negative-test documentation, and a residual-risk record. M10
adds the deterministic final gate, the production Host/Viewer composition with
interactive pairing and Keychain trust reuse, and the two-machine acceptance
checklist.
The production path now wires window discovery/selection, ScreenCaptureKit,
H.264 encode/decode, Metal presentation, authenticated mouse/keyboard input,
and opt-in text clipboard synchronization. The Viewer presents the eligible
Host windows in a picker so a system/helper window is not selected silently.
The interactive pairing UI is implemented with Keychain trust reuse. The
actual Intel-to-Apple-Silicon run and OS Accessibility/input evidence remain
environment gates until they are executed on both Macs.

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
    ├── M7_CLIPBOARD_UX.md
    ├── M8_PERFORMANCE_RESILIENCE.md
    ├── M9_SECURITY_RELEASE.md
    ├── M10_ACCEPTANCE.md
    ├── POST_V1_ROADMAP.md
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
files, and run the two-machine Bonjour/TLS smoke. `scripts/package-device-apps.sh`
also creates local signed role-specific DMGs under
`build/testing/`; this package-only output is not a
notarized distribution. `scripts/release-notarized.sh` is the required final
test path: it runs the repository validation (`.codex/ci.sh` when available,
otherwise `scripts/validate.sh`), signs, submits, staples, and validates the
notarized apps and DMGs. Its default output is the repository-local
`build/release/` directory, outside `.build`. Local artifacts are organized as
`build/testing/`, `build/beta/`, `build/rc/`, and `build/release/`; the
`build/` tree is excluded through the checkout-local `.git/info/exclude`
(configured automatically by the packaging script) and must never be staged or
pushed to GitHub. The flow stages a new release beside the selected channel
and promotes it only after notarization validation succeeds, preserving the
previous channel output if a run fails. Pass `beta` or `rc` to
`scripts/release-notarized.sh` to target those channels.
The lower-level `scripts/notarize-device-apps.sh` remains available for the
notarization step itself and accepts only an absent or empty output directory.
`scripts/install-device-apps.sh` and `scripts/uninstall-device-apps.sh` manage
the exact app bundles in `~/Applications`. To remove ad-hoc testing residue,
run `scripts/uninstall-device-apps.sh --clean-testing --yes`; add
`--identities "$HOME/MacRemoteApp-identities"` when that disposable M2
identity directory and its matching imported Keychain identities should also
be removed. On a physical-test Mac that keeps only its local `.p12` and the
opposite device's `.cer`, export `MACREMOTEAPP_P12_PASSWORD` for the cleanup
run so the local certificate fingerprint can be checked without printing the
password. If that verification cannot be completed, the identity directory is
preserved for a safe retry. Without `--identities`, imported M2 Keychain
identities are preserved. This preserves `build/beta/`,
`build/rc/`, and `build/release/`. The packaging source icon is
[`Resources/MacRemoteAppIcon.svg`](Resources/MacRemoteAppIcon.svg); generated
`.icns`, app bundles, and test identities stay outside version control.

The repository validation and deterministic M10 gate write temporary build
packages under `.build/` while running. A successful `.codex/ci.sh` removes
that cache; a failed run retains it for diagnosis. To validate an already
notarized release directly, set `MACREMOTEAPP_CI_NOTARIZED_RELEASE_ROOT` to an
external release directory when running `.codex/ci.sh`.
`scripts/validate-notarized-release.sh` is read-only with respect to the
release payload and never submits credentials or uploads artifacts.

## M10 production pilot

The installed Host and Viewer binaries start their production runtime when
launched without debug-only smoke arguments. They require a provisioned
Keychain identity. On the first connection, omit `MACREMOTEAPP_PEER_CERT` to
use the interactive Host/Viewer pairing flow:

```bash
open ~/Applications/MacRemoteApp-Host.app
open ~/Applications/MacRemoteApp-Viewer.app
```

The Host displays a one-time code and asks for local approval; the Viewer
displays the same code and asks the operator to enter it. Both endpoints store
the resulting peer identity in the Keychain only after local and remote
consent complete. `MACREMOTEAPP_PEER_CERT` remains an optional pinned-peer
migration/diagnostic mode; it is not required for new installations.

Debug builds may load a PKCS#12 identity through the existing
`MACREMOTEAPP_LOCAL_IDENTITY_P12` and `MACREMOTEAPP_P12_PASSWORD` test
workflow; those variables are not compiled into release behavior. The current
pilot uses the existing one-window selection protocol and a Viewer picker; the
Host remains authoritative and validates the selected generation. Use
[`docs/M10_ACCEPTANCE.md`](docs/M10_ACCEPTANCE.md) for the
required permissions, local identity provisioning, pairing flow, and physical
evidence; a successful local build is not a two-Mac acceptance result. Future
capabilities are recorded in
[`docs/POST_V1_ROADMAP.md`](docs/POST_V1_ROADMAP.md).

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
| M7 | Text clipboard synchronization and session UX (implementation/test gate complete; physical walkthrough pending) |
| M8 | Performance/resilience implementation and deterministic evidence (physical report pending) |
| M9 | Security hardening, signed app/DMG release audit, install lifecycle, and notarization helper (current notarized artifacts verified; profile remains host-specific) |
| M10 | Production Host/Viewer vertical slice, interactive pairing, and acceptance checklist (physical Intel-to-Apple-Silicon acceptance pending) |

Each milestone is independently scoped in `docs/DEVELOPMENT_PLAN.md`. Do not
skip a gate because a later feature appears easy to prototype.
