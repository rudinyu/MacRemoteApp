# Post-V1 Roadmap

## Status and boundary

This is a planning document. Background-process input was present in the
historical `0.2.1011` RC and Build `1023` signed Debug artifacts. Build `1022`
also keeps the selected-window stream active when its app is inactive; Build
`1023` adds pre-delivery input-failure recovery while preserving terminal
handling for uncertain delivery. Current source policy requires foreground
input for every peer; P6 retains Host-authorized pairing and process-safety
checks but does not permit inactive-process input. V1 remains a LAN-only
session between one Host and one Viewer for one selected window, with H.264
video, mouse/keyboard input, and opt-in text clipboard.

Every roadmap item needs its own protocol, threat-model, consent, performance,
and physical acceptance gate. A future item must not be enabled as a hidden
fallback in the V1 runtime.

## Proposed sequence

| Stage | Capability | Reason for order | Required decision gate |
| --- | --- | --- | --- |
| P0 | V1 stabilization | Complete the physical Intel Host to Apple Silicon Viewer acceptance and collect real latency/resource evidence before expanding scope. | M10 acceptance report, release rollback plan, and security residuals are closed or explicitly accepted. |
| P0.5 | Host cursor shape (option (b) chosen) | Small single-window UX fidelity gap; does not add a new data class, so it could come before multi-window. | Option (b) chosen in [Open decision: Host cursor shape](#open-decision-host-cursor-shape). A Host cursor-kind feasibility spike and milestone definition in the planning documents come before any code. |
| P1 | Multi-window | Extends the existing window-list/selection model before adding more media or network complexity. | New session/window generations, focus rules, UI affordances, and authorization tests prove that input cannot cross windows. |
| P2 | Audio | Adds a second real-time media stream while remaining LAN-first. | Explicit capture/playback consent, mute state, bounded jitter/backpressure behavior, privacy review, and synchronized A/V measurements. |
| P3 | WebRTC transport evaluation | Introduces a transport option only after the measured TCP baseline and media/control separation are understood. | Codec/security/ICE policy, certificate identity binding, permission model, fallback behavior, and a documented reason TCP is insufficient. |
| P4 | Internet relay and NAT traversal | Depends on a reviewed transport abstraction and a service threat model; this is a new trust and availability boundary. | Relay authentication, end-to-end identity continuity, abuse/rate controls, metadata minimization, billing/operations ownership, and opt-in network policy. |
| P5 | Secure file transfer | Adds durable user data movement and therefore a larger privacy and malware surface. | Explicit per-transfer approval, path sandboxing, size/type/rate limits, cancellation, integrity, audit redaction, and no implicit clipboard/file sharing. |
| P6 | Pairing and process-safety checks | Implemented as a negotiated, Host-authorized extension that preserves foreground input requirements; physical input and IME acceptance remains pending. | Verify the security, consent, stale-work, and recovery gates in [P6](P6_BACKGROUND_CONTROL.md) on Intel Host and Apple Silicon Viewer. |
| P7 | Locked-screen control research | This is not a committed feature. It may be infeasible or unsafe under macOS login-window and secure-input rules. | Separate security review and user decision; no implementation milestone is authorized unless an explicit threat model, OS support matrix, recovery path, and consent design are approved. |

## Cross-stage dependencies

```text
M10 physical acceptance
        |
        v
 multi-window -----> audio --------------------+
        |                                       |
        +-----> transport evaluation (WebRTC) --+--> Internet relay
                                                        |
                                                   file transfer

 foreground authorization review ---> background control
                                    \
                                     ---> locked-screen research gate
```

WebRTC and Internet relay are separate decisions: WebRTC may be useful on a
LAN, but adopting it does not authorize an Internet service. A relay must not
terminate or silently replace the device-identity trust model. Likewise,
background or locked-screen control must not inherit the existing foreground
authorization just because a session is already paired.

## Open decision: Host cursor shape

Status: **decided — option (b)** (user decision, 2026-09-27). It is not yet
implemented. No code, wire identifier, or capability for this item exists
until the P0.5 milestone below is defined in the planning documents and its
feasibility spike passes.

### Gap

`CaptureCore.ScreenCaptureEngine` sets `SCStreamConfiguration.showsCursor =
false`, and no V1 message conveys the Host cursor shape. The Viewer therefore
always shows its local arrow over the remote surface, even where the Host app
would show an I-beam, a resize cursor, or a pointing hand. Cursor shape is not
a V1 requirement in `docs/PRODUCT_SPEC.md`, so this is a UX gap rather than a
V1 defect.

### Options

| Option | Summary | Benefits | Costs and risks |
| --- | --- | --- | --- |
| (a) Bake cursor into video | Set `showsCursor = true` so ScreenCaptureKit draws the Host cursor into each frame. | No protocol change; exact shape including custom cursors; one-line capture change. | Double cursor (local arrow plus a remote copy that lags by the full capture, encode, network, and decode latency). Hiding the local cursor makes pointing feel as slow as video. Cursor motion forces extra encoded change regions and can raise bitrate. The remote cursor is still drawn when input is disabled. |
| (b) Optional `CursorState` message | New Host → Viewer control message carrying a small enumerated cursor kind. It is gated by a new optional capability (unknown optional capabilities are already ignored per `docs/M1_PROTOCOL.md`). The Viewer sets the matching local `NSCursor` over the remote surface. | Local cursor stays responsive at pointer speed. Only a shape change crosses the latency path. No pixels are sent. Older peers are unaffected. | Protocol minor bump, new wire schema, golden vectors, and TransportCore gating. macOS has no public API that reports another process's cursor *kind*. The Host must infer it, for example by comparing `NSCursor.currentSystem` image and hotspot to the standard `NSCursor` set, and that needs a feasibility spike on the Intel Host. Custom app cursors degrade to `arrow`. |
| (c) Defer | Keep V1 behavior and document the gap in the user guide. | Zero risk to V1 acceptance. | The UX gap remains. |

### Sketch of option (b) if chosen

- Capability: allocate a free identifier at the P0.5 decision gate
  (`0x000A` is allocated to P6; cursor capability must use another free ID), always
  optional and never mandatory. A peer that did not negotiate it never receives
  `CursorState`. Receiving it without negotiation is a protocol violation that
  fails closed like any other ungated protected message.
- Message: allocate a free message type at the P0.5 decision gate
  (`0x001B` is currently next; these planning values are not reservations).
  `CursorState` is Host → Viewer on
  the control channel. Fields: `windowGeneration` (u64, mandatory) and
  `cursorKind` (u8, mandatory). Fixed size, so no variable-length payload.
- Kinds: a closed enum mapped to public `NSCursor` standard cursors (arrow,
  I-beam, pointing hand, open/closed hand, crosshair, horizontal/vertical
  resize, operation-not-allowed, and a few others). The Viewer renders unknown
  or future values as `arrow`.
- Emission: sent only on change, coalesced latest-wins, and rate-limited on the
  Host (for example at most 30 per second). Sent only while the session is
  authorized, the stream is ready, and the Host pointer is inside the selected
  window. On authorization loss, a generation change, or disconnect, the
  Viewer reverts to `arrow`.
- Versioning: a protocol minor bump (`2.1`) with an optional capability and
  safe default. `2.0` peers are unaffected.
- Ownership: the wire type in `RemoteProtocol`, capability and generation gating
  in `TransportCore`, and Host cursor observation in an `Apps/Host` adapter,
  because it needs AppKit (whether a neutral model belongs in `CaptureCore`
  gets decided in the milestone document). The Viewer cursor application goes
  in `Apps/Viewer` on the existing input surface.

### Security and privacy notes

- **Never send raw cursor bitmaps.** Apps can draw content into custom cursors,
  such as drag images with file icons, names, or document thumbnails.
  Forwarding the image would create a new, unredacted pixel channel outside the
  selected-window capture boundary. The enumerated kind carries only a few bits.
- Any image comparison or hashing used to classify the cursor stays local to
  the Host. Hashes or fingerprints of custom cursors are never sent or logged.
- An enumerated kind reveals only what the authorized video already shows,
  such as the pointer hovering over text or a link. It adds no new data class.
  As a conservative rule, the Host sends `arrow` while secure input is detected,
  and nothing while the selected window is not foreground-eligible.
- `CursorState` never grants or implies input authority and never changes the
  Host cursor. It is display-only on the Viewer.
- Diagnostics may record the kind and the rate-limit counters. They must not
  record images, hashes, or pointer coordinates.
- Option (a) adds no wire surface, but it shows the Host pointer in the video
  even when input is disabled. It carries whatever the cursor image contains,
  including drag images, within the already-authorized capture.

### Milestone ownership

V1 milestones M0–M10 do not own this item. Changing `showsCursor` or adding a
message inside M10 would be out-of-scope scope creep. If option (b) is chosen,
it becomes a named post-V1 milestone (stage P0.5 above). That milestone updates
`docs/PRODUCT_SPEC.md`, `docs/ARCHITECTURE.md`, `docs/PROTOCOL.md`,
`docs/M1_PROTOCOL.md` identifier tables and golden vectors,
`docs/SECURITY.md`, and `docs/DEVELOPMENT_PLAN.md` before any code. Option (a)
still needs an explicit product decision and an M8-style latency/bitrate
re-measurement, because it changes the capture output.

## Non-negotiable security rules for later work

- Preserve Keychain-backed device identity and explicit peer trust. Never make
  discovery, a relay account, or a short pairing code the sole authorization.
- Keep Host authorization separate from transport authentication. Pairing never
  grants window, audio, file, background, or locked-screen authority by itself.
- Add explicit user consent for every new data class: audio, files, and any
  target outside the foreground selected-window policy.
- Keep bounded queues, cancellation, freshness, and redacted diagnostics for
  every new channel. Do not log media, file names when sensitive, tokens, or
  raw input.
- Maintain a documented downgrade path to the V1 LAN/TCP mode only when the
  downgrade is safe and visible; never silently weaken authentication.

## Planning outputs for each future milestone

Before implementation, update the product, architecture, protocol, security,
and development-plan documents with one named milestone. That milestone must
define the wire changes, ownership package, migration/versioning story,
permission UX, deterministic tests, physical test matrix, performance target,
rollback behavior, and release evidence. Except for the separately authorized
P6 source extension, these capabilities remain
roadmap items and are intentionally absent from the M10 code path.
