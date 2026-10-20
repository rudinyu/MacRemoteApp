# MacRemoteApp Product Specification

## Document status

This is the V1 product specification. It defines the user-visible goal and
acceptance boundaries; implementation details belong in the architecture and
protocol documents. Current milestone state and open evidence gaps are
tracked in [the status page](STATUS.md).

The [P6 extension](P6_BACKGROUND_CONTROL.md) adds opt-in pairing and control-
generation checks for Host input. The selected app must be foreground before
input is available; the Host may activate it after explicit selection. The
Host continues to capture the selected window independently of the app's
foreground state. Peers without P6 use the same foreground-only input path.
P6 never permits
locked-screen, login-window, secure-input, or system authentication-dialog
control.

## Product goal

Allow a user at an Apple Silicon Mac (the Viewer) to view and interact with one
selected macOS application window running on an Intel Mac (the Host) over a
trusted local-area network.

MacRemoteApp is not intended to be a general-purpose remote desktop. V1 keeps
the control surface narrow: one active window, one Viewer session, LAN only,
mouse and keyboard interaction, and text clipboard exchange.

## Users and terms

- **Host** — the Intel Mac that owns the application window, captures its
  pixels, and performs authorized input injection.
- **Viewer** — the Apple Silicon Mac that displays the remote window and sends
  user input.
- **Operator** — the person who approves pairing and selects the window on the
  Host. The Operator may also use the Viewer.
- **Selected window** — the single shareable window currently streamed and
  eligible for input. A session never controls multiple windows at once.
- **Session** — an authenticated, paired, user-authorized Host/Viewer
  connection.

## V1 target environment

| Area | V1 target |
| --- | --- |
| Host hardware | Intel Mac |
| Viewer hardware | Apple Silicon Mac |
| Network | Same trusted LAN; no Internet traversal requirement |
| Platform APIs | Swift 6, ScreenCaptureKit, VideoToolbox, Metal, Network.framework, CoreGraphics, Accessibility APIs |
| Video | H.264, target 1080p, up to 60 fps |
| Interaction | Mouse, keyboard, and text clipboard |
| Connection | Explicit discovery, pairing, authentication, and session authorization |

The Host executable is build-compatible with both `x86_64` and `arm64`; the V1
integration target remains a physical Intel Host and an Apple Silicon Viewer.
Build compatibility does not claim Host runtime, permission, or cross-machine
interoperability on Apple Silicon.

**Platform lifespan risk.** Apple has announced that macOS 26 Tahoe is the
last macOS release for Intel Macs. An Intel-only Host therefore stops
receiving macOS feature updates after that release, and ScreenCaptureKit or
VideoToolbox behavior on Intel will not track newer releases. V1 keeps the
Intel Host target, but an Apple Silicon Host is the expected successor: keep
the `arm64` Host build green, avoid Intel-specific encoder assumptions, and
run an Apple Silicon Host smoke before any post-V1 platform decision.

The exact supported macOS deployment target and toolchain matrix must be
verified and recorded in M0. No document should silently assume that an API is
available on every macOS version.

## Core user journeys

### Host setup and pairing

1. The Operator launches the Host.
2. The Host requests Screen Recording at startup before waiting for Bonjour
   readiness, then starts its listener so macOS can request Local Network
   access. PostEvent permission is requested only when the corresponding input
   capability is needed; Accessibility is optional for legacy and foreground
   P6 input. P6 uses target-process inspection only to classify an inactive
   target for safe cleanup; this never enables inactive-process input.
3. The Host advertises a non-sensitive LAN discovery record after its Local
   Network path is ready.
4. The Viewer finds the Host and requests a connection.
5. Both sides display a short pairing confirmation value. The local operator
   records consent on each intended endpoint after confirming that the values
   match; one person may perform both confirmations while physically using the
   two devices.
6. The devices store the resulting trust record and establish an authenticated
   session.
7. The Host name shown during discovery may be changed from the Host status
   menu. Either endpoint can explicitly forget saved peer trust to recover
   from a stale or one-sided pairing record.

### Select and view one window

1. The Host lists eligible local applications/windows after Screen Recording
   authorization.
