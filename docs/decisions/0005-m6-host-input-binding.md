# ADR-0005: M6 Host input admission, mapping, and cleanup binding

- Milestone: M6
- Status: Accepted
- Extracted from: `docs/PROTOCOL.md` ("M6 binding decisions")

## Context

Host-side injection must affect only the authorized, eligible, foreground
selected window, and must never leave an OS key or button pressed when
authorization, focus, permission, or selection changes. The resulting
admission and cleanup state machine is documented in
[Host input admission and cleanup](../ARCHITECTURE.md#host-input-admission-and-cleanup).
Foreground eligibility is a local fact: the selected process must be the
active workspace process, and the exact selected target must remain a valid
layer-0 window. The top regular layer-0 WindowServer window must belong to the
selected process and bundle, though it may have a different window identifier
for an app-owned sheet or popover. Unresolved layer-0 windows that may overlap
remain blockers.

## Decision

- `Apps/Host/HostInputMessageHandler` converts only the typed
  `InputEventMessage` fields into an `InputCore.InputEventRecord`. The
  already-authenticated ordered delivery gate is followed by a Host-local
  per-session sequence and local monotonic arrival timestamp; remote payload
  fields do not provide admission authority.
- `InputCore.HostInputController` queries Host context for every event and
  requires session authorization, matching window generation and process/
  window identity, current window geometry, PostEvent permission, optional AX
  secure-input inspection, eligible foreground focus, and the negotiated
  mouse/keyboard capability. Commands retain the selected target identity so
  the OS adapter can repeat the check immediately before posting.
- The Host may request bounded cooperative AppKit activation only after an
  explicit legacy window selection and only on macOS 14 or later. It first
  activates itself and confirms it is the frontmost process before yielding
  to the selected app. Failed confirmation or unsupported cooperative APIs
  leave input fail-closed and instruct the Host user to click or reactivate
  MacRemoteApp Host. Activation is not authorization; the active PID and
  layer-0 foreground checks still gate every event. Negotiated P6 process
  targeting never activates the selected app.
- Normalized coordinates map to the selected window's current global screen
  bounds. Only typed CoreGraphics commands are accepted; arbitrary `CGEvent`
  archives, background activation, locked-screen control, and secure-input
  bypass remain unsupported.
- Disconnect, authorization revocation, focus/permission loss, and selection
  changes reset Host input sequence/rate state and attempt safe release of
  admitted pressed state while the same target and permission remain valid.
- A known not-foreground state is permitted only for this target-bound
  cleanup; normal input still requires eligible focus.
- Host lifecycle code announces a selection change before replacing the
  CaptureCore selection.
- A detected secure-input state or unknown console state is rejected.

## Consequences

- If the selection-change order is missed, the stale release is rejected and
  the Host closes the session rather than admitting input for the replacement
  target.
- If permission is unavailable, cleanup remains pending and status stays
  unavailable until a safe snapshot allows a retry.
- If the optional Accessibility secure-input query is unavailable, the
  independent foreground/window checks still protect the base PostEvent path.
