# M10 V1 Integration Pilot and Acceptance

## Scope

M10 is the final Intel Host to Apple Silicon Viewer acceptance run. Its sole
user-approved input-source extension is defined by
[ADR-0007](decisions/0007-m10-input-source-following.md); physical key transport
and Host-side IME composition remain unchanged. Use a disposable test
application whose content contains no private data; verify foreground input
with and without P6. Background selection/viewing remains supported, but
ordinary input requires explicit selection to foreground the selected regular
app and must stop if that app loses focus.

The repository now contains a production runtime composition in
`Apps/Host/HostRuntime.swift` and `Apps/Viewer/ViewerRuntime.swift`. On first
launch, the Host requests Screen Recording, performs a short Bonjour readiness
probe to trigger Local Network consent, then enrolls its local identity and
starts the authenticated listener. It advertises eligible windows, validates the
selected generation, captures and encodes it, and forwards authorized
input/clipboard messages. A Viewer discovers available Hosts and requires an
explicit Host choice, presents a picker for the eligible advertised windows,
decodes and presents H.264 frames through Metal, and forwards mouse/keyboard
events from the same aspect-fit surface. The Viewer can request a safe
same-session window replacement; the Host refreshes the window catalog while
connected and activates the explicitly selected regular application for all
peers. If the Host already has Accessibility trust, it may request a public
AXRaise for the exact selected window on the legacy path after an unambiguous
geometry match. Legacy input requires the exact selected target live, its PID
active, and a regular layer-0 window from that app frontmost. P6 adds Host
pairing trust and a control generation; foreground P6 uses the same optional
global secure-input policy as legacy input. Target-process AX inspection is
used only to classify an inactive target for safe cleanup. A fresh Host-side
PostEvent check must also pass. The Viewer visibly distinguishes Connecting, Connected, and
Reconnecting, and disables Connect while active. The Host's default Bonjour
name is its short macOS hostname, while the Viewer sends its hostname as
display-only pairing metadata. The Host remains resident when Screen
Recording or Local Network setup is incomplete and exposes a status-menu Retry
action. The production path now uses TLS bootstrap plus Keychain-backed
two-sided pairing: a first connection uses Host and Viewer commitments, then
the Host reveal and Viewer reveal before both endpoints independently derive the
same six-digit code; a fresh pairing shows a Host consent prompt and a Viewer
consent prompt that displays the code for comparison and requires explicit
acceptance. Host acceptance also establishes durable input trust for that
Viewer; no per-session control or Host clipboard consent prompt follows. A
later connection silently exchanges the same challenge when both trust
records match and reuses them without prompting. If
only one endpoint has a record, the other endpoint still receives the consent
flow and the completed exchange repairs both records. Each endpoint
automatically enrolls its own local P-256 identity in the login Keychain. The
Host status menu can rename the Bonjour display name and forget all saved peer
pairings; the Viewer exposes the same explicit trust reset action. Forgetting
pairings stops the active session but preserves the local device identity and
macOS permissions. The physical evidence below remains required; deterministic
build/test output must not be used as a substitute.