2. The Operator selects one window. The catalog may include titled offscreen
   windows of regular apps; selecting one asks the Host to reveal and foreground
   that app before capture.
3. The Host starts a stream for that window only. Selection and foreground
   activation do not authorize input; the existing independent input checks
   still apply.
4. The Viewer displays the remote content with a visible connection and stream
   status.
5. The Operator may stop the session or explicitly change the selected window;
   the Viewer can request an eligible app switch in the same session. The Host
   may foreground the explicitly selected regular application for every peer.
   With P6, accepted pairing and control-generation checks add authorization;
   they do not enable inactive-process input. The Viewer may keep displaying
   the selected app while it is inactive, but input stays disabled until the
   selected PID is foreground. Being occluded does not stop the selected-window
   stream. A short missing catalog snapshot does not revoke the active
   selection; if ScreenCaptureKit ends the stream, CaptureCore makes bounded
   restart attempts only after checking the same window ID, bundle ID, PID,
   layer, and geometry. Confirmed target loss stops the stream, releases held
   input, and ends the selection while the session stays connected so another
   window can be chosen; Screen Recording permission loss ends the session. The Host menu-bar icon is tinted and
   the status menu names the shared app and its capture state. There is never
   simultaneous multi-window control.

### Interact with the selected window

1. The Viewer captures pointer and keyboard events inside its remote-content
   surface.
2. The Viewer sends normalized coordinates, key data, modifiers, and ordering
   metadata through the authenticated session.
3. The Host accepts events only for the authorized selected target and only
   while its PID is frontmost with the selected window still eligible. P6 adds
   Host pairing, control-generation, and target safety checks.
4. The Host maps and injects events through the public system Quartz/PostEvent
   path; on explicit window selection, Accessibility may optionally raise the
   uniquely matched selected window. Foreground P6 follows the same global
   secure-input policy as legacy input; target-process inspection is limited to
   safe cleanup classification for inactive targets.
5. If permissions, focus, authorization, or session health are lost, input is
   disabled and the Viewer shows a clear state.

### Follow the Viewer input source (approved M10 extension)

1. When both peers authorize `inputSourceSync`, the focused Viewer remote
   surface requests the actual selected Chinese/English source state before
   delivering keyboard input. The Host sets that state rather than replaying
   a toggle: EN to an already-English Host is a no-op.
2. Chinese requires the same enabled input-source/mode identifier on the Host.
   A missing or disabled source pauses keyboard delivery with an actionable
   status; it must not silently substitute another Chinese input method.
3. The Host still performs composition and candidate selection. This does not
   add Viewer-side composed-text insertion or background control. Leaving the
   remote surface stops source synchronization; no Host source restoration is
   attempted in the background.
4. Window replacement, reauthorization, reconnect, and returning to the remote
   surface require fresh synchronization. A late acknowledgement cannot
   release keyboard input belonging to a different source request or session.
5. Older peers retain manual Host input-source selection. See
   [ADR-0007](decisions/0007-m10-input-source-following.md) for the bounded
   optional protocol and unsupported third-party internal IME modes.

### Exchange text clipboard content

1. Host acceptance of pairing is the durable local trust grant for input and
   negotiated text clipboard. There is no separate Host clipboard consent
   dialog. The Viewer must opt in locally for each session before text flows.
2. Clipboard synchronization is visibly indicated while enabled.
3. Only text is synchronized in V1; images, files, URLs as file promises, and
   arbitrary pasteboard types are out of scope.
4. Each side avoids echoing content that it just received from the other side.
5. Disconnecting clears transient transport buffers and disables the Viewer
   opt-in; saved Host pairing trust is reused on reconnect but does not opt the
   Viewer in.

### Settings and standard macOS controls

1. Both apps expose About with version/build, Settings (`Command-,`), Services,
   Hide (`Command-H`), Hide Others, Show All, and Quit (`Command-Q`), plus File
   Close (`Command-W`) and Window Minimize (`Command-M`), Zoom, Show App
   (`Command-0`), and Bring All to Front. These commands operate locally.
2. Viewer Settings replaces the remote view in the same main window. Back to
   Remote View, Command-0, or Close on that page restores the remote view.
   Switching pages preserves the session and releases held remote input;
   closing the remote-view window itself quits the Viewer. About may use a
   separate information window, but Settings must not open a second window.
