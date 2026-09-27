# ADR-0004: M5 Viewer input binding

- Milestone: M5
- Status: Accepted
- Extracted from: `docs/PROTOCOL.md` ("M5 binding decisions")

## Context

The [input contract](../PROTOCOL.md#input-contract) defines `InputEvent` as a
typed authenticated-session message with normalized coordinates. M5 had to fix
the coordinate encoding, ordering metadata, bounds, and the Viewer-side
mapping to the wire type without adding Host-side injection.

## Decision

- Viewer pointer coordinates are normalized to unsigned 16-bit values against
  the current content rectangle. The Viewer surface uses a top-left origin:
  `y=0` is the top edge and `y=65535` is the bottom edge.
- Events outside that rectangle, or while the surface is not authenticated,
  authorized, and stream-ready, are rejected locally and never sent.
- `InputCore` assigns a local monotonic event ordinal and carries the current
  selected-window generation. Keyboard modifiers use the protocol bitmask;
  scroll deltas are bounded before encoding.
- The Viewer input surface admits at most 240 events per monotonic second and
  the encoded event payload is limited to 512 bytes.
- `ViewerInputTransport` converts only the typed `InputCore.InputEventRecord`
  into the existing `RemoteProtocol.InputEventMessage`. It does not serialize
  raw `NSEvent`, `CGEvent`, key logs, or clipboard data. `TransportCore` then
  applies session authentication, direction, capability, sequence, and window
  generation checks.

## Consequences

- M5 verification may use a Host test double to inspect typed records.
- M6 now performs Host coordinate mapping and OS event injection only after
  the permission, foreground, focus, and selected-window checks in
  [ADR-0005](0005-m6-host-input-binding.md).
