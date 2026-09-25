# MacRemoteApp Protocol Design

## Protocol status and scope

This document defines the V1 LAN session contract at design level. It is the
source for `Packages/RemoteProtocol` and `Packages/TransportCore`; it does not
authorize implementing later milestone behavior early.

The protocol supports one Viewer, one selected Host window, authenticated
control, H.264 video, mouse/keyboard input, and opt-in text clipboard exchange.
It excludes Internet traversal, WebRTC, audio, file transfer, arbitrary
pasteboard types, multi-window sessions, background control, and locked-screen
control.

## Transport binding

### Discovery

- Use Bonjour service discovery through Network.framework.
- Advertise a stable service type documented by the implementation, with a
  versioned instance name and non-sensitive capability metadata.
- Discovery metadata is advisory and untrusted. It must not contain pairing
  secrets, trust records, clipboard text, or window pixels.
- The Viewer must handle duplicate, stale, malformed, and disappearing service
  records.

### Connection

- Use Network.framework for connection lifecycle and path monitoring.
- Establish an authenticated TLS 1.3 session according to
  `docs/SECURITY.md` before protected control, video, input, or clipboard data
  is accepted.
- Network.framework peer authentication is required on every connection. A
  bootstrap connection may identify an unknown certificate for pairing, but a
  missing peer identity or failed certificate verification is never an
  acceptable bootstrap state.
- M2 binds both channels to one ordered reliable Network.framework TCP byte
  stream under the same authenticated session policy. `TransportCore` keeps
  independent bounded control and media scheduling queues; control is
  prioritized between individual TCP writes, while TCP head-of-line blocking
  remains a measured M8 concern. A different binding requires measured
  evidence and an explicit later milestone decision.
- V1 does not use WebRTC. A later Network.framework datagram/QUIC evaluation
  is allowed only as a measured M8 decision and is not part of the initial
  interoperability contract.

## Session phases

```text
Bonjour discovery
  -> transport connect
  -> TLS and peer identity validation
  -> PairingRequired OR trusted-peer confirmation
  -> Hello / capability negotiation
  -> session authorization
  -> WindowList
  -> WindowSelection
  -> StreamConfig / VideoConfig
  -> Streaming + input/clipboard as separately authorized
```

The session must fail closed if any required phase fails. A reconnect repeats
peer validation and capability/session authorization; it does not inherit
input authority merely because the network endpoint is familiar.

## Frame envelope

All control and media messages use a bounded length-prefixed envelope. The
wire representation is versioned and uses network byte order for fixed-width
numeric fields.

| Field | Purpose |
| --- | --- |
| `protocolVersion` | Major/minor version selected for this session |
| `channel` | Control or media routing identifier |
| `messageType` | Versioned message kind |
| `flags` | Keyframe, acknowledgement, end-of-stream, or other defined flags |
| `payloadLength` | Bounded payload size; reject overflow before allocation |
| `sequence` | Monotonic sequence within the channel |
| `timestamp` | Sender monotonic timestamp when meaningful |
| `payload` | Message-specific encoded data |

`RemoteProtocol` owns envelope parsing and validation. It must reject invalid
magic/version, unknown mandatory flags, impossible lengths, sequence violations,
and payloads that exceed negotiated limits. Parsers must be incremental so a
partial network read is not treated as a malformed complete message.

The exact binary field widths and serialization format are fixed by M1 in
`docs/M1_PROTOCOL.md`, including golden vectors before interoperability testing.

## Message families