3. Viewer Settings shows current connection, Host, LAN/TLS transport, discovery,
   RTT, input readiness, details, and clipboard state. Host filter, trust mode,
   and reconnect policy are read-only. The clipboard action uses the existing
   session-only opt-in; Local Network Settings and confirmed pairing reset
   remain explicit actions.
4. The Host status menu also opens About and Settings. The Host remains resident
   when Settings closes. While Settings/About is open or minimized, standard
   app menus and Dock restoration are available; after both close, it returns
   to menu-bar operation. Host Settings shows its name, runtime state,
   LAN/TLS, trust mode, and read-only Screen Recording/PostEvent/optional
   Accessibility checks, with Rename, Retry, privacy settings, and pairing
   reset actions. Permission checks refresh when the Host becomes active.
5. Discovery/browser/service activity must not be presented as a direct
   macOS Local Network permission check. Status is informational and never
   substitutes for the existing permission, trust, and input authorization gates.

## Functional requirements

### Host requirements

- **HOST-01**: Enumerate eligible running applications and shareable windows
  after the required permission is granted.
- **HOST-02**: Let the Operator select exactly one active window for a session.
- **HOST-03**: Capture only the selected window through ScreenCaptureKit; do
  not capture the entire desktop by default.
- **HOST-04**: Encode captured frames as H.264 through VideoToolbox and expose
  timestamps, dimensions, and keyframe metadata.
- **HOST-05**: Advertise a discoverable LAN endpoint without exposing
  credentials or clipboard contents.
- **HOST-06**: Authenticate and authorize the Viewer before sending protected
  window content or accepting input.
- **HOST-07**: Inject only permitted input into the eligible selected window;
  reject input when focus, permission, pairing, or session state is invalid.
- **HOST-08**: Report permission loss, capture failure, stream failure, and
  authorization changes as actionable states.
- **HOST-09**: Let the Operator change the Host's Bonjour display name and
  explicitly forget saved peer trust without deleting the Host's local device
  identity. Default the display name to the Host Mac's short hostname.
- **HOST-10**: Provide the resident Settings/About lifecycle above. Closing or
  minimizing Settings must not stop the listener or active session; Quit must
  perform normal session shutdown.

### Viewer requirements

- **VIEWER-01**: Discover Host endpoints on the local network and show enough
  non-sensitive information for the Operator to choose one.
- **VIEWER-02**: Complete pairing and authenticated session setup with clear
  confirmation and failure states.
- **VIEWER-03**: Display the selected window stream with correct aspect ratio,
  frame ordering, and resize behavior.
- **VIEWER-04**: Capture mouse movement, buttons, scrolling, keyboard keys, and
  modifiers inside the remote-content surface.
- **VIEWER-05**: Send only events that belong to the active authenticated
  session and selected window.
- **VIEWER-06**: Show connection, authorization, permission, stream, and input
  availability states without implying that disabled input is still active;
  show Connected and disable duplicate connection actions while connected.
- **VIEWER-07**: Participate in opt-in text clipboard synchronization and
  clearly indicate when it is enabled.
- **VIEWER-08**: Send the Viewer Mac's bounded short hostname as optional
  display-only pairing metadata; it must never be used for authentication or
  authorization.
- **VIEWER-09**: Use a single main window for remote view and Settings, preserve
  the session during navigation, release held input on leaving the surface,
  and keep local settings/menu interactions out of remote input delivery.
- **VIEWER-10**: Display Connecting, Connected, Reconnecting, or Disconnected
  independently of input readiness. Show LAN/TLS, Host, RTT, FPS, release, and
  protocol information without stale connected data after disconnect; input
  must read Not connected while disconnected.
- **VIEWER-11**: Follow the focused Viewer's actual Chinese/English input
  source when negotiated, keep switching shortcuts local, and show pending,
  synchronized, or unavailable states without sending keyboard input before
  the matching Host acknowledgement.

### Shared requirements

- **SHARED-01**: Negotiate protocol version and capabilities before starting a
  video stream.
