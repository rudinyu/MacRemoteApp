# ADR-0005: M6 Host input admission, mapping, and cleanup binding

**Current status:** P6 adds Host-accepted pairing trust, a control generation,
and process-safety checks, but ordinary input always requires the selected app
to be foreground. Explicit Viewer window selection cooperatively activates
the selected regular app before input is authorized. Pausing closes control
for the session; unpairing revokes trust and ends the active session.

- Milestone: M6
- Status: Accepted
- Extracted from: `docs/PROTOCOL.md` ("M6 binding decisions")

## Context

Host-side input is admitted only for the authorized selected target while its
PID is verified foreground, and must never leave an OS key or button pressed
when authorization, foreground eligibility, P6 target safety, permission, or
selection changes. Ordinary events enter the public Quartz system stream, where
WindowServer hit-tests the cursor location. A focus or overlay change in the
narrow interval between the final check and dispatch can alter the recipient;
physical receipt by the selected app remains unverified. All peers require
foreground eligibility; negotiated P6 also requires Host pairing acceptance
and safe process checks. The resulting admission and cleanup state
machine is documented in
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
  window identity, current window geometry, PostEvent permission, secure-input
  inspection, foreground eligibility, P6 process-target safety when negotiated,
  and the negotiated
  mouse/keyboard capability. Commands retain the selected target identity so
  the OS adapter can repeat the check immediately before posting.
- The Host may request bounded cooperative AppKit activation only after an
  explicit window selection and only on macOS 14 or later. It first
  activates itself and confirms it is the frontmost process before yielding
  to the selected app. Failed confirmation or unsupported cooperative APIs
  leave input fail-closed and instruct the Host user to click or reactivate
  MacRemoteApp Host. Activation is not authorization; active-PID and layer-0
  foreground checks gate all ordinary events. Negotiated P6 also requires
  current Host pairing trust and safe target state.
- Normalized coordinates map to the selected window's current global screen
  bounds. Ordinary events use public system Quartz dispatch and normal
  hit-testing. Target-bound PID posting is reserved for safe cleanup releases
  of already admitted pressed state during reset, selection change, focus loss,
  or revocation, using the original target identity. Only typed CoreGraphics
  commands are accepted; arbitrary `CGEvent` archives,
  locked-screen control, and secure-input bypass remain unsupported.
- Disconnect, authorization revocation, focus/permission loss, and selection
  changes reset Host input sequence/rate state and attempt safe release of
  admitted pressed state while the same target and permission remain valid.
- A known not-foreground state rejects ordinary input for every peer. It may
  be permitted only for safe target-bound cleanup of already admitted state.
- Host lifecycle code announces a selection change before replacing the
  CaptureCore selection.
- A detected secure-input state or unknown console state is rejected.

## Consequences

- If the selection-change order is missed, the stale release is rejected and
  the Host closes the session rather than admitting input for the replacement
  target.
- If permission is unavailable, cleanup remains pending and status stays
  unavailable until a safe snapshot allows a retry.
- Foreground P6 follows the same optional global secure-input signal as legacy
  peers; a detected active state is rejected, while an unknown signal keeps
  the established foreground behavior. P6 requires known-safe global and
  target-process inspection only when classifying an inactive target for safe
  cleanup, which never admits ordinary input.