| Message | Direction | Purpose |
| --- | --- | --- |
| `Hello` | Both | Protocol version, device role, implementation identity, supported limits, and optional bounded display-only device name |
| `Capabilities` | Both | Codec, resolution, frame-rate, input, and clipboard capabilities |
| `PairingChallenge` | Host → Viewer | Bootstrap challenge and Host commitment |
| `PairingResponse` | Viewer → Host | Fresh Viewer commitment for the commit/reveal exchange |
| `PairingVerification` | Host → Viewer | Host contribution reveal after both commitments are fixed |
| `PairingReveal` | Viewer → Host | Viewer contribution reveal after verifying the Host contribution |
| `PairingConfirmation` | Both | User-confirmed pairing result; never a substitute for authenticated transport |
| `SessionAuthorize` | Host → Viewer / local policy | Selected session authorization state and enabled capabilities |
| `WindowList` | Host → Viewer | Eligible application/window summaries, not pixels or secrets |
| `WindowSelection` | Viewer → Host or Host-local policy | Request/status for one selected window; Host remains authoritative |
| `StreamConfig` | Host → Viewer | Negotiated dimensions, frame rate, codec limits, and stream state |
| `VideoConfig` | Host → Viewer | H.264 decoder configuration and codec generation identifier |
| `VideoFrame` | Host → Viewer | One encoded access unit with timing and keyframe metadata |
| `InputEvent` | Viewer → Host | Validated mouse, keyboard, modifier, and scroll event model |
| `ClipboardOffer` | Both | Text clipboard generation/metadata and opt-in state |
| `ClipboardText` | Both | Bounded UTF-8 text payload for an accepted offer |
| `ClipboardAcknowledgement` | Both | Accept/reject result for one clipboard offer |
| `Ping` / `Pong` | Both | Liveness and timing measurement |
| `SessionState` | Both | Explicit state, permission, focus, and capability transitions |
| `Error` | Both | Structured failure code, retryability, and safe user-facing detail |
| `Close` | Both | Intentional shutdown reason |

Message names are design identifiers. M1 defines exact schemas, optionality,
canonical encoding, and golden test vectors in `docs/M1_PROTOCOL.md`.

## Handshake and capability negotiation

1. The Viewer connects to a discovered Host endpoint.
2. The transport authenticates the peer and validates the trust record or
   enters the explicit pairing flow. In bootstrap mode, a matching local trust
   record auto-consents after the commit/reveal value is ready but does not
   remove the two-sided `PairingConfirmation` exchange.
3. Both sides send `Hello` with role, protocol version, implementation version,
   and bounded limits. They may also send a short device name for pairing and
   status UI; it is untrusted display metadata and never affects identity or
   authorization.
4. Both sides send `Capabilities` and compute an intersection. Unsupported
   mandatory capabilities fail with a structured error.
5. The Host reports whether a selected window and required permissions are
   available.
6. The session becomes stream-ready only after authorization for the one
   selected window. Input and clipboard are independently enabled according to
   policy and consent.

Capabilities must be additive and versioned. Unknown optional capabilities may
be ignored; unknown mandatory capabilities must fail closed.

## Window identity and selection

`WindowList` entries contain a short-lived opaque identifier, display title only
when policy permits, application identity, bounds/aspect metadata, and
eligibility state. The identifier is not a permanent security credential.

The Host is authoritative for selection. A Viewer request cannot select a
window that the Host did not expose, and a stale identifier is rejected. The
Host refreshes the eligible catalog during an active session so the Viewer can
switch applications without reconnecting. A requested eligible regular app is
brought to the Host foreground as a direct consequence of that explicit
selection; input remains disabled until the Host independently confirms the
selected window is foreground-eligible. The per-event permission, focus,
identity, and generation checks remain mandatory. When a window closes,
changes identity, loses permission, or becomes ineligible, the Host disables
input before stopping or renegotiating the stream.

## Video contract

- Codec: H.264 through VideoToolbox.
- Configuration: `VideoConfig` carries a decoder configuration record and a
  generation identifier before dependent frames.
- Frame payload: a bounded encoded access unit with sequence, capture timestamp,
  presentation timing, dimensions, and keyframe indicator.
- Keyframes: the Host can request or produce a new keyframe after stream start,
  decoder reset, or recovery.
