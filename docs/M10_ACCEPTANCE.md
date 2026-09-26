# M10 V1 Integration Pilot and Acceptance

## Scope

M10 is the final Intel Host to Apple Silicon Viewer acceptance run. It does
not add features beyond the V1 specification. Use a disposable foreground test
application whose content contains no private data.

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
connected and may foreground the explicitly selected regular application.
Input is still accepted only after Host-side foreground and PostEvent
checks pass. The Viewer visibly distinguishes Connecting, Connected, and
Reconnecting, and disables Connect while active. The Host's default Bonjour
name is its short macOS hostname, while the Viewer sends its hostname as
display-only pairing metadata. The Host remains resident when Screen
Recording or Local Network setup is incomplete and exposes a status-menu Retry
action. The production path now uses TLS bootstrap plus Keychain-backed
two-sided pairing: a first connection uses Host and Viewer commitments, then
the Host reveal and Viewer reveal before both endpoints independently derive the
same six-digit code; a fresh pairing shows a Host consent prompt and a Viewer
consent prompt that displays the code for comparison and requires explicit
acceptance. A later connection silently exchanges the same challenge when both
trust records match and reuses them without prompting. If
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

## Prerequisites

1. Build the release candidates on the current checkout:

   ```bash
   export MACREMOTEAPP_SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
   bash scripts/release-notarized.sh
   ```

   This first runs the canonical `scripts/validate.sh` repository validation.
   Only after deterministic CI passes does it
   build, submit, staple, and validate notarized `MacRemoteApp-Host.dmg` and
   `MacRemoteApp-Viewer.dmg`, together with the stapled app bundles. The
   default output is the repository-local `build/release/` directory, outside
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
   cache. The script uses the local `notarytool-profile` Keychain profile by
   default. Do not place the profile, its credentials, or the signing identity
   configuration in the repository.
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
     "$PWD/build/release"
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
   requested as an optional AX/secure-input enhancement. Until PostEvent is
   authorized, the Host remains view-only and does not authorize mouse/keyboard
   capabilities.
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

## Acceptance sequence

| Step | Acceptance evidence | State |
| --- | --- | --- |
| Fresh install | Host/Viewer app bundles launch and signatures verify | ☐ |
| Startup permissions | Host Local Network and Screen Recording, plus Viewer Local Network, are granted to the signed app bundles | ☐ |
| User documentation | Each DMG contains the User Guide, debugging guide, and debug-log collection guide | ☐ |
| Pairing | Host and Viewer complete commit/reveal, display the same independently derived six-digit code, operators compare it, Host allows and Viewer explicitly accepts, and trust records are stored | ☐ |
| Pairing recovery | Host and Viewer can explicitly forget their own role's saved peer pairings; the next connection requires a new code and local identity records remain intact | ☐ |
| Full uninstall reset | The DMG helper clears both roles' per-user app-state paths and invokes each installed role's signed binary to clear its own trust and generated identity; it does not touch unrelated Keychain records or macOS TCC grants | ☐ |
| Host display name | Host `Rename Host…` changes the Bonjour discovery name and the listener restarts without changing the TLS identity | ☐ |
| Default/display device names | Host defaults to its macOS short hostname; Viewer pairing UI and trust metadata use the Viewer hostname; names never affect authentication | ☐ |
| Window selection | Exactly one eligible foreground window is selected | ☐ |
| Same-session app switching | Start streaming one app, select another eligible app without reconnecting, then verify the new app is foreground on Host and receives mouse/keyboard only while focus and PostEvent checks pass | ☐ |
| Viewer connection state | Connect changes to disabled `Connected`; disconnect shows `Reconnecting…` during retry and re-enables Connect only when disconnected | ☐ |
| Native app menus | Both roles expose About with version/build, Settings, Minimize, Hide, and Quit; Host status menu also opens About/Settings | ☐ |
| Release identity | About, Settings, Viewer title/status, and Host status menu match both installed plists; `major.minor.build` means separate short version and build, not wire protocol version | ☐ |
| Viewer settings navigation | Settings uses the same main window; Back, Command-0, and Command-W return to remote view; switching during a connected session releases held input and preserves the session | ☐ |
| Host settings lifecycle | Runtime and permission status refresh; closing settings keeps Host running, and the app returns to menu-bar operation after its windows close | ☐ |
| Capture/display | Viewer renders the selected window with aspect preservation | ☐ |
| Performance | 30-second report has clock probes, valid samples, p50/p95, fps and resource data | ☐ |
| Input | Each authorized input capability works only while authorized; mouse-only or keyboard-only authorization keeps the other local controls disabled | ☐ |
| Clipboard | Text-only opt-in works; opt-out and echo prevention work | ☐ |
| Permission recovery | Local Network, Screen Recording, or PostEvent denial/revocation disables the affected path and gives a recoverable instruction; optional Accessibility loss only disables its AX enhancement | ☐ |
| Window recovery | Close/change/focus loss disables input and reports a recoverable state | ☐ |
| LAN recovery | Disconnect shows reconnecting; reauthorization is required before input resumes | ☐ |
| Stale trust | Revocation or identity mismatch requires explicit re-pairing | ☐ |
| Failure UX | Malformed/unsupported/oversized input fails closed without sensitive diagnostics | ☐ |
| Post-test cleanup | After collecting evidence, stop test apps, clear scoped settings/trust/identity and permissions, remove test installations/review output, verify absence, and preserve source/release artifacts | ☐ |

Follow [UI Review and Post-test Cleanup](TESTING_CLEANUP.md) after the run.
Its dated local evidence does not complete the physical acceptance rows above.

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

The explicit M7 text-clipboard opt-in path is available from the same debug
build when the clipboard row is being exercised. It enables only the bounded
`.string` pasteboard flow after authorization and prints a redacted UX state;
it never logs clipboard contents. The command remains connected for the
operator's copy/conflict/opt-out walkthrough; press Return to stop or type
`disable`/`off` to revoke clipboard consent before stopping:

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

Archive only sanitized logs and the JSON performance report. Do not archive
screen captures, clipboard content, raw input values, private keys, or full
window titles. Record the exact Mac model, architecture, macOS build, app
signature identity, permission state, network conditions, selected test app,
and every unchecked item above. An unchecked physical item is an explicit V1
exception; it is not reported as verified.
