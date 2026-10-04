# MacRemoteApp

MacRemoteApp is a LAN-first macOS application remote-view and control tool.
An Intel Mac acts as the Host and an Apple Silicon Mac acts as the Viewer. The
Viewer sees and interacts with one selected macOS application window on the
Host; this is deliberately not a full remote-desktop product.

## Current status

Milestone state and open evidence gaps are tracked in one place:
[`docs/STATUS.md`](docs/STATUS.md).

The current release candidate is `0.2.1007` (Version `0.2`, Build `1007`),
including the capture, input, reconnect, and presentation reliability fixes.
Signed/notarized artifact evidence is recorded in [`docs/STATUS.md`](docs/STATUS.md);
passing local tests does not replace the pending two-Mac acceptance run.

## Native app shell

Both roles now have native macOS About, Settings, Hide, Minimize, and Quit
commands. Viewer Settings replaces the remote view in its existing main
window; Back, Command-0, or Command-W on that page returns to the remote view.
The Host remains a menu-bar app, with a temporary Dock icon while its Settings
or About window is open. Settings shows current runtime/permission information
without replacing the session's authorization checks. Release identifiers use
`major.minor.build`: `0.2.1003` is Version `0.2`, Build `1003`, stored separately
in the bundle metadata. See the [UI architecture](docs/ARCHITECTURE.md#native-app-shell-and-release-identity)
and [product requirements](docs/PRODUCT_SPEC.md#settings-and-standard-macos-controls).

The user-facing documents are [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md),
[`docs/DEBUGGING.md`](docs/DEBUGGING.md), and
[`docs/DEBUG_LOG_COLLECTION.md`](docs/DEBUG_LOG_COLLECTION.md). The DMG
packaging flow puts plain-text copies of all three documents beside the app,
the per-user `Applications` drop target, and optional role-specific install
and uninstall commands in every newly generated Host and Viewer DMG. The DMG
commands are user-facing, double-click-only helpers: they have no CI, testing,
ad-hoc, arbitrary-path, or repository-cleanup options.

The repository root is:

```text
MacRemoteApp/
├── README.md
├── Package.swift
├── Apps/
│   ├── Host/
│   └── Viewer/
├── Packages/
│   ├── AppSupport/
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
    ├── USER_GUIDE.md
    ├── DEBUGGING.md
    ├── DEBUG_LOG_COLLECTION.md
    ├── TESTING_CLEANUP.md
    ├── PRODUCT_SPEC.md
    ├── PROTOCOL.md
    ├── SECURITY.md
    ├── STATUS.md
    └── decisions/
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
│   ├── AppSupport/
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
test path: it runs the canonical `scripts/validate.sh` validation directly,
then signs, submits, staples, and validates the
notarized apps and DMGs. Its default output is the repository-local
`build/release/` directory, outside `.build`. Local artifacts are organized as
`build/testing/`, `build/beta/`, `build/rc/`, and `build/release/`; the
`build/` tree is excluded through the checkout-local `.git/info/exclude`
(configured automatically by the packaging script) and must never be staged or
pushed to GitHub. The release flow acquires a repository-local kernel-backed
`lockf` file lock and removes the repository `.build` cache before deterministic
validation. The operating system releases the advisory lock when the process
ends, so an interrupted run does not leave a PID/reclaim race; unexpected
directory or symlink lock paths fail closed. The
existing selected channel remains available while signing and notarization run;
the new release is staged beside it and promoted only after notarization
validation succeeds. A failed run before promotion leaves the existing channel
untouched; a failure during promotion restores the previous known-good channel.
The selected channel is protected by a repository-local `lockf` file lock, and
`MACREMOTEAPP_RELEASE_ROOT` must match that channel; concurrent release
runs and cross-channel promotion are rejected. Pass `beta` or `rc` to
`scripts/release-notarized.sh` to target those channels.
The lower-level `scripts/notarize-device-apps.sh` remains available for the
notarization step itself and accepts only an absent or empty controlled staging
directory; it refuses direct writes to `build/beta`, `build/rc`, and
`build/release`, which require the lock-protected promotion flow.
Both notarization entry points pass the named Keychain profile directly to
each `notarytool submit`; the submit operation is the authoritative profile
check for the actual release path. `scripts/check-notary-profile.sh` remains
an optional history-based diagnostic, but it is not a release gate because a
Codex runner may reject the separate `history` operation even when the actual
submit path can read the profile.
The repository-only `scripts/install-device-apps.sh` and
`scripts/uninstall-device-apps.sh` manage exact app bundles and disposable test
state for development. They are not copied into a DMG. The DMG's
role-specific helpers only install a verified app into `~/Applications` or
move that exact per-user app to the Trash; the DMG also includes the User
Guide, How to Debug, and How to Collect Debug Logs text files. Users may drag
the app onto the DMG's `Applications` drop target to install into their own
`~/Applications`, or use the optional helper. The DMG uninstall helper verifies
the selected Developer ID/Gatekeeper-accepted app and any installed opposite
role, quits installed MacRemoteApp roles, and asks each role's signed app to
clear its own Keychain trust and generated identity before moving only the
selected app to the user's Trash. It also clears both roles' exact per-user
app-state paths. It refuses ad-hoc or modified testing bundles and does not
reset macOS TCC grants; use System Settings when a fresh privacy decision is
needed. Legacy shared Keychain records from earlier builds are preserved and
not used by the new role-specific runtime. After every local UI/installation
test, follow [UI Review and Post-test Cleanup](docs/TESTING_CLEANUP.md) to stop
the test apps, remove scoped installation/settings/identity state, reset their
permissions, and verify cleanup while preserving source and release artifacts.
For an explicitly intended broad development reset, preview
`scripts/uninstall-device-apps.sh --clean-testing --dry-run` before using
`--yes`. This broader helper removes the whole `.build/` and is not a substitute
for current per-role app-data cleanup; add
`--identities "$HOME/MacRemoteApp-identities"` when that disposable M2
identity directory and its matching imported Keychain identities should also
be removed. On a physical-test Mac that keeps only its local `.p12` and the
opposite device's `.cer`, export `MACREMOTEAPP_P12_PASSWORD` for the cleanup
run so the local certificate fingerprint can be checked without printing the
password. If that verification cannot be completed, the identity directory is
preserved for a safe retry. Without `--identities`, imported M2 Keychain
identities are preserved. The DMG uninstall is intentionally a full
MacRemoteApp reset: if the other role remains installed, it must enroll a new
local identity and pair again. This preserves `build/beta/`,
`build/rc/`, and `build/release/`. The packaging source icon is
[`Resources/MacRemoteAppIcon.svg`](Resources/MacRemoteAppIcon.svg); generated
`.icns`, app bundles, and test identities stay outside version control.

The public repository validation entry point is `bash scripts/validate.sh`.
It builds both roles, tests all seven local packages (including AppSupport),
and runs the deterministic M8/M9/M10 gates. Its scratch directory is
`.build/public-validation/`; a successful run removes only that directory,
while a failed run retains it for diagnosis. It does not uninstall apps or
clear their settings. To validate an already notarized release directly, run
`bash scripts/validate-notarized-release.sh <absolute-release-directory>`.
`scripts/validate-notarized-release.sh` is read-only with respect to the
release payload and never submits credentials or uploads artifacts.

## M10 production pilot

The installed Host and Viewer binaries start their production runtime when
launched without debug-only smoke arguments. On first launch, each endpoint
creates or reuses a role-specific P-256 TLS identity in the login Keychain.
The identity labels are `MacRemoteApp.host` and `MacRemoteApp.viewer`; peer
trust is kept in a separate Keychain service for each role. No
`host.p12` or `viewer.p12` is required for the production path. On the first
connection, omit `MACREMOTEAPP_PEER_CERT` to use the interactive Host/Viewer
pairing flow:

```bash
open ~/Applications/MacRemoteApp-Host.app
open ~/Applications/MacRemoteApp-Viewer.app
```

The Host and Viewer complete a MacKVM-style two-sided commit/reveal exchange:
both endpoints commit to fresh random contributions before either reveal, then
derive the same six-digit one-time comparison code independently. The Host
displays it and asks for local approval; the Viewer displays the same code and
asks the operator to compare it and select **Accept** or **Deny**. Neither side
creates new trust from remote approval alone: each endpoint stores the peer
identity in the Keychain only after its local consent policy and the matching
remote consent complete. A matching trust already saved on one endpoint may
satisfy that endpoint's prior approval. The Host
requests Screen Recording before waiting for Bonjour
readiness, then starts Bonjour to trigger Local Network consent. It requests
PostEvent input permission from its signed app bundle only after a Viewer
negotiates input and the operator selects a window. Accessibility is requested
as an optional AX/secure-input enhancement; without PostEvent permission it
remains view-only. After the Host authorizes text clipboard for
the session, the Viewer exposes an explicit clipboard opt-in toggle.
`MACREMOTEAPP_PEER_CERT` remains an optional pinned-peer
migration/diagnostic mode; it is not required for new installations.

Debug-only smoke builds may load a PKCS#12 identity through the existing
`MACREMOTEAPP_LOCAL_IDENTITY_P12` and `MACREMOTEAPP_P12_PASSWORD` test
workflow; those variables are not required for, or used by, normal release
launches. The current pilot uses the existing one-window selection protocol and
a Viewer picker; the Host remains authoritative and validates the selected
generation. Use
[`docs/M10_ACCEPTANCE.md`](docs/M10_ACCEPTANCE.md) for the
required permissions, automatic local identity enrollment, pairing flow, and
physical evidence; a successful local build is not a two-Mac acceptance
result. Future
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

`docs/STATUS.md` is the single source for milestone state and evidence gaps,
and `docs/decisions/` holds milestone-scoped decision records.

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
| M4 | H.264 encode/decode and Metal presentation |
| M5 | Viewer mouse/keyboard capture and event transport |
| M6 | Host-side focus-aware input mapping and injection |
| M7 | Text clipboard synchronization and session UX |
| M8 | Performance/resilience implementation and deterministic evidence |
| M9 | Security hardening, signed app/DMG release audit, install lifecycle, and notarization helper |
| M10 | Production Host/Viewer vertical slice, interactive pairing, and acceptance checklist |

Per-milestone completion and pending evidence are in
[`docs/STATUS.md`](docs/STATUS.md).

Each milestone is independently scoped in `docs/DEVELOPMENT_PLAN.md`. Do not
skip a gate because a later feature appears easy to prototype.
