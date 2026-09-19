# M6 Host Input Injection

## Scope and status

M6 adds the Host-side input boundary for the typed M5 event model. The
implementation is complete for deterministic package and composition tests.
Actual OS event posting remains an explicit manual evidence step because it
requires a local Accessibility grant and can affect the selected test
application. No M7 clipboard behavior is included.

## Ownership

- `Apps/Host/HostInputMessageHandler.swift` converts an authenticated
  `RemoteProtocol.InputEventMessage` into an `InputCore.InputEventRecord`.
  `TransportCore` has already admitted the ordered authenticated message; the
  handler assigns a per-session local sequence and receives a local monotonic
  arrival timestamp. Remote payloads do not provide authority for either
  value.
- `Apps/Host/HostInputSessionLoop.swift` is the single-consumer dispatcher for
  the authenticated Host message stream. It forwards input cases to the M6
  handler and hands every non-input message to the app's central dispatcher;
  it never silently consumes unrelated session messages. The loop observes
  authorization/reconnect transitions and calls `reset()`; Host lifecycle code
  must use `withSelectionReplacement()` (or pair
  `selectionWillChange()`/`selectionDidChange()`) while changing CaptureCore's
  selected window. The admission barrier remains held until the provider
  publishes the replacement. Safety transitions discard queued input records before resetting the
  handler, so input buffered before a permission/focus/authorization change is
  never replayed as fresh input. The loop also polls for a missed selection
  transition; if old pressed state cannot be released safely, it terminates
  the session instead of carrying that state into the new target.
  `TransportCore.SessionCoordinator.withIncomingInputAdmission` fences an
  input already delivered directly to the sole stream waiter against local
  revoke, reconnect, and stop transitions; the synchronous admission operation
  cannot interleave with those actor state changes.
  `HostInputSessionRuntime` starts and stops this loop once per
  `SessionCoordinator` connection. If the stream ends while cleanup is
  pending, the runtime keeps a target-bound retry worker alive until
  permission/focus recovers or the admitted target is no longer safely
  identifiable, even if the short-lived runtime handle is released. Lifecycle
  stop/replacement waits for that safe recovery before a replacement Host
  session can reuse the selected target. This can temporarily block
  reconnection during a permission/focus outage; cancelling the retry would
  risk leaving an admitted key or button pressed.
- `Packages/InputCore/HostInput.swift` owns the Host authorization matrix,
  normalized-coordinate mapping, event shape/modifier/button validation,
  sequence/rate admission, status, and serialized injection boundary.
- `Packages/InputCore/CoreGraphicsAccessibilityInput.swift` owns the macOS
  context provider and the typed CoreGraphics event adapter. The adapter does
  not activate a background app or accept raw event archives.
- `TransportCore` and `SecurityCore` remain the sources of session/trust
  authorization facts. The Host supplies those facts to `InputCore`; a
  transport authorization result alone never posts an OS event.

## Admission matrix

Every event is checked immediately before adapter invocation:

```text
authenticated and authorized session
  AND authorized selected-window generation matches
  AND selected window identity, owning application, and process still match
  AND Accessibility/post-event permission is authorized
  AND selected window is the eligible foreground window
  AND input capability is enabled
  AND event shape, modifier mask, sequence, and rate are valid
```

Any other state rejects the event. `resetInputState()` is called when a
session disconnects, authorization is revoked, focus/permission is lost, or
the selected-window generation changes. The controller reserves a bounded
safety lane for matching key/button releases and makes a best-effort synthetic
release before clearing admitted pressed state when the same target and
permission remain safe. The adapter has a controller-only release path
that can run after session authorization has already been revoked. It remains
bound to the exact admitted window identity and process. If CaptureCore has
already published a new selection, the provider must supply a fresh live
context for the admitted target; the new selection is never reused to release
old state. If that target is gone or an unknown security surface blocks a
safe snapshot, cleanup remains pending and lifecycle replacement is blocked
until recovery. Normal input status reports unavailable while cleanup is
pending. Normal polling never reconciles healthy pressed state. Cleanup
coordinates are clamped to the current bounds after a window move or resize.
A rejected event is not retried under a later authorization state, and an
unmatched release is never sent to the OS.

## Mapping and platform boundary

Viewer coordinates are unsigned 16-bit values in the displayed content
rectangle. The Viewer surface is vertically flipped to use a top-left origin,
so `y=0` is the top edge and `y=65535` is the bottom edge. `HostInputMapper`
maps them directly to the selected window's current global screen geometry
supplied by the same OS snapshot. Normalized edge coordinates are clamped to
the half-open window rectangle so the right/bottom edge cannot spill into an
adjacent target. Every typed command carries
the selected window identity, owning application identifier, and generation.
The Host rechecks that application identifier against the current on-screen
owner before posting. Only typed pointer move/button,
scroll, keyboard, modifier, and focus-intent commands reach the adapter; mouse
buttons are limited to left, right, and center. Focus intent is an eligibility
signal and never activates a background window.

The real context provider checks Accessibility/post-event permission, the
current on-screen window identity, front-to-back window ordering, and console
lock state. The adapter repeats the complete target/focus/permission check
immediately before posting a `CGEvent`, then uses target-bound process posting
so a focus change cannot redirect the event to another frontmost application.

macOS does not expose a general public secure-input status query. The provider
therefore defaults to `unknown`, which is rejected, and accepts an explicit
local `inactive`/`active` signal only from a Host-owned provider. It never
infers secure-input safety from the Viewer or from received event data.

## Verification

`InputCoreTests` cover:

- normalized pointer and scroll mapping to selected-window screen geometry;
- keyboard modifiers and typed command construction;
- authorization, permission, focus, lock, secure-input, identity, and stale
  generation rejection;
- malformed modifier/button rejection, event rate limits and the state-ending
  safety lane, replay rejection, current-geometry mapping, serialized
  fake-adapter delivery, status consistency including disabled capabilities,
  unmatched-release rejection, safe
  release after authorization loss, and input-state reset/release. Host
  admission also enforces the configured encoded-payload bound.

The real adapter is not invoked by automated tests. Manual OS verification
must use a disposable foreground test application, grant Accessibility to the
signed Host bundle, confirm pointer/scroll/key behavior, then revoke or remove
the grant and verify that subsequent events are rejected. Do not use a
password field, login window, authentication dialog, or a production app.
