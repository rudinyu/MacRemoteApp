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
- The baseline design uses an ordered reliable control stream and an
  independently queued media stream under the same authenticated session
  policy. The exact physical connection arrangement is an M2 decision, but
  both channels must be isolated enough that video backpressure cannot starve
  input or authorization messages.
- V1 does not use WebRTC. A later Network.framework datagram/QUIC evaluation
  is allowed only as a measured M8 decision and is not part of the initial
  interoperability contract.

## Session phases

```text
Bonjour discovery
  -> transport connect
  -> TLS and peer identity validation
  -> Hello / capability negotiation
  -> PairingRequired OR trusted-peer confirmation
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

The exact binary field widths and serialization format are an M1 decision and
must be documented with golden vectors before interoperability testing.

## Message families

| Message | Direction | Purpose |
| --- | --- | --- |
| `Hello` | Both | Protocol version, device role, implementation identity, and supported limits |
| `Capabilities` | Both | Codec, resolution, frame-rate, input, and clipboard capabilities |
| `PairingChallenge` | Host → Viewer | Bootstrap challenge and displayable confirmation data |
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
| `Ping` / `Pong` | Both | Liveness and timing measurement |
| `SessionState` | Both | Explicit state, permission, focus, and capability transitions |
| `Error` | Both | Structured failure code, retryability, and safe user-facing detail |
| `Close` | Both | Intentional shutdown reason |

Message names are design identifiers. M1 defines exact schemas, optionality,
canonical encoding, and golden test vectors.

## Handshake and capability negotiation

1. The Viewer connects to a discovered Host endpoint.
2. The transport authenticates the peer and validates the trust record or
   enters the explicit pairing flow.
3. Both sides send `Hello` with role, protocol version, implementation version,
   and bounded limits.
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
window that the Host did not expose, and a stale identifier is rejected. When a
window closes, changes identity, loses permission, or becomes ineligible, the
Host sends a state change and disables input before stopping or renegotiating
the stream.

## Video contract

- Codec: H.264 through VideoToolbox.
- Configuration: `VideoConfig` carries a decoder configuration record and a
  generation identifier before dependent frames.
- Frame payload: a bounded encoded access unit with sequence, capture timestamp,
  presentation timing, dimensions, and keyframe indicator.
- Keyframes: the Host can request or produce a new keyframe after stream start,
  decoder reset, or recovery.
- Ordering: the Viewer rejects stale generations and handles missing/superseded
  frames by waiting for the next usable keyframe/configuration.
- Backpressure: the media queue is bounded and may replace unsent stale frames;
  it must never grow without limit.
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
Accessibility permission is unavailable, the session is not authorized, or the
event rate/sequence is invalid.

V1 does not transfer arbitrary key logs, secure-input contents, password
prompts, or events intended for background/unfocused applications.

## Clipboard contract

- Only text is supported in V1.
- Synchronization is opt-in and represented in session state.
- `ClipboardOffer` carries a generation identifier, origin, text metadata, and
  bounded size; `ClipboardText` carries canonical UTF-8 content.
- The receiver acknowledges or rejects an offer before applying it.
- Each side tracks origin/generation so received text is not immediately echoed
  back indefinitely.
- A default maximum payload of 1 MiB encoded text should be used unless M7
  documents a different bound with a compatibility reason.
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

- `Ping`/`Pong` supports liveness and controlled timing measurement.
- A missed heartbeat changes the visible session state before input is disabled
  or the connection is closed.
- `Close` is best effort; transport teardown must still be safe if it is lost.
- On disconnect, stop input immediately, cancel capture/encode work, clear
  unsent transient media, and retain no reusable authorization in memory longer
  than the session policy allows.
- Reconnect starts at peer validation and capability/session authorization. It
  may request a new keyframe, but it never silently resumes unsafe input.

## Compatibility and evolution

- Major protocol changes require an explicit incompatible version.
- Minor changes may add optional fields/capabilities with safe defaults.
- M1 creates golden vectors for envelopes and each stable message schema.
- Tests must cover truncated frames, oversized lengths, unknown optional fields,
  unknown mandatory fields, duplicate sequences, stale window IDs, and stale
  codec generations.
- The wire contract must not encode Swift implementation types directly.