- **SHARED-02**: Bound all decoded lengths, queues, event rates, and clipboard
  payloads before allocating or processing them.
- **SHARED-03**: Preserve message ordering for control/input and tolerate
  dropped or superseded video frames without applying stale input state.
- **SHARED-04**: Expose structured diagnostics that do not contain secrets,
  raw clipboard text, or unnecessary user data.
- **SHARED-05**: Shut down safely when either side disconnects, revokes a
  permission, or loses session authorization.
- **SHARED-06**: Provide the native app/window commands above and expose the
  same release identity in About, Settings, and role-specific status UI.
- **SHARED-07**: Use `major.minor.build` for the product release identity.
  For example, `0.2.1003` means Version `0.2` and Build `1003`; store them in
  `CFBundleShortVersionString` and `CFBundleVersion`, respectively. The final
  component is the build number, not a patch version. Wire protocol versioning
  remains independent. Testing, beta, and RC distribution filenames include
  this version; only formal release filenames may omit it. Installed app
  names and bundle identifiers remain stable.
- **SHARED-08**: Provide a confirmed current-user clean-uninstall script for
  verified installations, role-owned settings/Keychain data, and bundle-scoped
  TCC decisions. Report failures and missing cleanup helpers. Explain that
  Local Network requires separate manual revocation and historical entries
  cannot be removed through a supported macOS reset command. Never reset
  unrelated apps' permissions or delete release/source artifacts. Include the
  full-cleanup script in both Host and Viewer DMGs with a verified payload hash.

## Quality targets

These are measurable V1 targets, not claims that the current planning package
has already verified them.

| Metric | Target and measurement rule |
| --- | --- |
| Resolution | Support a 1920×1080 capture/display configuration when the selected window and hardware permit it; negotiate a lower size when necessary. Dimensions are encoded pixels: the Host captures at the window's backing scale (Retina = 2 pixels per point) and downscales with preserved aspect ratio to fit 1920×1080 pixels; see [the M3 output resolution policy](M3_CAPTURE.md#output-resolution-policy). |
| Frame rate | Target 60 fps on the LAN path; provide a stable 30 fps fallback when the target cannot be sustained. Measure delivered frames over a defined 30-second window. |
| End-to-end latency | Target p95 under 50 ms from a Host capture timestamp to the corresponding Viewer presentation timestamp on a controlled LAN benchmark. Report p50 and p95, not only an average. Before sampling, exchange authenticated monotonic-clock timestamps over at least 20 Ping/Pong probes; estimate clock offset from the minimum-RTT sample and report the residual offset uncertainty and drift. Exclude warm-up samples, measure for 30 seconds with at least 1,000 valid frame samples, and mark one-way latency unverified when clock uncertainty exceeds 5 ms. |
| Interaction latency | Measure input send-to-observable-result on a documented test app; report p50/p95 and conditions. |
| Backpressure | A slow Viewer must not cause unbounded Host capture, encode, or memory queues. Prefer a recent frame over stale frames. |
| Recovery | A temporary LAN interruption must result in a visible session state and a bounded reconnect/reauthorization path; do not silently resume unsafe input. |
| Compatibility | Verify at least one Intel Host and one Apple Silicon Viewer using the M0 deployment matrix before V1 acceptance. |

M8 owns the benchmark harness and records the exact hardware, macOS version,
network conditions, resolution, frame rate, clock-sync probe count, estimated
offset, uncertainty, drift, valid sample count, p50, p95, and measurement
method. Viewer presentation timestamps must be taken at the actual display
handoff, not when a frame merely enters a render queue. If clock alignment is
not within the stated uncertainty bound, report a separate authenticated
round-trip measurement instead of claiming a one-way latency result.

The repository's deterministic M8 harness validates the measurement math,
queue bounds, and report schema only. It is not physical performance evidence.
M10 must attach a sanitized report from the Intel Host and Apple Silicon
Viewer run before the one-way latency and 1080p/60 acceptance items are
marked verified.

## Permissions and consent

- Screen Recording permission is required for Host window capture.
- PostEvent permission is required only for Host-side authorized input
  injection. Accessibility is optional for legacy and foreground P6 input and
  for best-effort exact-window raising; P6 uses known-safe global and
  target-process inspection only for inactive-target cleanup.
