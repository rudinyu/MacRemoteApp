# P6 Host-Controlled Viewer Input

## Scope and decision

**Status: active opt-in extension; physical acceptance pending.** P6 permits
the Viewer to keep viewing and control the selected Host app while it is
inactive, after capability negotiation and Host-local pairing acceptance. It does
not change the foreground-only behavior for peers without P6, and does not
permit locked-screen or secure-input control.

The 2026-10-14 product decision reaffirmed the selected-app workflow and
updates the earlier foreground-only rule to support the explicitly authorized
P6 process-target path described below.
P6 is an explicit M6 input-policy extension beyond the V1 baseline and does
not close any physical M10 acceptance row. Other post-V1 features remain
deferred.

The approved M10 integration keeps the selected-window video stream
independent of foreground eligibility. The picker may use an on-screen catalog,
but selected-window resolution uses the full ScreenCaptureKit catalog and
accepts `SCWindow.isActive` when an offscreen target is still streaming. A
brief missing catalog snapshot does not clear the Viewer selection; Host
withholds that catalog update while its selected target is still under
CaptureCore's bounded liveness check. Unexpected stream completion enters a
visible recovering state and permits at most two delayed restarts after the
same window ID, bundle ID, PID, layer, and valid geometry are rechecked. A
restart does not require `isActive`, since stream termination may clear it.
Confirmed target loss, permission loss, or owner mismatch still fails closed.
These capture rules do not authorize input, and no ScreenCaptureKit behavior
has yet been confirmed on the physical Intel Host/Apple Silicon Viewer pair.

Host acceptance of the authenticated Viewer pairing is the durable local trust
decision for input control; there is no separate Host control-consent prompt.
The pairing record is reused on subsequent authenticated sessions. Pause
applies only to the current session. Unpairing removes the saved trust record
and stops the active authenticated session, so reconnect requires a fresh
two-sided pairing. Keychain failures block control and must be reported; a
failed unpair remains fenced in the running Host and cannot be reported as
durable until the Keychain operation succeeds.

## Control contract

P6 adds process-targeted mouse and keyboard input for an authenticated,
paired Viewer. Accepting the Host pairing authorizes that Viewer for input;
negotiating `backgroundControl` alone does not. The Host automatically uses
the saved pairing trust on the first and later supported sessions. The Host
can pause the current session or unpair the Viewer from its menu-bar control
actions. Pause leaves authenticated video active; unpairing ends that session
and requires pairing again before reconnect.

The optional `backgroundControl` capability uses protocol ID `0x000A`;
`keyframeRequest`, `receiverReport`, and `inputSourceSync` retain IDs `0x0007`,
`0x0008`, and `0x0009`. Session status carries a separate Host control state and
process-target safety signal. The existing `focusEligible` field remains a
truthful foreground signal: it is true only when the selected process is the
active `NSWorkspace.frontmostApplication`, the exact selected target remains
a valid layer-0 window, and the top regular layer-0 WindowServer window
belongs to the selected PID and bundle. That top window may have a different
identifier, as with an app-owned sheet or popover. Only layer-0 windows
participate; nonzero-layer windows are excluded. An overlapping layer-0
window with an unresolved owner, or a window whose layer metadata is
missing, keeps foreground eligibility unknown. `focusEligible` may be false
while a paired and otherwise safe process target is ready.
Viewer input readiness uses the P6 control state and process-target signal,
not foreground eligibility, and labels that state as background control while
the app is inactive.

Control has its own positive wire generation, independent of the video
authorization epoch. The Host publishes it in `SessionState`; the Viewer
echoes it with input and input-source requests. Pausing, resuming, and revoking
advance that generation, so pre-pause messages delayed in TCP cannot become
fresh input after resume. Legacy peers omit the optional fields and retain
the foreground-only contract.

Background eligibility requires a known inactive secure-input signal;
unavailable inspection blocks background control. Legacy foreground input
retains its existing optional Accessibility inspection policy.
Viewer-led input-source following remains foreground-only because selecting
a Host input source changes global state. Background P6 input uses the Host's
current source and requires manual source matching; it must not switch the
source of another foreground application.

Process targeting does not activate the selected application. It targets the
selected process; exact-window targeting is not guaranteed for applications
with multiple windows. The Host's cooperative foreground activation is
reserved for an explicit legacy window selection and does not grant input by
itself; fresh active-process, layer-0 window, permission, geometry, and
per-event checks still apply. P6 never invokes that activation path. Secure
input, a locked/non-console session, unknown or unsafe target geometry, and
lost Host input permission remain fail-closed. Pausing immediately closes
Host-side input admission and clears pressed-input state while leaving
authenticated video active. Unpairing closes input admission, removes text
clipboard authorization, and stops the authenticated session after the
Keychain trust record is deleted.

The focused tests cover pairing-trust reuse on a new session and reconnect,
pause/resume, successful and failed unpairing, clipboard authorization after
pairing without a Host prompt, transient catalog gaps, bounded stream restart,
same-owner retry checks, and the independent foreground/process-target
protocol signals. These checks are local unit tests, not two-Mac acceptance.

## Verification and remaining evidence

Deterministic checks must cover trusted-pairing lookup and unpair failures,
stale storage completions, pause/resume and queued-input invalidation,
permission loss, capability negotiation, and truthful Viewer readiness.
The canonical local gate is
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./.codex/ci.sh`.

Physical acceptance remains pending. On the Intel Host and Apple Silicon
Viewer, use a disposable application and verify pairing denial/view-only,
pair acceptance, reconnect with the saved identity, continued Viewer frames
after the app becomes inactive or occluded without activating it, and recovery
after a stream interruption. Then verify background mouse/keyboard delivery,
pause with a held key/button, resume, revoke, and new pairing. Confirm that
video remains available while control is paused or pairing is denied. Repeat
with PostEvent revoked, secure input, screen lock, target closure, and multiple
windows of the same app. Record which apps accept process-targeted events and
any IME/candidate-panel limits; do not infer support from a fake adapter or
local build.
