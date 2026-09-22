# MacRemoteApp Product Specification

## Document status

This is the V1 product specification. It defines the user-visible goal and
acceptance boundaries; implementation details belong in the architecture and
protocol documents. The repository contains the M0 foundation, M1 wire
contract, M2 secure session, M3 capture, M4 codec/Metal, M5 Viewer input, M6
Host input, M7 clipboard/UX, M8 resilience, M9 release audit, and M10
production composition. M10 now wires the existing packages into launchable
Host and Viewer runtimes with TLS bootstrap, interactive two-sided pairing,
Keychain trust reuse, and a pre-authorized one-window path: one eligible
window is advertised and selected, captured, H.264 encoded, transported,
decoded, rendered, and paired with the existing authenticated input and
opt-in text clipboard paths. The actual Intel-to-Apple-Silicon run remains
environment-dependent. Physical OS event posting and the two-Mac
clipboard/performance evidence remain acceptance gates; the current pilot uses
the Viewer picker to select one eligible advertised window while the Host
remains authoritative for validation.

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

The exact supported macOS deployment target and toolchain matrix must be
verified and recorded in M0. No document should silently assume that an API is
available on every macOS version.

## Core user journeys

### Host setup and pairing

1. The Operator launches the Host.
2. The Host starts its Bonjour listener and requests Local Network access, then
   explains and requests Screen Recording at startup. Accessibility permission
   is requested only when the corresponding input capability is needed.
3. The Host advertises a non-sensitive LAN discovery record after its Local
   Network path is ready.
4. The Viewer finds the Host and requests a connection.
5. Both sides display a short pairing confirmation value. The local operator
   records consent on each intended endpoint after confirming that the values
   match; one person may perform both confirmations while physically using the
   two devices.
6. The devices store the resulting trust record and establish an authenticated
   session.

### Select and view one window

1. The Host lists eligible local applications/windows after Screen Recording
   authorization.
2. The Operator selects one window.
3. The Host starts a stream for that window only.
4. The Viewer displays the remote content with a visible connection and stream
   status.
5. The Operator may stop the session or explicitly change the selected window;
   there is never simultaneous multi-window control.

### Interact with the selected window

1. The Viewer captures pointer and keyboard events inside its remote-content
   surface.
2. The Viewer sends normalized coordinates, key data, modifiers, and ordering
   metadata through the authenticated session.
3. The Host accepts events only for the authorized selected window while it is
   eligible for foreground control.
4. The Host maps and injects events using the authorized CoreGraphics and
   Accessibility path.
5. If permissions, focus, authorization, or session health are lost, input is
   disabled and the Viewer shows a clear state.

### Exchange text clipboard content

1. Clipboard synchronization is opt-in per session and visibly indicated.
2. Only text is synchronized in V1; images, files, URLs as file promises, and
   arbitrary pasteboard types are out of scope.
3. Each side avoids echoing content that it just received from the other side.
4. Disconnecting disables synchronization and clears transient transport
   buffers.

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
  availability states without implying that disabled input is still active.
- **VIEWER-07**: Participate in opt-in text clipboard synchronization and
  clearly indicate when it is enabled.

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

## Quality targets

These are measurable V1 targets, not claims that the current planning package
has already verified them.

| Metric | Target and measurement rule |
| --- | --- |
| Resolution | Support a 1920×1080 capture/display configuration when the selected window and hardware permit it; negotiate a lower size when necessary. |
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
- Accessibility permission is required only for Host-side authorized input
  injection.
- Pairing is explicit and user-confirmed; LAN discovery alone never grants
  access.
- Input is disabled until the session is authenticated, paired, authorized for
  the selected window, and in a valid focus state.
- Clipboard synchronization is disabled by default unless the Operator enables
  it for the session.

## Explicitly out of scope for V1

- Internet NAT traversal or relay service.
- WebRTC or a browser-based Viewer.
- Audio capture, audio transport, or audio playback.
- File transfer, folder sharing, drag-and-drop file transfer, or arbitrary
  pasteboard types.
- iPadOS or iOS Viewer support.
- Simultaneous multi-window or multi-Viewer sessions.
- Background control of an unfocused application.
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
- Text clipboard synchronization works only when enabled and does not echo
  indefinitely or transfer non-text content.
- Permission loss, disconnect, stale authorization, malformed messages, and
  unsupported capabilities fail closed with actionable UI.
- M8 performance targets are measured and reported, and any missed target is
  explicitly documented rather than hidden.
- M9 security, privacy, and release-readiness checks pass.

## Open decisions to resolve in milestones

- Exact minimum macOS deployment target and supported Intel/Apple Silicon
  hardware matrix — M0.
- Final stream transport binding and whether a future datagram/QUIC path is
  necessary after the baseline is measured — M2/M8; no WebRTC in V1.
- Exact H.264 profile, bitrate/rate-control defaults, and decoder fallback —
  M4.
- User-facing pairing UX and Keychain trust reuse — M10; trust-record
  revocation UI remains a release-operations follow-up.
- Clipboard size limit, conflict policy, and text encoding edge cases — resolved
  in M7: 65,515 UTF-8 bytes, Offer/ACK/Text ordering, and deterministic
  arrival-order conflict handling.