- Pairing is explicit and user-confirmed; LAN discovery alone never grants
  access. Host acceptance of pairing also provides durable Host-local input
  trust for that Viewer; a separate Host control-consent prompt is not shown.
  Unpairing removes that trust and ends the active session. The Viewer retains
  a separate local opt-in for text clipboard synchronization.
- Input is disabled until the session is authenticated, paired, authorized for
  the selected target, the selected PID is foreground, and applicable P6
  process-safety checks pass.
- Clipboard synchronization is disabled by default unless the Operator enables
  it locally in Viewer Settings for that session. Host pairing trust enables
  the negotiated Host-side bridge without a separate Host prompt.

## Explicitly out of scope for V1

- Internet NAT traversal or relay service.
- WebRTC or a browser-based Viewer.
- Audio capture, audio transport, or audio playback.
- File transfer, folder sharing, drag-and-drop file transfer, or arbitrary
  pasteboard types.
- iPadOS or iOS Viewer support.
- Simultaneous multi-window or multi-Viewer sessions.
- Locked-screen, login-window, secure-input, or system authentication-dialog
  control.
- Remote privilege escalation, credential collection, or bypass of macOS
  permission prompts.
- Cloud account, analytics, or remote relay dependency.

The ordered proposals for capabilities outside V1 are recorded in
`docs/POST_V1_ROADMAP.md`. They are not part of M10 acceptance and must not be
implemented as compatibility fallbacks.

## V1 acceptance checklist

V1 is acceptable only when all of the following are demonstrated on the
documented compatibility matrix:

- An Operator can pair a Viewer to a Host on the same LAN and see a clear
  authenticated state.
- The Host can enumerate and select one eligible application window.
- The Viewer receives and renders that window at the negotiated resolution and
  a stable frame rate.
- Pointer, keyboard, and modifier input reaches only the authorized selected
  foreground window when permissions and focus are valid.
- Text clipboard synchronization requires accepted Host pairing, negotiated
  capability, and the Viewer-local opt-in; it does not echo indefinitely or
  transfer non-text content.
- Permission loss, disconnect, stale authorization, malformed messages, and
  unsupported capabilities fail closed with actionable UI.
- M8 performance targets are measured and reported, and any missed target is
  explicitly documented rather than hidden.
- M9 security, privacy, and release-readiness checks pass.
- Both roles' menus and version/build displays work. Viewer Settings stays
  within the main window during an active session, and returning does not
  leave held input or require another connection. Host Settings closes without
  quitting the resident Host.
- Test handoff includes scoped removal of test installations, settings,
  trust/generated identities, permissions, and dedicated review output, with
  absence verified and source/release artifacts preserved, unless retaining
  test state was explicitly requested. Follow [the cleanup runbook](TESTING_CLEANUP.md).

## Open decisions to resolve in milestones

- Exact minimum macOS deployment target and supported Intel/Apple Silicon
  hardware matrix — M0.
- Whether a post-V1 release adds Apple Silicon as a supported Host platform,
  given the Intel platform lifespan risk above — post-V1 decision; V1 does not
  change the Intel Host target.
- Final stream transport binding and whether a future datagram/QUIC path is
  necessary after the baseline is measured — M2/M8; no WebRTC in V1.
- Exact H.264 profile, bitrate/rate-control defaults, and decoder fallback —
  M4.
- User-facing pairing UX, Keychain trust reuse, trust-record revocation UI,
  and editable Host discovery name — implemented in M10; physical recovery
  walkthrough remains an acceptance item.
- Clipboard size limit, conflict policy, and text encoding edge cases — resolved
  in M7: 65,515 UTF-8 bytes, Offer/ACK/Text ordering, and deterministic
  arrival-order conflict handling.
- Host cursor shape on the Viewer (the capture currently hides the cursor, and
  no message carries its shape) — post-V1, not an M0–M10 requirement; option
  (b), an optional enumerated `CursorState` message, was chosen and is pending
  its P0.5 milestone definition.
  The options and security notes are in
  [the post-V1 roadmap](POST_V1_ROADMAP.md#open-decision-host-cursor-shape).
