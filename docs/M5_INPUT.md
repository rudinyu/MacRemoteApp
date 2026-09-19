# M5 Viewer Input Foundation

## Scope

M5 implements the Viewer-side input boundary for the selected remote-content
surface. It captures AppKit pointer, button, scroll, keyboard, and modifier
events, converts them to a platform-neutral `InputCore.InputEventRecord`, and
sends the typed record through the authenticated `TransportCore` session.

M5 does not map coordinates to a Host window or inject events into macOS. It
does not implement clipboard synchronization, secure-input handling, raw event
archives, background control, or locked-screen control.

## Ownership

- `Apps/Viewer/ViewerInputSurface.swift` owns AppKit event capture, content
  rectangle tracking, visible readiness state, and the local manual fixture.
- `Packages/InputCore` owns normalized coordinates, event kinds, selected-window
  generation, local sequence, modifier/scroll bounds, and rate/size validation.
- `Apps/Viewer/ViewerInputTransport.swift` maps the typed record to
  `RemoteProtocol.InputEventMessage` and sends it through
  `TransportCore.SessionCoordinator`.
- `TransportCore` remains the authoritative authenticated delivery gate. It
  rejects stale authorization, unsupported capability, direction, sequence,
  or selected-window-generation state.
- M6 will add the Host-side `InputCore` mapping and CoreGraphics/Accessibility
  adapter after checking permission, foreground focus, and window identity at
  the moment of injection.

## Admission rules

An event is emitted only when the Viewer session is authenticated and
authorized, the selected window generation matches, the input capability is
enabled, and the content rectangle is valid. Pointer coordinates are rejected
outside the displayed content rectangle and normalized to `0...65535` per axis.
The input surface uses a flipped AppKit coordinate system, so normalized `y=0`
is the top edge and `y=65535` is the bottom edge; this matches Host global
screen coordinates.
The local input surface enforces the 240-events-per-second default and the
512-byte encoded event-payload bound. Rejected events are reported as local
readiness/validation failures and are not serialized as arbitrary platform
events.

## Verification

- `InputCoreTests` cover edge normalization, resize/content bounds, readiness,
  keyboard modifiers, scroll bounds, sequence, and rate limiting.
- `TransportCoreTests/testAuthorizedViewerInputReachesHostDoubleInWireOrder`
  verifies that authorized pointer and keyboard records reach a Host double in
  wire order with the selected-window generation and modifier bits intact.
- `Viewer --m5-input-surface` provides a local AppKit fixture. It starts in a
  disabled, unauthenticated state and is intended for manual surface/event
  inspection; it performs no Host injection.

## Boundary

The first OS-facing input API is intentionally absent from M5. A successful
M5 test proves typed event capture and authenticated delivery only; it does not
prove that a Host application receives or injects a mouse or keyboard event.