The app shell now provides native menus and version/build metadata on both
roles. Viewer Settings navigates within its existing main window; Host
Settings/About temporarily expose a regular application menu and Dock icon,
then return to menu-bar operation when closed. These are app-layer changes,
not a protocol revision. The rows below remain unchecked until exercised on
the target Macs; [dated local UI evidence](TESTING_CLEANUP.md#local-evidence-2026-09-26-021003)
is not physical acceptance.

## Current candidate and manual acceptance

The last public notarized `0.2.1011` RC was built from source commit `a63222e`,
with both app bundle plists set to Build `1011`. It includes the M6/M10
runtime follow-ups that were absent from the
superseded `0.2.1010` RC built from
`1e422da8799f183487276e2295008c6ebe499ec8`. Canonical CI, Apple notarization,
stapling, and release audit passed on 2026-10-13; see the
[release evidence](STATUS.md#021011-notarized-rc). This remains local build and
notarization evidence only. The operator elected to perform physical
acceptance manually, so every physical row below remains unchecked until the
operator records evidence for the exact installed build.

P6 control is available when both peers negotiate `backgroundControl` and the
Host has accepted the authenticated Viewer pairing. There is no separate Host
control prompt. Select an eligible on-screen Host app window, including one
occluded by another app; the picker excludes windows ScreenCaptureKit reports
offscreen, such as minimized or hidden/off-space windows. Video can continue
while the app is inactive, including during a short ScreenCaptureKit catalog
gap; a stream end is shown as recovery and only retries after same-owner
validation. To send input, explicitly select the window and confirm that Host
has activated the selected regular app and Viewer reports input ready only
while foreground eligibility remains true. P6 adds pairing, generation, and
exact target-identity checks; foreground P6 follows the same optional global
secure-input policy as legacy input. Target-process AX inspection applies only
to inactive-target cleanup classification and does not permit inactive-app
input. The Viewer must show focus loss as unavailable and must not hide missing
pairing trust, stale generation, unsafe target, permission loss, or secure-input
block.

Build `1018`, `1024`, `1025`, `1026`, and `1027` were previous in-house Debug
diagnostic pairs; their artifacts have been superseded in
`build/debug-diagnostic/`. Build `1028` was locally audited and Developer ID
signed, but not submitted to Apple. Build `1029` was accepted by Apple and
promoted, then withheld after source review found that distinct input rejection
provenance could be flattened into the same recoverable error. Do not use it
for physical acceptance. Build `1031` is the current validated M10 in-house
Debug pair; both role plists identify Version `0.2`, Build `1031`. Its complete
`.codex/ci.sh` validation, Developer ID signing, Apple notarization, stapling,
Gatekeeper checks, and final artifact audit passed on 2026-10-16. Physical
two-Mac acceptance remains open. Build `1030` is superseded. Its Dropbox
Viewer log copy records `attempted=0` through `05:45:49Z`; the local Viewer log
continues with 18 locally accepted `mouse_move` events at `06:04:12Z`,
`06:04:37Z`, and `06:05:48Z`, but no button or keyboard events. The Dropbox
Host copy has no matching input summaries for those later attempts and ends
at `05:46:07Z`, so these logs do not establish that the target app received a
click. They do show Host readiness alternating between
`background_target_ready` and `focus_unavailable`.
Build `1025` was the previous M10 diagnostic test pair: both source plists identify Build
`1025`, and the receive-side media policy lets a newer independently decodable
keyframe supersede queued older keyframes and delta frames while preserving
control messages and required media such as `VideoConfig`. Regression tests
cover a full incoming queue with multiple keyframes and the required-media
backpressure case. Build `1025` passed the complete local validation and was
tested on both Macs by the operator. Its signed/notarized Debug apps, ZIPs,
and DMGs were promoted to `build/debug-diagnostic/` at that time; they were
replaced by Build `1026`. The signed-artifact audit and stapled-ticket checks
passed on 2026-10-15. See the [Build 1018 artifact record](STATUS.md#021018-in-house-debug-diagnostic-artifacts),
the [Build 1024 artifact record](STATUS.md#021024-in-house-debug-diagnostic-artifacts),
and the [Build 1025 candidate record](STATUS.md#021025-m10-diagnostic-test-candidate).
These are internal test artifacts and candidates, not a public release or
physical acceptance claim. On 2026-10-14, the Viewer watchdog crashed when
`checkHeartbeat()` subtracted a newer heartbeat timestamp from an earlier
sample, trapping on unsigned underflow. The Host watchdog had the same race.
Both now sample in lock order and guard stale values; Host and Viewer
regression tests cover the ordering. Build `1018` included the former Host
clipboard consent sheet. The current M10 pairing-trust policy removes that
per-session Host prompt; accepted pairing enables the negotiated Host-side
clipboard capability, while the Viewer-local clipboard toggle remains, and
clipboard text is never logged. The physical acceptance rows below remain
unchecked. The operator confirmed Bonjour/TLS communication and a Host frame
reaching the Viewer before the disconnect recurred on Build `1025`; complete
the remaining rows against the tested pair. The Build `1022` log analysis and the
resulting input-failure recovery are recorded in the
[Build 1023 artifact record](STATUS.md#021023-in-house-debug-diagnostic-artifacts).

Build `1026` was the previous packaged in-house Debug diagnostic pair. Its
Host and Viewer source plists identify Build `1026`; only a positively
identified authorization change rejected before transport can preserve the
Viewer video session when a held-state release fails. Host holds an
input-admission fence, discards queued input, and resets held state before wire
authorization changes; the fence remains until the authorization receipt.
Local input-admission pause/resume also fences and resets. Generic readiness,
reconnect-required, local preflight, fallback, and unknown or post-transport
failures stay terminal when held state may remain. Focused Host and Viewer
tests passed (40/40 and 53/53). Full `.codex/ci.sh` validation and four Apple
notarization submissions passed on 2026-10-15. Its artifacts were superseded
by Build `1027` in `build/debug-diagnostic/`.

Build `1026` physical input diagnostics showed Viewer connection 2 made 54
input attempts: 22 were locally accepted and 32 were rejected as
`authorization_not_ready` before transport. The paired Host diagnostic summary
reported 22 received and 22 calls to the PID-targeted event-post API, with no
Host rejections; this does not establish that the app consumed those events.
The latest Dropbox Host log is Build `1026`, server modified at
`2026-10-15T07:53:14Z`, and ends at `07:53:06.747Z`. On connection 4, Viewer
acknowledged selection at `07:33:47Z`. The local click test recorded three
events accepted by Viewer transport with no send failures at `07:36:21.241Z`;
Host recorded three received, admitted, and injected events at `07:36:21.021Z`,
with zero rejections or permission, authorization, focus, and target failures.
An `injected` count means the Host posting API was called, not that the target
app consumed the event. Connection 4 continued streaming until Viewer logged
`stopping`, a peer `close`, and cleared selection at `07:45:57Z`; Viewer opened
connection 5 about one second later. That new session connected without a
selected window, so no video resumed. The stop was about nine and a half
minutes after the click and the Host recorded no rejection for it, so these
logs do not support attributing the later stop to that click. The reason for
the peer close is not recorded, and target-app response remains unverified.
Repeated main-actor stalls around 0.8–1.1 seconds remained visible. Physical
click-delivery acceptance therefore remains open.

### 0.2.1031 M10 in-house Debug diagnostic artifacts

The statements in this artifact record describe Build 1031 at the time it was
generated; current source policy now requires foreground input for every peer.
Both role plists identify Version `0.2`, Build `1031`. This build includes the
M10 P6 background-target correction: eligibility now follows the exact live
WindowServer target and its process-specific safety checks, without being
invalidated by unrelated foreground-window overlap classification. The
foreground-only path remains separately checked, and background input does
not activate the selected app.

The full `.codex/ci.sh` gate passed on 2026-10-16, including Host `arm64` and
`x86_64`, Viewer `arm64`, deterministic tests, the M8 benchmark, and M9
testing-channel audit. Host and Viewer Debug apps and DMGs were Developer ID
signed, accepted by Apple, stapled, and passed signature, Gatekeeper, ticket,
and final package audits. Apple submission IDs: Host app ZIP
`2639e1b3-1b9a-4a2f-a757-fef3c00ba664`, Viewer app ZIP
`dba324da-7c24-40d8-a748-b5bd2407b28f`, Host DMG
`0b6bb1a3-7959-46bf-803b-0faff58e629b`, Viewer DMG
`0236bb9b-1ae7-4315-bc91-894cfc9488fd`. The signed and notarized artifacts
are in `build/debug-diagnostic/`:

| Delivered DMG | SHA-256 |
| --- | --- |
| `MacRemoteApp-Host-debug-diagnostic-0.2.1031.dmg` | `9f09baa380ab650e0df1f0e6741ef3dc1a6a13520e669deb8a4d1c713d83cd84` |
| `MacRemoteApp-Viewer-debug-diagnostic-0.2.1031.dmg` | `d2ef32ae9d96d72e3aa0038489130247ea9cd4d334d5a08db390ffa452945dce` |

The physical two-Mac background-selection and input-delivery test remains
pending. For this historical build, local validation and Apple notarization do
not establish that an inactive target app consumed its posted mouse or keyboard
events. Current source acceptance checks foreground input and focus loss.

### 0.2.1030 M10 in-house Debug diagnostic artifacts

Build `1030` is a historical, superseded diagnostic pair. At artifact
generation, both role source plists identified Version `0.2`, Build `1030`.
Only a send observation that positively identifies
`authorizationEpochChangedAfterAdmission` receives the held-state recovery
exception: the Viewer invalidates the old input scope, rechecks readiness, and
keeps the authenticated session. An admission-token mismatch, an expected
authorization-generation mismatch rejected before admission, or a
post-admission authorization rejection with nil/unknown provenance does not
receive that exception. If held key or button state may remain, those failures
end the session so Host cleanup runs. Without possible held state, pre-transport
failures still invalidate the old input scope and permit readiness rechecking.
Failures after transport invocation remain delivery-uncertain and end the
session when held state may remain.

Deterministic coverage currently checks the real pre-transport rejection
observation in TransportCore, Viewer provenance mapping/classification, and
the held-state lifecycle policy in separate tests. There is no end-to-end
`ViewerInputTransport.send` fixture that forces the post-admission epoch race;
the production-path combination remains unverified.

The full `.codex/ci.sh` gate passed on 2026-10-16, including Host `arm64` and
`x86_64` builds, Viewer `arm64`, deterministic tests, the M8 benchmark, and M9
testing-channel artifact audit. Host and Viewer Debug apps and DMGs were
Developer ID signed, accepted by Apple, stapled, and passed signature,
Gatekeeper, notarization-ticket, and final package audits. Apple submission
IDs: Host app ZIP `db3c53ab-9b58-4fef-bc63-aa016580bd61`, Viewer app ZIP
`d9edf258-5643-4330-979c-1e486a8a096b`, Host DMG
`5f80c94f-24e5-4d58-aa36-a33c501ff7e2`, Viewer DMG
`a28327e2-5ee4-4813-b558-d2b691e265d8`. The signed and notarized Build `1030`
DMGs were superseded and replaced in `build/debug-diagnostic/` by Build
`1031`; their hashes below are the historical generation record:

| Delivered DMG | SHA-256 |
| --- | --- |
| `MacRemoteApp-Host-debug-diagnostic-0.2.1030.dmg` | `c362f52beb713ee9559ff32b572a4167c0fd52fee5552d9f5bd01c99cd41b86c` |
| `MacRemoteApp-Viewer-debug-diagnostic-0.2.1030.dmg` | `354b80884ca99fd3d4a695aa8c9335561878facdd79235147620242dd2618dd3` |

Physical two-Mac acceptance is still pending. The Dropbox Viewer log copy
records `attempted=0` through `05:45:49Z`, while the local Viewer log later
records 18 locally accepted mouse moves across three input windows; it records
no button-down, button-up, or keyboard events. The Dropbox Host log has no
matching input summaries for those later Viewer moves and ends at `05:46:07Z`.
Therefore the logs identify Host readiness instability and Viewer-side
readiness suppression, but do not establish a click reaching the Host or the
target app. Build `1031` is the current validated and notarized in-house Debug
pair; physical acceptance remains open.

### 0.2.1029 M10 authorization-epoch recovery candidate — withheld

Both role source plists identify Version `0.2`, Build `1029`. The
TransportCore admission token now binds the full required capability set,
while preserving the expected authorization-generation check before
admission and the generation recheck after the outbound mutex. Viewer
diagnostics use fixed categories to distinguish an admission-token mismatch
from an authorization epoch that changed after admission, both before
transport invocation. The stale old-scope event is discarded and the Viewer
can resume input only after its scope is refreshed. A failure after transport
invocation remains delivery-uncertain and session-ending when held state may
remain.

The 1028 Viewer log showed repeated pre-transport authorization failures but
did not distinguish these rejection sites, so it does not prove which site
caused the observed failures. The focused TransportCore admission regression,
Viewer stale-scope recovery integration test, and diagnostic-classification
test passed; the full `.codex/ci.sh` gate passed for the code before the 1029
metadata update. Apple accepted Build `1029`'s notarization and its Debug DMG
was promoted. A later source review found that the Viewer mapped an
admission-token mismatch and an authorization epoch change after admission to
the same recoverable typed error. Build `1029` is withheld and must not be used
for physical acceptance. Build `1030` contained the source correction; its
complete `.codex/ci.sh` gate, Developer ID signing, Apple notarization,
stapling, Gatekeeper checks, and artifact audit passed on 2026-10-16. Build
`1030` is superseded by the validated and notarized Build `1031` in-house
Debug pair. Physical two-Mac acceptance remains pending.

### 0.2.1028 M10 previous in-house Debug diagnostic artifacts

Build `1028` adds bounded Viewer subcategories for authorization failures
rejected before transport and fixed input-event-kind aggregates on both Viewer
and Host. The counters record only fixed categories and event kinds; they do
not include key or pointer values, coordinates, window titles, clipboard text,
or raw error messages. Both role apps retain the production bundle identifiers.

The complete `.codex/ci.sh` gate passed on 2026-10-15. The Debug Host
`arm64`/`x86_64` and Viewer `arm64` apps, ZIPs, and DMGs were Developer ID
signed with hardened runtime and empty Debug entitlements. The package and
final DMG audits passed. These artifacts were previously staged in
`build/debug-diagnostic/`; the channel directory now contains Build `1031`:

| Delivered DMG | SHA-256 |
| --- | --- |
| `MacRemoteApp-Host-debug-diagnostic-0.2.1028.dmg` | `7af5a6ecbf603357660b7bd46c30333edeec656ed4265124de7269f052a7c6af` |
| `MacRemoteApp-Viewer-debug-diagnostic-0.2.1028.dmg` | `188ae0f9577772b564726a88159593d45fa18f2a3d1af3f58cf9ffc65a18324d` |

Build `1028` was not submitted for notarization and has not been installed or
physically tested. In the latest local Viewer log, the UI reported `ready` at
`09:10:07.976Z`; 112 of the following 211 input attempts failed before
transport under the broad `authorization_not_ready` category. The Dropbox Host
log is still Build `1027` and ends at `08:51:20Z`, so it does not cover that
Viewer interval. Its earlier three admitted/injected events show that the Host
called the posting API, not that the target app consumed the events. Physical
input delivery remains unverified. Build `1029` later added distinct rejection
classification, but it is withheld because the Viewer flattened an admission-
token mismatch and a post-admission epoch change into the same recoverable
typed error. Build `1030` was the previous source/artifact pair and is now
superseded by Build `1031`. The Dropbox Viewer copy has no attempts in its
captured interval; the local Viewer continuation contains only mouse-move
attempts and no click events, with no matching Host records. Physical input
still needs a correlated retest using Build `1031`.

### 0.2.1027 M10 in-house Debug diagnostic artifacts

This section preserves the historical Build 1027 behavior and does not define
current input policy, which requires the selected app to be foreground.
Both role source plists identify Version `0.2`, Build `1027`. The picker
includes eligible windows that ScreenCaptureKit reports on-screen, including
occluded inactive app windows; minimized, hidden, and off-space windows remain
excluded. CaptureCore can re-resolve the exact previously authorized target
while inactive/offscreen. InputCore falls back to the current-session full
WindowServer list only when that target ID is absent from the ordered onscreen
list, while requiring exact window/PID/bundle identity, layer 0, safe geometry,
the authorized generation, pairing trust, PostEvent permission, known-safe
global and target secure-input checks, and an unlocked console session. This
does not activate the selected app. Mouse buttons remain PID-targeted through
the accepted CoreGraphics API; neither tests nor Host "injected" counters
prove app-level event consumption.

Focused CaptureCore and InputCore regression tests cover the picker boundary,
exact full-list target resolution, unresolved overlapping-window rejection,
and target-bound background mouse input. The complete `.codex/ci.sh` gate
passed on 2026-10-15, including Host arm64/x86_64 and Viewer arm64 builds,
package/app tests, the M8 benchmark, and M9 local packaging audit. Host and
Viewer apps, ZIPs, and DMGs were Developer ID signed, accepted by Apple,
stapled, and passed final signature, Gatekeeper, and notarization-ticket
audits. Apple submission IDs: Host app ZIP
`87d6a242-57cc-4516-b219-09185d532de8`, Viewer app ZIP
`1e3d09e4-12b2-4476-b804-197a70ea2c2f`, Host DMG
`cfeb2c5f-0230-4194-ac51-17c7ec850590`, Viewer DMG
`9e070db3-1f96-4e48-a518-e24ec5c13ecd`. At the time these hashes were recorded,
the installable DMGs were in `build/debug-diagnostic/`; Build `1031` has since
replaced the channel directory. SHA-256: Host
`9d5bb85fbbb484c9436777fd5652e08f250fe1a61a1f1a42ec293491f04780b4`, Viewer
`6051b97878f140ae75a3266f63fbc7f1f55c4a0aabb07e0428822f306ef7ac62`.
Physical Build `1027` acceptance is still pending, including selecting an
inactive app, confirming background readiness, and delivering mouse and
keyboard events to a disposable target app.

The Build `1024` Viewer log from the 2026-10-15 two-Mac diagnostic run recorded
repeated `incoming_message_backpressure` failures at 01:37:17.850Z and
01:37:40.910Z. The paired Host log recorded transport EOF at 01:37:17.770Z and
01:37:40.774Z after the Viewer initiated close. The receive/presentation path
also showed repeated roughly 0.8–1.0 second main-actor stalls. Build `1025`
was intended to retest whether queued-frame supersession removes this
disconnect cause. Its focused regression and full local validation passed on
2026-10-15, but the physical retest still reproduced the disconnect after the
first Host frame, so the media-backlog fix is not yet established.

In the separate Build `1025` click run on 2026-10-15, Viewer connection 3
selected a Host window at 05:59:32.896Z and logged readiness at 05:59:33.069Z.
The Viewer recorded 66 locally accepted input events; at 05:59:37.829Z its
second input window logged two send failures—one `authorization_not_ready` and
one `held_state_release_failure`—then started reconnect sequence 4. Host
logged `transport_eof` at 05:59:36.894Z; its delayed aggregate reported 66
received, 64 injected, and two rejected (one authorization and one invalid
event). The redacted records do not identify the rejected events, and the
deployed Viewer log lacks the underlying failure and boundary fields, so the
exact cause of the held-state failure is unknown. Keep the physical M10
disconnect-recovery acceptance row open until Build `1026` is retested.

## Prerequisites

1. Build the release candidates on the current checkout:

   ```bash
   export MACREMOTEAPP_SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
   bash scripts/release-notarized.sh rc
   ```

   This first runs the canonical `scripts/validate.sh` repository validation.
   Only after deterministic CI passes does it
   build, submit, staple, and validate versioned RC DMGs such as
   `MacRemoteApp-Host-0.2.1011.dmg` and `MacRemoteApp-Viewer-0.2.1011.dmg`,
   together with the stapled app bundles. The command above targets
   `build/rc/`; without a channel argument the default is `build/release/`, outside
   `.build`. Local artifacts are organized under `build/testing/`,
   `build/beta/`, `build/rc/`, and `build/release/`; the whole `build/` tree
   is excluded through `.git/info/exclude` and must never be staged or pushed.
   Use `bash scripts/release-notarized.sh beta` or `rc` for those channels.
   The release lock is acquired through the macOS kernel-backed `lockf` utility.
   Validation receives `--clean` and removes only `.build/public-validation/`
   under its validation lock; after a successful release, only the dedicated
   `.build/notarized-release-build/` cache is removed. Other `.build` caches
   and the public validation results remain available.
   The operating system releases the advisory lock after an interrupted run;
   unexpected directory or symlink lock paths fail closed. The existing selected channel remains in
   place while the new release is built, signed, and notarized beside it. The
   new channel is promoted only after final validation; a failure before
   promotion leaves the old channel intact, while a failure during promotion
   restores it.
   The successful CI and notarization flow removes only the release-owned build
   cache. The script reads the owner-only shared
   `~/.config/codex/notarization.env`; an explicit
   `MACREMOTEAPP_NOTARY_PROFILE` overrides it. With no shared default, the
   fallback is `notarytool-profile`. Shared settings can select a Keychain
   profile or the existing external API-key reference; see the
   [configuration contract](../README.md#physical-m2-test).
   Do not place credential material or signing configuration in the repository.
   A new Apple submission requires release authorization. The `0.2.1011` RC
   was submitted and accepted under the operator's explicit DMG request.
   If a separate read-only profile diagnostic is useful, run it in the same
   logged-in macOS session that will run the release command:

   ```bash
   bash scripts/check-notary-profile.sh \
     "${MACREMOTEAPP_NOTARY_PROFILE:-notarytool-profile}"
   ```

   This diagnostic does not submit an artifact or print profile credentials.
   It is advisory only; the release flow validates the profile through the
   actual `notarytool submit` calls. A Codex or app-server runner can have a
   different visibility context for the separate history operation.
   Each role-specific DMG also contains `MacRemoteApp-User-Guide.txt`,
   `MacRemoteApp-How-to-Debug.txt`, and
   `MacRemoteApp-How-to-Collect-Debug-Logs.txt` beside the install and
   uninstall commands.
   To validate that exact notarized directory without rebuilding or uploading,
   run:

   ```bash
   bash scripts/validate-notarized-release.sh \
     "$PWD/build/rc"
   ```

   `scripts/notarize-device-apps.sh` is the lower-level operation. Without
   `MACREMOTEAPP_RELEASE_ROOT`, it writes to a fresh controlled staging
   directory under `build/`; with that variable, the directory must be an
   absent or empty controlled staging directory. Use
   `scripts/release-notarized.sh` for the complete clean-channel CI-gated
   release flow.

2. On the Intel Host, complete the first-run setup shown by the signed Host
   app. Screen Recording is requested first; a short Bonjour readiness probe
   then gives macOS an opportunity to present Local Network consent before the
   Host enrolls its local identity. The Host remains running if either permission is denied;
   use the status-menu `Retry setup` item after changing System Settings.
   After a
   Viewer negotiates input and the operator selects a window, the signed Host
   requests PostEvent access from the Host bundle. Accessibility may also be
   requested as an optional secure-input/exact-window-raise enhancement. If
   it is unavailable, the Host may still activate the app for every peer.
   Legacy and foreground P6 input remain blocked until the selected PID is
   active and a regular layer-0 window from that app is frontmost. P6 uses the
   same optional global secure-input policy as legacy input; target-process AX
   inspection is needed only to classify an inactive target for safe cleanup.
   The exact selected target must remain live. Until PostEvent
   is authorized, the Host remains view-only and does not authorize
   mouse/keyboard capabilities.
   The capability may still appear in the negotiation offer; authorization is
   the security gate that reflects the current permission state.
   Install the role-specific app by dragging it onto the DMG's per-user
   `Applications` drop target, or use its optional
   `Install-MacRemoteApp-*.command` helper. Both paths install under the
   current user's `~/Applications`; the DMG helper is double-click-only and
   has no CI or testing options. The repository-only
   `scripts/install-device-apps.sh` is reserved for debug/release workflows.
   On the Apple Silicon Viewer, grant Local Network access.
3. No production identity file is required. On first launch, each app creates
   or reuses its own P-256 TLS identity in that Mac's login Keychain. Never
   copy a private key or PKCS#12 file into the repository or to the other Mac.
   Generate fresh M2 identities outside the repository only when running the
   explicit debug physical-smoke commands below.

The production Host and Viewer use separate Keychain identity labels and
peer-trust services, so both roles can run on one Mac without attempting to
use the same private key. If upgrading from a build that used the former
shared namespace, pair once after upgrading: old shared trust is not imported
and remains untouched by the upgrade. The diagnostic
`MACREMOTEAPP_LOCAL_IDENTITY_LABEL` value is a base; the app appends `.host` or
`.viewer` before using it.

When launching the installed production bundles below, do not set
`MACREMOTEAPP_PEER_CERT` for the normal AirPlay-like first-pairing flow: the
Host and Viewer enroll their local TLS identities, establish the presented
peer identities, complete commit/reveal, independently derive and compare the
same six-digit code, require local consent on both endpoints, and then save
the peer records in the Keychain.
`MACREMOTEAPP_PEER_CERT` remains an optional pinned-peer migration/diagnostic
path. `MACREMOTEAPP_LOCAL_IDENTITY_LABEL` remains a controlled diagnostic
override for the generated identity label.

The debug role commands below intentionally exercise the existing M2/M7
physical smoke harness, which uses explicit PKCS#12 identities and pinned
public certificates. For those commands only, set `MACREMOTEAPP_PEER_CERT` as
documented in `docs/M2_PHYSICAL_SMOKE.md`; that legacy test setup is separate
from the production bundle's first-pairing flow.

## Debug stall reproduction package

The M10 Debug diagnostic apps help reproduce a Host event/UI stall while
keeping its production bundle identifiers and executable names. They are
separate SwiftPM `Debug` builds staged in a fresh `.build/m10-debug-diagnostic/`
generation, with Host arm64+x86_64 and Viewer arm64 binaries, versioned
channel-specific ZIPs and signed DMGs. The package is audited before an atomic
promotion to `build/debug-diagnostic/`; failed builds or audits preserve the
previous debug channel, and promotion rolls back if final validation fails. The
`--check` mode previews the channel and build path without building or creating
output:

```bash
bash scripts/package-debug-diagnostic-apps.sh --check
```

To prepare Gatekeeper-acceptable packages for a two-Mac reproduction, the
dedicated entry point builds, signs, submits and staples the Debug apps and
DMGs in an isolated generation, validates tickets, then atomically promotes
the exact Debug channel:

```bash
bash scripts/notarize-debug-diagnostic-apps.sh
```

This command uploads artifacts to Apple. Run it only with explicit
notarization authorization and the existing Developer ID/notarization
configuration. The package uses the same Host and Viewer app identities as
Release, so install it in place of the current role apps; it shares their TCC
permissions and Keychain pairing and cannot run alongside them. Use the DMG's
Applications drop target on the Intel Host and Apple Silicon Viewer Macs, then
reinstall the Release artifacts after the reproduction. Do not reset TCC or
Keychain state for this run.

Reproduce with a disposable foreground app on both endpoints. Debug Host and
Viewer automatically write a bounded local JSONL log at launch. Use Host's
**Open Debug Log…** status-menu item and Viewer's **Open Debug Log…**
application-menu item; if either app is stuck, use the Finder paths and
collection steps in [M10 Debug log collection](DEBUG_LOG_COLLECTION.md).
Attach both role logs for connection, authorization, selection, input, and
blank-video failures. The logs distinguish per-process runs and correlate
across Macs by UTC time; they contain only fixed events, counts, booleans, and
timings. Viewer input windows distinguish send attempts, local acceptance, and
send failures from Host received/admitted/injected totals. The Host file is
`~/Library/Logs/MacRemoteApp/Host/m10-debug-host.log`; the Viewer file is
`~/Library/Logs/MacRemoteApp/Viewer/m10-debug-viewer.log`. The writer keeps one
previous file beside the current file, and older records eventually rotate
out. Historical Build `1018` Host clipboard-consent diagnostics use fixed
prompt lifecycle states and contain no clipboard content. The current runtime
does not show a Host clipboard consent prompt.
This is in-house Debug evidence only. Release
customer diagnostics remain a separate future opt-in workflow. Diagnostic
events and timings do not complete the physical acceptance rows below or
establish production performance.

## Acceptance sequence

| Step | Acceptance evidence | State |
| --- | --- | --- |
| Fresh install | Host/Viewer app bundles launch and signatures verify | ☐ |
| Startup permissions | Host Local Network and Screen Recording, plus Viewer Local Network, are granted to the signed app bundles | ☐ |
| User documentation | Each DMG contains the User Guide, debugging guide, and debug-log collection guide | ☐ |
| Pairing | Host and Viewer complete commit/reveal, display the same independently derived six-digit code, operators compare it, Host allows and Viewer explicitly accepts, and trust records are stored | ☐ |
| Pairing recovery | Host and Viewer can explicitly forget their own role's saved peer pairings; the next connection requires a new code and local identity records remain intact | ☐ |
| Full uninstall reset | The standalone `Uninstall-MacRemoteApp.command` verifies installed signed cleanup helpers, clears both roles' current-user data and role-owned Keychain state, resets only the two product bundle IDs' TCC decisions, and moves removable apps to Trash. Check explicit partial-result reporting; Local Network revocation is manual and legacy shared records remain preserved | ☐ |
| Host display name | Host `Rename Host…` changes the Bonjour discovery name and the listener restarts without changing the TLS identity | ☐ |
| Default/display device names | Host defaults to its macOS short hostname; Viewer pairing UI and trust metadata use the Viewer hostname; names never affect authentication | ☐ |
| Window selection | Select one eligible on-screen Host app window, including one occluded by another app. The Viewer may continue showing it while inactive; explicit selection must foreground the selected regular app before input becomes ready. The picker excludes minimized, hidden, and off-space candidates | ☐ |
| Same-session app/window switching | Replace the selected app without reconnecting. Verify old-target input and held state are released, capture follows the new selection, Host foregrounds the newly selected app, and ordinary events are dispatched only after the selected PID is confirmed foreground. WindowServer hit-testing determines the recipient; physical receipt remains unverified across the final focus/overlay race | ☐ |
| P6 capability and pairing trust | Verify both peers negotiate `backgroundControl`; Host acceptance of pairing enables control without a second prompt. Deny pairing and confirm no control is authorized; accept pairing and verify a fresh control generation. Pause preserves video; unpair removes trust and ends the active session, and reconnect requires fresh pairing | ☐ |
| Focus-loss input safety | After selecting and foregrounding the app, switch to another Host app during mouse and keyboard input. Verify ordinary input stops immediately, Viewer readiness becomes unavailable, and admitted pressed state is safely released. Re-select the target and verify system-dispatched input resumes only after foreground, permission, pairing, generation, target, console, and secure-input checks pass | ☐ |
| Viewer connection state | Connect changes to disabled `Connected`; disconnect shows `Reconnecting…` during retry and re-enables Connect only when disconnected | ☐ |
| Native app menus | Both roles expose About with version/build, Settings, Minimize, Hide, and Quit; Host status menu also opens About/Settings | ☐ |
| Debug log access | In Debug builds, each role's **Open Debug Log…** action reveals its own automatically created file, and Finder fallback locates it when the UI is unavailable | ☐ |
| Watchdog stability | Run both Debug apps through repeated connect, disconnect, window selection, and idle periods; neither watchdog traps or crashes, and logs append across relaunches | ☐ |
| Host clipboard authorization | After Host accepts pairing and both peers negotiate text clipboard, verify the Host authorizes the capability without a per-session dialog. Confirm the Viewer still requires its local clipboard toggle before syncing text; unpair removes capability and ends the session | ☐ |
| Release identity | About, Settings, Viewer title/status, and Host status menu match both installed plists; `major.minor.build` means separate short version and build, not wire protocol version | ☐ |
| Viewer settings navigation | Settings uses the same main window; Back, Command-0, and Command-W return to remote view; switching during a connected session releases held input and preserves the session | ☐ |
| Host settings lifecycle | Runtime and permission status refresh; closing settings keeps Host running, and the app returns to menu-bar operation after its windows close | ☐ |
| Capture/display | Viewer renders the selected window with aspect preservation | ☐ |
| Background selected-window stream | Keep the selected Host window unminimized, switch to another app and cover it for at least 30 seconds. Confirm Viewer frames continue without activating either app. If ScreenCaptureKit ends the stream, verify a visible bounded recovery resumes the same selected target without reconnecting. Minimize or close the target separately and confirm target loss does not leave stale video or input active | ☐ |
| Display lifetime | Disconnect or window replacement clears the previous image immediately; late decode/presentation callbacks from the old session cannot restore it, including reconnects that reuse a wire generation | ☐ |
| Capture replacement race | Rapid window replacement during a slow capture stop/failure keeps the new selection and its stream alive | ☐ |
| Video backlog recovery | After encoder-relay overflow, pre-gap frames stay ordered; only a post-gap keyframe permits post-gap deltas to resume | ☐ |
| Performance | 30-second report has clock probes, valid samples, p50/p95, fps and resource data | ☐ |
| Input | Each authorized input capability works only while authorized; mouse-only or keyboard-only authorization keeps the other local controls disabled | ☐ |
| Viewer-led input source | EN/EN stays EN; Chinese/EN and EN/Chinese reach the Viewer's selected state without double toggling; matching Chinese mode composes/candidates on Host; missing/disabled Chinese source pauses keyboard with a clear status and leaves mouse available | ☐ |
| Input-source lifetime | Change source while typing, return from Settings, switch windows/apps, reauthorize, and reconnect; no old acknowledgement or queued key releases a different source/session; focus loss or secure input prevents Host source mutation | ☐ |
| Input-source compatibility | A peer without `inputSourceSync` continues manual Host IME input without receiving new messages; unsupported third-party internal modes are not presented as synchronized | ☐ |
| Clipboard | Host pairing trust enables the negotiated text capability without another Host prompt; the Viewer-local opt-in, text-only bounds, opt-out, and echo prevention work | ☐ |
| Permission recovery | Local Network, Screen Recording, or PostEvent denial/revocation disables the affected path and gives a recoverable instruction; all ordinary input requires foreground checks, and P6 requires known-safe global and target-process Accessibility inspection for inactive-target cleanup | ☐ |
| Window recovery | Close/change/target-safety loss or foreground loss disables input and reports a recoverable state; explicit reselection restores control only after the selected app is confirmed foreground | ☐ |
| LAN recovery | Disconnect shows reconnecting; reauthorization is required before input resumes | ☐ |
| Queued-input isolation | Held input is released on Settings navigation within the same authorization; window switch, reauthorization, and reconnect never replay queued old input, and a saturated input queue closes the affected session instead of losing a release | ☐ |
| Stale trust | Revocation or identity mismatch requires explicit re-pairing | ☐ |
| Failure UX | Malformed/unsupported/oversized input fails closed without sensitive diagnostics | ☐ |
| Post-test cleanup | After collecting evidence, stop test apps, clear scoped settings/trust/identity and permissions, remove test installations/review output, verify absence, and preserve source/release artifacts | ☐ |

Follow [UI Review and Post-test Cleanup](TESTING_CLEANUP.md) after the run.
Its dated local evidence does not complete the physical acceptance rows above.
For this check, background means the selected window is occluded by another
app, not minimized or hidden/off-space. ScreenCaptureKit continues to provide the full contents of
an occluded window, while its single-window stream pauses when the window is
minimized ([Apple's ScreenCaptureKit session](https://developer.apple.com/videos/play/wwdc2022/10155/)).

## Role commands

The following commands run the existing authenticated physical session smoke
from a debug build. They are transport/pairing evidence, not a substitute for
the complete table above:

```bash
# Intel Host
bash scripts/run-m10-acceptance.sh host

# Apple Silicon Viewer
bash scripts/run-m10-acceptance.sh viewer
```

The production binaries use their runtime by default when launched from the
installed app bundle. Launch the bundles themselves during setup so macOS
records TCC decisions against the signed app identity. No peer-certificate
environment variable is needed for the normal first-pairing flow:

```bash
open "$HOME/Applications/MacRemoteApp-Host.app"
open "$HOME/Applications/MacRemoteApp-Viewer.app"
```

For terminal-visible startup diagnostics, collect the unified logs described in
`docs/DEBUG_LOG_COLLECTION.md`; do not execute the file inside `Contents/MacOS`
when validating permissions.

The explicit M7 text-clipboard test path is available from the same debug
build when the clipboard row is being exercised. Host pairing trust enables
the negotiated capability without a Host consent sheet; the Viewer must still
use its local toggle to opt in. The path is limited to the bounded `.string`
pasteboard flow and prints a redacted UX state; it never logs clipboard
contents. The command remains connected for the operator's
copy/conflict/opt-out walkthrough; press Return to stop or type `disable`/`off`
to turn off clipboard sync before stopping:

```bash
# Intel Host
bash scripts/run-m10-acceptance.sh host-clipboard

# Apple Silicon Viewer
bash scripts/run-m10-acceptance.sh viewer-clipboard
```

The deterministic local gate, which does not claim physical interoperability,
is:

```bash
bash scripts/run-m10-acceptance.sh deterministic
```

Its temporary release audit is written to
`.build/m10-acceptance/release/`, not to the notarized release directory. The
complete `scripts/release-notarized.sh` flow removes that temporary tree after
CI and notarization succeed.

## Evidence and residual limitations

### Support and evidence matrix

| Combination | Current evidence | Acceptance state |
| --- | --- | --- |
| Intel Host (`x86_64`) → Apple Silicon Viewer (`arm64`), same LAN | Operator confirms Bonjour/TLS communication and reports that a Host window frame reached the Viewer before disconnect | Partial: live video was observed; full M10 input, recovery, clipboard, performance, and UI acceptance remains open |
| Local Apple Silicon build host, macOS `27.0.1` (`26A434`) | Canonical `0.2.1011` CI, release audit, and notarized universal Host / arm64 Viewer packaging passed | Local build evidence only |
| macOS `13.0` deployment minimum from both app plists | Deployment target declared; current-toolchain compilation passed | Minimum-OS launch, capture, codec, permissions, and UI unverified |
| Apple Silicon as a production Host | Host `arm64` builds for development | Not a verified V1 Host hardware target |
| Internet relay, locked-screen control, audio, files, and concurrent multi-window control | No implementation or acceptance scope | Unsupported |

### Manual run record

For each run, record the following without copying private data:

- Source commit, installed build on both endpoints, artifact hashes, and
  Developer ID / notarization verification results.
- Intel Host and Apple Silicon Viewer models, architecture, exact macOS
  versions/builds, LAN conditions, and granted permission state.
- Disposable target app and the negotiated capability set. For the current
  Debug pair, confirm `backgroundControl` is negotiated and record whether the
  Host pairing trust is active and whether the app is active. If checking backward
  compatibility, test a legacy peer separately and record its foreground-only
  behavior.
- Pass/fail/skipped for each acceptance row, with sanitized log/report paths
  and a concrete reason for each failure or skip.
- Physical M8 report: at least 20 clock probes, a 30-second measurement with
  at least 1,000 valid frame samples, p50/p95 latency, achieved fps/resolution,
  uncertainty/drift, and resource data. Synthetic benchmark output does not
  satisfy this row.
- Cleanup result and every retained exception. A partial cleanup result is
  recorded as partial; preserve source and release artifacts.

M10's implementation and manual handoff are ready. Product acceptance and the
release decision remain open until the operator attaches these physical
results; unchecked rows are not converted into passes by this handoff.

Archive only sanitized logs and the JSON performance report. Do not archive
screen captures, clipboard content, raw input values, private keys, or full
window titles. Record the exact Mac model, architecture, macOS build, app
signature identity, permission state, network conditions, selected test app,
and every unchecked item above. An unchecked physical item is an explicit V1
exception; it is not reported as verified.