- Ordering: the Viewer rejects non-increasing media sequences and stale
  generations. Forward gaps are allowed for discardable `VideoFrame` messages;
  the decoder waits for the next usable keyframe/configuration rather than
  applying stale state.
- Backpressure: the media queue is bounded and may replace only unsent,
  discardable video frames before they receive a wire sequence number; it must
  never grow without limit. `VideoConfig` and recovery keyframes are not
  discardable.
- Authorization invalidation: unsent protected media is discarded. An admitted
  protected control envelope is replaced by an optional unknown tombstone with
  the same sequence, preserving strict control ordering while ensuring the
  stale payload is not decoded or applied.
- Pixel correctness: the Viewer preserves aspect ratio and reports actual
  presentation timing for M8 latency measurement.

The H.264 profile, bitrate, rate control, and frame-duration defaults are M4
decisions. They must be negotiated or explicitly fixed before interoperability
tests.

## Input contract

`InputEvent` is an authenticated-session message, not an arbitrary CoreGraphics
event archive. It contains only the defined V1 event types:

- normalized pointer move and button state;
- scroll/wheel deltas;
- key down/up with physical/logical key identity and modifier state;
- explicit focus/interaction intent where needed by the UI model;
- sequence and monotonic timestamp metadata.

Coordinates are normalized to the current displayed remote-content rectangle,
not the Viewer desktop. The Host maps them to the selected window's current
geometry and clamps/rejects values outside the authorized content. The Host
must reject events when the selected window is not foreground-eligible, the
PostEvent permission is unavailable, the session is not authorized, or the
event rate/sequence is invalid.

V1 does not transfer arbitrary key logs, secure-input contents, password
prompts, or events intended for background/unfocused applications.

### M5 binding decisions

- Viewer pointer coordinates are normalized to unsigned 16-bit values against
  the current content rectangle. The Viewer surface uses a top-left origin:
  `y=0` is the top edge and `y=65535` is the bottom edge. Events outside that rectangle, or while the
  surface is not authenticated, authorized, and stream-ready, are rejected
  locally and never sent.
- `InputCore` assigns a local monotonic event ordinal and carries the current
  selected-window generation. Keyboard modifiers use the protocol bitmask;
  scroll deltas are bounded before encoding. The Viewer input surface admits
  at most 240 events per monotonic second and the encoded event payload is
  limited to 512 bytes.
- `ViewerInputTransport` converts only the typed `InputCore.InputEventRecord`
  into the existing `RemoteProtocol.InputEventMessage`. It does not serialize
  raw `NSEvent`, `CGEvent`, key logs, or clipboard data. `TransportCore` then
  applies session authentication, direction, capability, sequence, and window
  generation checks.
- M5 verification may use a Host test double to inspect typed records. M6 now
  performs Host coordinate mapping and OS event injection only after the
  permission, foreground, focus, and selected-window checks below.

### M6 binding decisions

- `Apps/Host/HostInputMessageHandler` converts only the typed
  `InputEventMessage` fields into an `InputCore.InputEventRecord`. The
  already-authenticated ordered delivery gate is followed by a Host-local
  per-session sequence and local monotonic arrival timestamp; remote payload
  fields do not provide admission authority.
- `InputCore.HostInputController` queries Host context for every event and
  requires session authorization, matching window generation and process/
  window identity, current window geometry, PostEvent permission, optional AX
  secure-input inspection, eligible foreground focus, and the negotiated mouse/keyboard
  capability. Commands retain the selected target identity so the OS adapter
  can repeat the check immediately before posting.
- Normalized coordinates map to the selected window's current global screen
  bounds. Only typed CoreGraphics commands are accepted; arbitrary `CGEvent`
  archives, background activation, locked-screen control, and secure-input
  bypass remain unsupported.
