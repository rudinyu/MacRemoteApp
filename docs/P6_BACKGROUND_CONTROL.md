# P6 Host-Controlled Viewer Input

## Scope and decision

The 2026-10-08 request authorizes finishing this existing post-V1 extension.
P6 is an explicit M6 input-policy extension beyond the V1 baseline and does
not close any physical M10 acceptance row. Other post-V1 features remain
deferred.

The control decision is a durable grant for an authenticated Viewer identity,
separate from pairing. This replaces the roadmap's earlier proposed
per-session consent requirement for P6. A saved grant may be reused on a new
authenticated session; a new identity requires a new local grant. Pause applies
to the current session; revoke removes the saved grant. Keychain failures block
control and must be reported. A failed durable revocation requires retry and
must not be presented as successfully saved across a Host restart.

## Control contract

P6 adds opt-in process-targeted mouse and keyboard input for an authenticated
Viewer. Pairing establishes identity; it does not grant input control. On the
first supported session, the Host asks locally and stores the grant in Keychain
under the authenticated Viewer identity. The Host can pause or revoke that
grant from its menu-bar control actions without stopping video sharing.

The optional `backgroundControl` capability uses protocol ID `0x000A`;
`keyframeRequest`, `receiverReport`, and `inputSourceSync` retain IDs `0x0007`,
`0x0008`, and `0x0009`. Session status carries a separate Host control state and
process-target safety signal. The existing `focusEligible` field remains a
truthful foreground signal: it may be false while an explicitly granted and
otherwise safe process target is ready. Viewer input readiness uses the P6
control state and process-target signal, not foreground eligibility.

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
with multiple windows. Secure input, a locked/non-console session, unknown or
unsafe target geometry, and lost Host input permission remain fail-closed.
Pausing or revoking immediately closes Host-side input admission and clears
pressed-input state while leaving the authenticated video path intact.

The focused tests cover the independent foreground/process-target protocol
signals and confirm that an authorized background process target is accepted
while the same target without local process-control authorization is rejected.
These checks are local unit tests, not two-Mac acceptance.

## Verification and remaining evidence

Deterministic checks must cover grant lookup/save/revoke failures, stale
consent or storage completions, pause/resume and queued-input invalidation,
permission loss, capability negotiation, and truthful Viewer readiness.
The canonical local gate is
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./.codex/ci.sh`.

Physical acceptance remains pending. On the Intel Host and Apple Silicon
Viewer, use a disposable application and verify initial denial/view-only,
local allow, reconnect with the saved identity, background mouse/keyboard
delivery without activating the Host app, pause with a held key/button,
resume, revoke, and new pairing. Confirm that video remains available while
control is paused or denied. Repeat with PostEvent revoked, secure input,
screen lock, target closure, and multiple windows of the same app. Record
which apps accept process-targeted events and any IME/candidate-panel limits;
do not infer support from a fake adapter or local build.
