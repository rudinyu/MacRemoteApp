# MacRemoteApp Protocol Design

## P6 negotiated extension

P6 is the negotiated process-target safety extension documented in
[the P6 contract](P6_BACKGROUND_CONTROL.md). Background selection and viewing
remain available, but ordinary control always requires the selected app to be
foreground. Explicit Viewer window selection asks Host to cooperatively
activate the selected regular app before input; the same rule applies with or
without P6. Pairing trust does not bypass per-event checks, and capability
negotiation alone grants no permission.

Optional `backgroundControl` capability
`0x000A` is separate from `keyframeRequest` (`0x0007`), `receiverReport`
(`0x0008`), `inputSourceSync` (`0x0009`), and `textInput` (`0x000B`, see
[Viewer-side text composition](#viewer-side-text-composition-m10)). It grants nothing by negotiation
alone: Host-accepted pairing trust, current selection authorization, and the
final platform safety checks remain required.

Host `SessionState` adds optional field 5, `controlState` (u8), and field 6,
`processTargetEligible` (bool), plus field 7, `controlGeneration` (u64).
P6 input events echo that generation in optional field 11; input-source
selections echo it in optional field 5. A negotiated P6 control operation
requires a positive generation matching the current Host control admission.
Pause, resume, and revoke advance the generation independently of video's
authorization epoch. Missing or stale generations cannot reopen control;
bytes delayed in the network across pause/resume are rejected. Existing
non-P6 messages omit these fields and retain their golden encodings.
These are additive optional TLVs under protocol `2.0`, gated by P6 negotiation.
The existing `focusEligible` field continues to mean foreground eligibility.
P6 readiness requires foreground eligibility, the active control state, and
the exact selected process identity in addition to permission and current
session authorization; target-process Accessibility inspection is used only
to classify inactive targets for safe cleanup. Missing fields cannot imply
control permission. Old peers
ignore optional fields and retain the same foreground input policy.
Pause/revoke must fence both input events and input-source selections while
retaining the authenticated video path. The transport must invalidate stale
queued input rather than admitting it after a later resume.
Input-source selection also requires foreground eligibility and does not
activate or retarget the Host from an input message. The Viewer uses manual
source matching while the selected app is background and starts a fresh source
synchronization after explicit selection foregrounds it.

## Protocol status and scope

This document defines the V1 LAN session contract at design level. It is the
source for `Packages/RemoteProtocol` and `Packages/TransportCore`; it does not
authorize implementing later milestone behavior early.

The protocol supports one Viewer, one selected Host window, authenticated
control, H.264 video, mouse/keyboard input, and opt-in text clipboard exchange.
It excludes Internet traversal, WebRTC, audio, file transfer, arbitrary
pasteboard types, multi-window sessions, inactive-process input, and
locked-screen control. P6 adds Host-accepted pairing trust, a control
generation, and process safety checks while preserving the foreground input
requirement. The M10 capture-continuity integration does not add wire messages:
the selected video stream is independent of app foreground state, and
transient picker-catalog omissions do not revoke the active selection.

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
| `InputEvent` | Viewer → Host | Validated mouse, keyboard, modifier, and scroll event model; with `textInput`, committed text (kind 7) |
| `InputSourceSelection` | Viewer → Host | Optional, authorized request to set the Host input source to the Viewer's desired Chinese/English state |
| `InputSourceAcknowledgement` | Host → Viewer | Optional, scoped result for that exact input-source request |
| `ClipboardOffer` | Both | Text clipboard generation/metadata and opt-in state |
| `ClipboardText` | Both | Bounded UTF-8 text payload for an accepted offer |
| `ClipboardAcknowledgement` | Both | Accept/reject result for one clipboard offer |
| `Ping` / `Pong` | Both | Liveness and timing measurement |
| `SessionState` | Both | Explicit state, permission, focus, and capability transitions |
| `Error` | Both | Structured failure code, retryability, and safe user-facing detail |
| `Close` | Both | Intentional shutdown reason |
| `ReceiverReport` | Viewer → Host | Periodic queuing-delay and loss feedback for Host bitrate adaptation (M8, optional capability) |
| `KeyframeRequest` | Viewer → Host | Ask the Host to make its next frame a keyframe after a media gap or decode failure (M8, optional capability) |

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
   selected window. Input remains separately authorized by capability,
   accepted Host pairing trust, current target/generation, permissions, and
   platform safety checks. The Host enables its negotiated clipboard bridge
   from accepted pairing trust; the Viewer still requires its session-local
   clipboard opt-in.

Capabilities must be additive and versioned. Unknown optional capabilities may
be ignored; unknown mandatory capabilities must fail closed.

## Window identity and selection

`WindowList` entries contain a short-lived opaque identifier, display title only
when policy permits, application identity, bounds/aspect metadata, and
eligibility state. The identifier is not a permanent security credential.

The Host is authoritative for selection. A Viewer request cannot select a
window that the Host did not expose, and a stale identifier is rejected. The
Host refreshes the eligible catalog during an active session so the Viewer can
switch applications without reconnecting. The catalog is picker data, not the
liveness authority for an already selected target: the Host does not publish a
transient snapshot that omits its active selection, and CaptureCore tolerates
brief selected-window lookup gaps before declaring confirmed target loss. For
any peer, explicit selection of an eligible regular app may bring it to the
Host foreground, and input requires foreground eligibility. P6 adds its
separate Host authorization and safety checks but does not permit inactive
process input. The selected-window stream can continue while the app is
inactive or occluded. Unexpected capture-stream completion enters a bounded local restart
path after the Host rechecks the same window ID, bundle ID, PID, layer, and
valid geometry; this state transition does not change the wire protocol or
authorization generation. Permission loss, confirmed target loss, or owner
mismatch stops capture and fails closed.

## Video contract

- Codec: H.264 through VideoToolbox.
- Configuration: `VideoConfig` carries a decoder configuration record and a
  generation identifier before dependent frames.
- Frame payload: a bounded encoded access unit with sequence, capture timestamp,
  presentation timing, dimensions, and keyframe indicator. The default envelope
  payload limit is 4 MiB (Hello field 4); a session uses min(local, peer), so a
  1 MiB older peer keeps 1 MiB. A Host access unit that does not fit the
  negotiated limit is dropped (the Host lowers its bitrate and forces the next
  keyframe) instead of stopping the stream.
- Stream size and rate: each side advertises its maximum video width, height,
  and frame rate in `Capabilities`; the session uses min(Host, Viewer). The
  Host advertises up to 3840×2160 at 60 fps, the Viewer advertises its Stream
  quality setting (1080p60 by default), and each selection streams at that
  negotiated bound. Peers that advertise nothing get 1920×1080 at 60 fps.
- Keyframes: the Host can request or produce a new keyframe after stream start,
  decoder reset, or recovery.
- Ordering: the Viewer rejects non-increasing media sequences and stale
  generations. Forward gaps are allowed for discardable `VideoFrame` messages;
  the decoder waits for the next usable keyframe/configuration rather than
  applying stale state.
- Backpressure: the media queue is bounded and must never grow without limit.
  When full it discards the incoming delta frame and then skips delta frames
  until the next keyframe, so a decoder never receives a delta frame whose
  reference was dropped. A newer independently decodable keyframe may replace
  older queued keyframes and delta frames while preserving `VideoConfig` and
  control messages. If required media fills the queue, the keyframe is rejected
  with media backpressure; delta frames remain gated until a keyframe is
  admitted. A sender that observes a discard forces its next frame to be a
  keyframe.
- Keyframe request (M8): when both endpoints negotiate the optional
  `keyframeRequest` capability and the Host authorizes it for the selected
  window, the Viewer sends `KeyframeRequest` on the control channel after an
  incoming media sequence gap, a local media-queue discard, or a decode
  failure. It is a protected message bound to the authorized window
  generation. The Viewer sends at most one request per 250 ms and the Host
  independently honors at most one per 250 ms, so a peer cannot force every
  frame to be a keyframe. Peers without the capability never receive it and
  recover at the periodic keyframe.
- Bitrate adaptation (M8): with the optional `receiverReport` capability, the
  Viewer's session sends `ReceiverReport` about every 500 ms while video
  arrives. It carries the mean queuing delay (the rise of receive time minus
  Host send time above its minimum over the last 5–10 s, which cancels the
  clock offset), frames received, and frames lost to sequence gaps or local
  discards. The Host's `AdaptiveBitrateController` cuts the encoder bitrate to
  70% on a report with discards or at least 40 ms queuing delay, on a Host
  queue discard, or on a gap-triggered `KeyframeRequest`, at most once per
  500 ms and never below 2 Mbps. After 3 s without congestion, reports with at
  most 15 ms delay raise it by one tenth of the maximum per second back to
  16 Mbps. The bitrate changes on the live VideoToolbox session without a new
  keyframe. A report is untrusted input bound to the authorized window
  generation; the worst a peer can do is move the bitrate within those
  bounds. Without the capability, the Host still adapts to its own queue
  discards and to gap-triggered keyframe requests.
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
geometry and clamps/rejects values outside the authorized content. Both legacy
and negotiated P6 input require foreground eligibility; P6 also requires a
safe, authorized process target. Both paths require PostEvent permission,
session authorization, and valid event rate/sequence. Ordinary events use the
public system Quartz event stream; PID-targeted posting is limited to safe
cleanup releases of already admitted state during reset, selection change,
focus loss, or revocation, using the original target identity.

V1 does not transfer arbitrary key logs, secure-input contents, password
prompts, or events intended for unselected or unauthorized background
applications.

The concrete input bindings are recorded as decision records:

- M5 Viewer binding (16-bit top-left normalized coordinates, local event
  ordinal, 240 events per second, 512-byte payload, typed-record-only
  transport) — [ADR-0004](decisions/0004-m5-viewer-input-binding.md).
- M6 Host binding (typed-field conversion, Host-local sequence, per-event
  context checks, target-bound cleanup, fail-closed secure input) —
  [ADR-0005](decisions/0005-m6-host-input-binding.md), with the cleanup state
  machine in
  [Host input admission and cleanup](ARCHITECTURE.md#host-input-admission-and-cleanup).

### Keyboard layout and text-input policy (V1 decision, M6)

The Viewer and Host may use different keyboard layouts (for example US,
JIS, or Dvorak), different physical keyboard types (ANSI, ISO, JIS), and
different input methods (for example Pinyin or Kotoeri). V1 resolves this
with one explicit rule: **physical key positions are forwarded; the Host's
active input source interprets them.**

- `InputEvent.keyCode` is the macOS virtual key code of the physical key
  that the Viewer received (`NSEvent.keyCode`). It is a key position, not a
  character, and the Viewer never translates it through its own layout. The
  "logical key identity" named in the input contract above is, for V1, only
  this code plus the `modifiers` mask; no character, Unicode string, or
  layout identifier is carried.
- `modifiers` is the AppKit device-independent flag mask (high 16 bits)
  observed with that key transition. Modifier keys (Shift, Control, Option,
  Command, left and right) are forwarded as their own key down/up events in
  the order the Viewer received them, and every key event carries the mask
  current at that moment. The Host applies that mask unchanged to the posted
  event and rejects any bit outside the device-independent range.
- The Host posts the key with `CGEvent(keyboardEventSource: nil, ...)`. The
  receiving application therefore interprets the key position with the
  Host's active keyboard layout, keyboard type, and input source. A Viewer
  key produces the character that the same physical position produces on the
  Host; it can differ from the Viewer keycap when the layouts differ. The
  operator selects the matching layout on the Host when that matters. The
  user-approved M10 synchronization below follows Chinese/English source
  state when both endpoints support it. It does not force an already-English
  Host to use the same English physical layout as the Viewer.
- Dead keys and Option-composed characters are forwarded as ordinary key
  events (for example Option down, E down/up with the Option bit, Option up,
  E down/up). Dead-key state lives in the Host application's text system, so
  the composed character is the one the Host's layout defines. Neither side
  collapses, reorders, or synthesizes events for composition.
- Without `textInput`, input-method (IME) composition happens on the Host:
  the Viewer surface does not hand keys to its input method, and the Host's
  active source owns marked text and candidate windows. With `textInput`
  (ADR-0008), a Viewer using a Chinese input method composes locally and sends
  committed text; marked text and candidates stay on the Viewer. Input-source
  switching is Viewer-local when M10 synchronization is negotiated, and the
  actual desired source is sent instead of replaying the toggle. Keyboard
  shortcuts consumed by the Viewer's own system or menus are not forwarded.
- Caps Lock and Fn are not forwarded as key events. Their state reaches the
  Host only as the corresponding bit in each key event's `modifiers` mask;
  the Host's own lock state is not toggled.
- Dictation and character-level translation of physical keys remain out of
  scope. Text entry through a Viewer-side input method is defined only by
  ADR-0008 and only for peers negotiating `textInput`.
- Key codes and modifier masks are raw input values: they are never logged,
  included in error strings, or reported in Host status/receipts. Secure-input
  rejection applies to every key regardless of layout; no layout or IME path
  bypasses it.

Verification: `InputCoreTests` feed Option/dead-key and shortcut sequences
through `HostInputController` and assert the adapter receives only typed key
commands with unchanged key codes, masks, and order; layout-specific ISO/JIS
codes pass through unmapped; and key rejection/status/receipt text contains no
key value. `scripts/validate.sh` rejects character translation and
secure-input-bypass APIs in the input path and limits the ADR-0008 text APIs to
the Viewer surface and the Host adapter. Behavior with a real Host
layout or input method is part of the M6 manual OS evidence.

### Viewer-led input-source synchronization (M10)

[ADR-0007](decisions/0007-m10-input-source-following.md) records the explicitly
approved extension, exact bounded request/acknowledgement contract, ownership,
ordering gate, older-peer compatibility, and security requirements. The Host
follows the actual Viewer Chinese/English source state; an already-matching
state is a no-op, not another toggle. Chinese alignment requires the matching
enabled input method/mode. Composition and candidate selection remain on the
Host, and no Unicode text-insertion message is introduced by this extension.

### Viewer-side text composition (M10)

[ADR-0008](decisions/0008-m10-viewer-text-composition.md) adds optional
capability `textInput` (`0x000B`). `InputEvent` kind `text` (`7`) carries
optional field 12 `text`: UTF-8, 1–256 bytes, no control characters, and no
other key/pointer fields; other kinds must omit field 12. It requires
selected-window authorization plus `keyboardInput` and `textInput`, and it
shares the input stream, ordering, rate limits, admission fence, and queue
invalidation with key events. Only committed text is sent; marked text and
candidates stay on the Viewer. The Host posts it as Unicode keyboard events
under the same per-event checks, including secure input. Text is never logged.

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