- Disconnect, authorization revocation, focus/permission loss, and selection
  changes reset Host input sequence/rate state and attempt safe release of
  admitted pressed state while the same target and permission remain valid.
  A known not-foreground state is permitted only for this target-bound cleanup;
  normal input still requires eligible focus. Host lifecycle code announces a
  selection change before replacing the CaptureCore selection. If that order
  is missed, the stale release is rejected and the Host closes the session
  rather than admitting input for the replacement target. If permission is
  unavailable, cleanup remains pending and status stays unavailable until a
  safe snapshot allows a retry.
  A detected secure-input state or unknown console state is rejected. If the
  optional Accessibility secure-input query is unavailable, the independent
  foreground/window checks still protect the base PostEvent path.

## Clipboard contract

- Only text is supported in V1.
- Synchronization is disabled by default. Both endpoints opt in per session;
  an optional `hasText = false` offer communicates enable/disable state without
  creating an ambiguous empty-text transfer.
- `ClipboardOffer` carries a generation identifier, origin, text metadata, and
  bounded size; `ClipboardText` carries canonical UTF-8 content. A status-only
  offer has `textByteCount = 0` and `hasText = false`.
- `ClipboardAcknowledgement` identifies the offer by origin/generation and is
  sent before the receiver applies any `ClipboardText`.
- Each side tracks origin/generation so received text is not immediately echoed
  back indefinitely.
- The M1/M7 default is 65,515 UTF-8 bytes. `ClipboardText` travels on the control
  channel and its 21-byte canonical schema/field overhead keeps the complete
  payload within the shared 64 KiB control-envelope limit. Both limits are
  negotiated as the minimum of the local and peer values.
- Conflict policy is deterministic arrival order: a pending local offer wins
  over a concurrent remote offer; a local edit after a remote offer was
  accepted cancels that incoming offer and creates a new local generation;
  replayed generations are rejected.
- Images, files, file promises, rich text, and arbitrary pasteboard types are
  rejected as unsupported.
- Clipboard contents must never appear in normal logs or error strings.

## Errors and state changes

Errors are structured and categorized, for example:

```text
unsupported-version
authentication-failed
pairing-required
authorization-denied
permission-missing
window-unavailable
codec-not-supported
message-too-large
invalid-sequence
backpressure
transport-closed
internal-failure
```

The wire error includes retryability and a safe diagnostic code. It does not
include secrets, raw clipboard text, captured pixels, or unbounded underlying
error strings.

## Liveness, shutdown, and reconnect

- `Ping`/`Pong` supports liveness and controlled timing measurement. `Pong`
  may carry the receiver's monotonic timestamp; when present, the session
  combines it with the envelope timestamps to form an authenticated
  four-timestamp clock probe. Older peers may omit that optional field, in
  which case liveness remains valid but one-way latency is not measured.
- A missed heartbeat changes the visible session state before input is disabled
  or the connection is closed.
- `Close` is best effort; transport teardown must still be safe if it is lost.
- On disconnect, stop input immediately, cancel capture/encode work, clear
  unsent transient media, and retain no reusable authorization in memory longer
  than the session policy allows.
- Connection establishment and each handshake phase have bounded deadlines.
  Normal EOF, cancellation, timeout, or send failure clears local
  authorization before any best-effort peer notification; a failed notification
  never leaves the local session authorized.
- Reconnect starts at peer validation and capability/session authorization. It
  may request a new keyframe, but it never silently resumes unsafe input.

## Compatibility and evolution

- Major protocol changes require an explicit incompatible version.
- M10 uses protocol `2.0`: the pairing challenge is now a mandatory
  commit/reveal exchange and window selections bind to a catalog generation.
  Protocol `1.x` peers are rejected before pairing rather than being allowed to
  fail later in the handshake.
- Minor changes may add optional fields/capabilities with safe defaults.
- M1 creates golden vectors for envelopes and each stable message schema; see
  `docs/M1_PROTOCOL.md`.
- Tests must cover truncated frames, oversized lengths, unknown optional fields,
  unknown mandatory fields, duplicate sequences, stale window IDs, and stale
  codec generations.
- The wire contract must not encode Swift implementation types directly.
