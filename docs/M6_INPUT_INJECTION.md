# M6 Host Input Injection

## Scope and status

M6 adds the Host-side input boundary for the typed M5 event model. The
implementation is complete for deterministic package and composition tests.
Actual OS event posting remains an explicit manual evidence step because it
requires local PostEvent access and can affect the selected test
application. P6 adds Host pairing and control-generation gates, but does not
permit input to an inactive process. Before input is authorized, an explicit
Viewer selection must foreground the selected regular app and confirm that its
PID is frontmost. No M7 clipboard behavior is included.

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
  context provider and the typed CoreGraphics event adapter. The adapter uses
  the public system Quartz event stream for ordinary input, so cursor position
  and normal hit-testing determine the recipient; it does not accept raw
  event archives.
- `TransportCore` and `SecurityCore` remain the sources of session/trust
  authorization facts. The Host supplies those facts to `InputCore`; a
  transport authorization result alone never posts an OS event.

## Admission matrix

Every event is checked immediately before adapter invocation:

```text
authenticated and authorized session
  AND authorized selected-window generation matches
  AND exact selected target still exists with valid geometry and layer 0
  AND selected target identity, owner, and process still match
  AND NSWorkspace.frontmostApplication PID matches the selected process
  AND top regular layer-0 WindowServer window belongs to the selected PID and bundle
  AND no overlapping unresolved layer-0 window can cover the selected target
  AND (if P6 is negotiated) Host pairing trust and control generation match
  AND (for foreground P6) the same global secure-input policy as legacy
      foreground input
  AND PostEvent permission is authorized
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

An inactive P6 target can support cleanup only when both the global and
target-process secure-input signals are known safe. This exception is limited
to releases of state admitted earlier while foreground; it never admits
ordinary input.

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

The real context provider checks PostEvent permission, the exact live
WindowServer target, front-to-back on-screen ordering, and console lock state.
Legacy and foreground P6 input use the same optional local Accessibility
secure-input signal: an active global signal blocks input, while an unknown
signal follows the established foreground behavior. P6 requires known-safe
global and target-process inspection only when classifying an inactive target
for safe cleanup; unavailable or mismatched inspection blocks that cleanup,
not foreground input. Immediately before ordinary posting, the adapter repeats
the target, generation, capability, foreground PID, and permission checks, then
sends the `CGEvent` through the public system event tap. WindowServer hit-tests
the cursor location. A focus or overlay change in the narrow check-to-dispatch
gap can alter the recipient, so physical receipt by the selected app remains
unverified pending two-Mac acceptance. Target-bound `postToPid` is reserved for controller-authorized
key/button release cleanup during reset, selection change, focus loss, or
authorization revocation, using the original admitted target identity; it
never carries ordinary input.

On an explicit Viewer window selection, including when P6 is negotiated, the
Host may activate the owning regular application before authorizing input. If
Accessibility trust is already available, it
may use the public AX window list and raise action to bring the exact selected
window forward. Matching uses global point geometry and verifies the local
window title when available; the title also breaks duplicate-geometry ties.
Missing, ambiguous, or mismatched candidates are not raised. App activation or
AXRaise is never proof of focus: input remains blocked until a fresh
WindowServer snapshot confirms foreground eligibility. P6 uses the same
foreground activation and input path; pairing and control generation add
authorization gates but do not enable inactive-process delivery. Accessibility
is optional for the legacy foreground path and is not a substitute for
PostEvent permission.

macOS does not expose a general public secure-input status query. The provider
therefore reports `unknown` when Accessibility inspection is unavailable.
Foreground/window checks protect the base PostEvent path, while P6 input fails
closed on unknown global or target state. A detected secure field remains
rejected, and an explicit local `inactive`/`active`
signal is accepted only from a Host-owned provider. It never infers secure-input
safety from the Viewer or from received event data.

## Keyboard layouts, dead keys, and input methods

Design decision (V1): the Viewer forwards physical key positions, and the
Host's active input source interprets them. The full policy is recorded in
[`PROTOCOL.md`](PROTOCOL.md#keyboard-layout-and-text-input-policy-v1-decision-m6).
For the M6 boundary this means:

- `HostInputMapper` copies `keyCode` and the device-independent `modifiers`
  mask into `HostInputCommand.key` unchanged. It does not remap key codes
  for ANSI/ISO/JIS differences. The original M6 physical-key path has no text
  command.
- `CoreGraphicsAccessibilityInputAdapter` posts that key code with a `nil`
  event source, so the target application uses the Host's keyboard layout,
  keyboard type, and input method. Dead-key and IME composition therefore
  happen in the Host application's text system, from the same ordered key
  events the Viewer received.
- Modifier key events are admitted and released like other keys. A reset
  releases admitted keys with an empty modifier mask.
- Viewer-side IME composition and committed-text events are a separate,
  user-approved M10 extension in
  [ADR-0008](decisions/0008-m10-viewer-text-composition.md). They are used only
  when the optional `textInput` capability is negotiated; marked text remains
  on the Viewer, and committed text passes the same Host authorization and
  secure-input checks as keyboard input. This does not add general character
  translation or change the M6 physical-key path.
- Key codes and modifier masks never appear in logs, errors, status, or
  receipts. The secure-input rejection applies regardless of layout or input
  method.

Manual OS evidence should include one mismatched-layout check (for example a
US Viewer with a Dvorak or JIS Host input source), one dead-key sequence, and
one Host IME composition in the disposable test application.

The approved M10 extension in
[ADR-0007](decisions/0007-m10-input-source-following.md) can select the enabled
Host input source before the physical-key sequence starts. This uses public
TIS source selection behind a fakeable `InputCore` policy boundary, not text
insertion. The same target, focus, permission, console, and secure-input
conditions apply immediately before selection, inside the session admission
and window-replacement fences. Chinese requires the matching enabled mode;
EN on an already-English Host is unchanged. Real source selection/composition
still requires physical acceptance, and automated tests must not change the
desktop's actual source. With ADR-0008 negotiated, Chinese composition occurs
on the Viewer and only committed text is sent; older peers continue to compose
on the Host.

## Verification

`InputCoreTests` cover:

- normalized pointer and scroll mapping to selected-window screen geometry;
- keyboard modifiers and typed command construction;
- the keyboard layout policy: Option/dead-key and modifier-shortcut
  sequences reach the adapter as ordered key commands with unchanged key
  codes and masks, ISO/JIS layout-specific key codes are not remapped, and
  key rejection, status, and receipt text contains no key value;
- authorization, permission, focus, lock, secure-input, identity, and stale
  generation rejection;
- malformed modifier/button rejection, event rate limits and the state-ending
  safety lane, replay rejection, current-geometry mapping, serialized
  fake-adapter delivery, status consistency including disabled capabilities,
  unmatched-release rejection, safe
  release after authorization loss, and input-state reset/release. Host
  admission also enforces the configured encoded-payload bound.

The real adapter is not invoked by automated tests. Manual OS verification
must use a disposable test application, grant PostEvent access to the signed
Host bundle, and confirm pointer/scroll/key behavior. Test P6 by starting with
the app inactive, explicitly selecting it, and confirming that control stays
unavailable until its PID is foreground. Verify ordinary events follow the
cursor and hit-testing, and that focus loss blocks new input while cleanup
releases remain target-bound. Then revoke the relevant permission or unpair the
Viewer and verify that subsequent events are rejected. Do not use a password
field, login window, authentication dialog, or a production app.
