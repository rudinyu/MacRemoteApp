# M10 V1 Integration Pilot and Acceptance

## Scope

M10 is the final Intel Host to Apple Silicon Viewer acceptance run. Its sole
user-approved input-source extension is defined by
[ADR-0007](decisions/0007-m10-input-source-following.md); physical key transport
and Host-side IME composition remain unchanged. Use a disposable test
application whose content contains no private data; verify foreground legacy
input and the paired-trust P6 inactive-app path.

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
connected and activates the explicitly selected regular application for peers
without P6. With P6, the selected app remains at its existing activation
state. If the Host already has Accessibility trust, it may request a public
AXRaise for the exact selected window on the legacy path after an unambiguous
geometry match. Legacy input requires the exact selected target live, its PID
active, and a regular layer-0 window from that app frontmost. P6 instead
requires its authorized process-target and secure-input checks. A fresh Host-side PostEvent
check must also pass. The Viewer visibly distinguishes Connecting, Connected, and
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

P6 process-target control is active when both peers negotiate
`backgroundControl` and the Host has accepted the authenticated Viewer pairing.
There is no separate Host control prompt. Select the Host app once; Viewer should keep showing its selected
window and report background-control readiness when the app is inactive. Video
continues without activating the selected app, including during a short
ScreenCaptureKit catalog gap; a stream end is shown as recovery and only retries
after same-owner validation. Then deliver mouse and keyboard input to the
selected app without activating it. Peers without P6 retain foreground-only
input and the cooperative activation path.
The Viewer must distinguish “app not active” from ordinary foreground “Input
ready”; neither status may hide missing pairing trust, stale generation, unsafe
target, permission loss, or secure-input block.

Build `1018` remains a historical in-house Debug diagnostic pair staged under
`build/debug-diagnostic/`; it was signed, notarized, stapled, and passed the
notarized-artifact audit. Build `1024` is the latest retained Developer ID
signed, notarized, stapled, and audited in-house Debug artifact pair. Its full
`.codex/ci.sh` gate passed before packaging. Build `1025` is the current M10
source-level diagnostic test candidate: both source plists now identify Build
`1025`, and the receive-side media policy lets a newer independently decodable
keyframe supersede queued older keyframes and delta frames while preserving
control messages and required media such as `VideoConfig`. Regression tests
cover a full incoming queue with multiple keyframes and the required-media
backpressure case. The candidate has not been built, validated, signed, or
packaged. See the [Build 1018 artifact record](STATUS.md#021018-in-house-debug-diagnostic-artifacts),
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
unchecked and should be completed against the exact installed Build `1025`
pair after validation and packaging. The Build `1022` log analysis and the
resulting input-failure recovery are recorded in the
[Build 1023 artifact record](STATUS.md#021023-in-house-debug-diagnostic-artifacts).

The Build `1024` Viewer log from the 2026-10-15 two-Mac diagnostic run recorded
repeated `incoming_message_backpressure` failures at 01:37:17.850Z and
01:37:40.910Z. The paired Host log recorded transport EOF at 01:37:17.770Z and
01:37:40.774Z after the Viewer initiated close. The receive/presentation path
also showed repeated roughly 0.8–1.0 second main-actor stalls. Build `1025`
is intended to retest whether queued-frame supersession removes this disconnect
cause; transport tests and the canonical validation remain pending, and this
candidate does not establish a physical fix yet.

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
   The release lock is acquired through the macOS kernel-backed `lockf` utility
   and the repository `.build` cache is removed before deterministic validation.
   The operating system releases the advisory lock after an interrupted run;
   unexpected directory or symlink lock paths fail closed. The existing selected channel remains in
   place while the new release is built, signed, and notarized beside it. The
   new channel is promoted only after final validation; a failure before
   promotion leaves the old channel intact, while a failure during promotion
   restores it.
   The successful CI and notarization flow removes the repository `.build`
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
   it is unavailable, the Host may still activate the app for peers without
   P6, but legacy input remains blocked until the selected PID is active and a
   regular layer-0 window from that app is frontmost. P6 requires its strict
   known-safe process-target check instead. The exact selected target must
   remain live. Until PostEvent
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
| Window selection | Select one eligible Host app window. After Host pairing acceptance and negotiated P6, verify Viewer shows the selected window and reports background-control ready even while the app is inactive; without P6, require foreground eligibility | ☐ |
| Same-session app/window switching | Replace the selected app without reconnecting. Verify old-target input and held state are released, capture follows the new selection, and only the newly authorized target receives input. P6 must not activate the selected app | ☐ |
| P6 capability and pairing trust | Verify both peers negotiate `backgroundControl`; Host acceptance of pairing enables control without a second prompt. Deny pairing and confirm no control is authorized; accept pairing and verify a fresh control generation. Pause preserves video; unpair removes trust and ends the active session, and reconnect requires fresh pairing | ☐ |
| Background input safety | With the selected app inactive, test mouse and keyboard delivery to a disposable app without activating Host or the target. Confirm secure-input, lock/non-console state, PostEvent revocation, stale generation, target replacement, and permission loss each block input and release admitted pressed state safely | ☐ |
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
| Permission recovery | Local Network, Screen Recording, or PostEvent denial/revocation disables the affected path and gives a recoverable instruction; legacy input still requires foreground checks, and P6 background input is blocked when known-safe Accessibility inspection is unavailable | ☐ |
| Window recovery | Close/change/target-safety loss disables input and reports a recoverable state; losing foreground alone blocks legacy input while an authorized P6 target remains safe | ☐ |
| LAN recovery | Disconnect shows reconnecting; reauthorization is required before input resumes | ☐ |
| Queued-input isolation | Held input is released on Settings navigation within the same authorization; window switch, reauthorization, and reconnect never replay queued old input, and a saturated input queue closes the affected session instead of losing a release | ☐ |
| Stale trust | Revocation or identity mismatch requires explicit re-pairing | ☐ |
| Failure UX | Malformed/unsupported/oversized input fails closed without sensitive diagnostics | ☐ |
| Post-test cleanup | After collecting evidence, stop test apps, clear scoped settings/trust/identity and permissions, remove test installations/review output, verify absence, and preserve source/release artifacts | ☐ |

Follow [UI Review and Post-test Cleanup](TESTING_CLEANUP.md) after the run.
Its dated local evidence does not complete the physical acceptance rows above.
For this check, background means the selected window is occluded by another
app, not minimized. ScreenCaptureKit continues to provide the full contents of
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
| Intel Host (`x86_64`) → Apple Silicon Viewer (`arm64`), same LAN | Both architectures build; protocol, input, transport, and package gates pass locally | Physical runtime unverified; operator manual run required |
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
