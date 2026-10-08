# MacRemoteApp User Guide

MacRemoteApp is a LAN-first remote view and control tool for two Macs:

- The Intel Mac runs `MacRemoteApp-Host`.
- The Apple Silicon Mac runs `MacRemoteApp-Viewer`.

The Viewer controls one eligible foreground application window selected from the
Host. The V1 protocol is intentionally limited to one local-LAN session, mouse,
keyboard, scroll, and bounded opt-in text clipboard synchronization. The
production Viewer exposes the clipboard toggle only after the Host authorizes
the capability for the current paired session.

## Install from a notarized DMG

1. Use the Host DMG on the Intel Mac and the Viewer DMG on the Apple Silicon
   Mac. Testing, beta, and RC files include their version, for example
   `MacRemoteApp-Host-0.2.1009.dmg` and `MacRemoteApp-Viewer-0.2.1009.dmg`.
   Only formal release files use the fixed `MacRemoteApp-Host.dmg` and
   `MacRemoteApp-Viewer.dmg` names; installed app names do not change.
2. Open the DMG. The `Applications` item in this DMG is a per-user drop target:
   drag the role app onto it and it copies the app to `~/Applications`, then
   launch that copy. Alternatively, double-click the role-specific
   `Install-MacRemoteApp-*.command` helper; it performs an interactive,
   signature-checked per-user install in `~/Applications`. The DMG helper has
   no command-line options and is not a CI or testing tool. For safety, the
   drop target refuses a symlink or non-directory at `~/Applications`.
3. Open the installed app bundle. On first Host launch, Screen Recording is
   requested first and a short Bonjour readiness probe requests Local Network
   access for the signed `MacRemoteApp-Host` bundle. Allow both in System
   Settings > Privacy & Security. The Host then creates or reuses its local
   role-specific P-256 TLS identity in that Mac's login Keychain. Host and
   Viewer use separate identity and peer-trust namespaces, even when both are
   installed on the same Mac. The private key never leaves the Mac and no
   `.p12` file is needed. PostEvent input access is intentionally requested
   later, only after a Viewer has paired, negotiated input, and the operator
   selects a window. Accessibility may be requested as an optional
   AX/secure-input enhancement. If PostEvent permission is missing, the Viewer
   remains view-only.
5. On the Viewer, the first launch creates its local identity, shows the Local
   Network setup step, and then starts Bonjour discovery. Allow Local Network
   access for the signed `MacRemoteApp-Viewer` bundle when macOS asks. If
   access is denied or the browser cannot start, the setup is retryable on the
   next launch; the Viewer does not treat a denied permission as completed.

Launch the `.app` bundle itself from Finder or with `open`; do not launch the
executable inside `Contents/MacOS` when testing app permissions. macOS records
these decisions against the signed app bundle identity, not against an
unrelated Terminal process.

The DMG helper rejects ad-hoc or non-Gatekeeper-approved bundles. If an older
per-user app is already installed, run the helper again and confirm its
interactive replacement prompt. The install and uninstall helpers use only
macOS signing and Gatekeeper checks on the target Mac; notarization/stapling
checks run during release validation. The uninstall helper also refuses an
ad-hoc, modified, or differently published same-identity bundle, so use Finder
or the repository's development cleanup workflow for disposable testing
artifacts. The repository's separate development installer has testing-only
options, but those options are intentionally not present in the DMG.

Use the notarized DMG for the physical test. Do not copy a private key, a
PKCS#12 file, a pairing secret, or the repository to the other Mac.

The repository's `scripts/create-m2-identities.sh` and PKCS#12 flow are for
disposable debug physical smoke only. They are not required for a production
installation. `MACREMOTEAPP_LOCAL_IDENTITY_LABEL` and
`MACREMOTEAPP_LOCAL_IDENTITY_P12` are controlled diagnostic overrides, not
normal user setup. When set, the identity-label value is a base; the app adds
`.host` or `.viewer` so both roles remain isolated.

When upgrading from an older build that used one shared Keychain namespace,
the new version does not import the old shared peer-trust records. Complete a
fresh pairing once. The old Keychain items are left untouched by the upgrade.

## First connection and pairing

1. Put both Macs on the same trusted LAN.
2. Start the Host first, then start the Viewer.
3. After discovery, both apps commit fresh random values before either side
   reveals them, then complete the commit/reveal exchange and independently
   derive the same six-digit one-time pairing code. The Host
   displays it in the pairing dialog and status-menu item. If the Host already
   trusts this Viewer but the Viewer trust record was lost, the Host may not
   show an Allow/Deny dialog; its status menu still shows the code.
4. Compare the same six-digit code on both Macs. If the Host asks, select
   **Allow**; select **Accept** on the Viewer only when the codes match.
   Otherwise select **Deny** on either Mac.
5. Each endpoint saves the peer trust record in its role-specific macOS
   Keychain service only after both operators consent. A permission grant
   alone never creates a pairing.

The Host status menu provides `Rename Host…` for changing the name shown in
Viewer discovery. The name is visible to devices on the local network and is
not the Host's TLS identity; changing it does not by itself remove pairing.
The listener briefly restarts under the new name.

If a previous pairing is stale or only one endpoint still has its trust record,
use `Forget saved pairings…` on the Host status menu and on the Viewer before
trying again. The action stops the active session, clears the current Viewer
Host selection, and removes that app role's saved peer trust records. On a P6
Host it also removes saved Viewer control grants. It
does not delete the local TLS identity, permissions, or Host name. The Host
continues to be discoverable, but it must be explicitly selected again before
the next connection can show and confirm a new pairing code.

New production installations do not need `MACREMOTEAPP_PEER_CERT`. That
variable is reserved for the pinned-certificate migration and debug smoke
paths.

## Select and control a window

1. Use the Viewer window picker to select exactly one eligible Host window.
2. Keep the Host unlocked. Legacy peers require the selected application to
   remain foreground. With the P6 control grant below, a safe selected process
   can receive input without being brought to the front.
3. Use the Viewer surface for pointer movement, button events, scrolling,
   keyboard input, and supported modifiers.
   If the session authorizes only mouse or only keyboard input, the Viewer
   keeps the other local controls disabled and continues to expose the
   authorized capability.

Very small macOS helper/service surfaces are intentionally omitted from the
window picker. If an application's main window is not listed, bring that
window on screen on the Host and refresh the session.
4. When the Host authorizes text clipboard, use the Viewer’s `Enable text
   clipboard` button to opt in for the current session. The button becomes
   unavailable when the Host has not granted the capability or the session
   ends. The protocol path is text-only, bounded, and opt-in; clipboard text
   is not written to diagnostics.

Screen Recording or PostEvent revocation, unsafe target state, window replacement,
disconnect, or failed reauthorization stops the affected operation. Optional
Accessibility loss only removes the AX/secure-input enhancement. Recheck the
Host permission and select the window again before reconnecting.
For P6 background control, unavailable secure-input inspection also blocks
control; enable Host Accessibility and recheck the safe target state.

### Host-controlled process input (P6)

The current source adds P6; the retained `0.2.1009` RC does not include it.
Both endpoints must support the new capability. After pairing, the Host asks
locally before granting mouse and keyboard control to this Viewer. Denying
the request keeps the session view-only. Approval is saved for the Viewer's
authenticated identity and can be reused on reconnect; a display-name change
does not grant a new device control.

The Host menu shows control state and offers allow, pause/resume, and revoke.
Pause stops control for the current session while video continues. Revoke
removes the saved grant; the Viewer needs another local approval to control
again. A Keychain error blocks control and is shown as a failure. If revocation
cannot be saved, retry before relying on it across a Host restart.

P6 sends events to the selected window's owning process without activating it.
An app with several windows may route events to another window in that process;
exact-window delivery is not guaranteed. Keep a disposable test app available
until physical behavior has been verified. The Host must remain unlocked with
the required input permission and a live safe selected target. Secure-input
and unsafe-target checks still block input. Viewer Settings and unfocused
Viewer windows do not send remote input.

Background control does not automatically change the Host's global input
source. Match the intended source manually on the Host. Chinese composition
and candidate panels remain Host-side; verify their behavior with the actual
target app. Input-source following can resume when the selected target is
foreground, under the existing acknowledgement rules below.

### Chinese/English input-source following

When both updated peers authorize input-source synchronization, click inside
the Viewer remote surface and use the Viewer's normal Chinese/English switch.
The Host follows the selected state, not another toggle: if Viewer becomes EN
and Host is already EN, Host stays EN. Keyboard delivery waits for the matching
Host acknowledgement. Composition and candidate selection still occur on the
Host. Visibility of a separate IME candidate panel needs checking with the
target app; the stream captures the selected window, not the entire desktop.

For Chinese, add and enable the same input method/mode on **both Macs** in
System Settings > Keyboard > Text Input. Pinyin and Zhuyin are not interchangeable.
If the Host lacks the matching enabled source, keyboard input pauses with an
input-source status; mouse control can remain available. Enable the matching
source locally on Host, then use `Retry source sync` in the Viewer or return
to the remote surface to retry. Do not use
clipboard sharing as a workaround for source synchronization.

Switching windows/apps, reconnecting, reauthorization, and returning from
Settings require a fresh acknowledgement. Source changes while using local
Viewer settings or another app do not control Host in the background. Older
peers continue to require manual Host input-source selection. Third-party IME
internal English/Chinese modes that are not exposed as separate macOS sources
are not guaranteed to follow.

Viewer Settings includes `Follow Viewer input source`, enabled by default.
Turn following off to choose the Host source manually for an unsupported
layout or input method. Returning to the remote view starts a fresh sync;
use that view's `Retry source sync` button after a failure. The Settings-page
retry action is inactive while the remote surface is unfocused. Turning
following off does not restore or change the Host's source in the background.

## App menus and settings

Both apps provide native macOS menus. `About MacRemoteApp Host/Viewer` shows
the full release number and build. `Settings…` (`Command-,`) opens settings,
`Window > Minimize` (`Command-M`) minimizes the current window,
and `Quit MacRemoteApp Host/Viewer` (`Command-Q`) ends the session and quits.
`Hide` (`Command-H`), `Hide Others`, `Show All`, and `Window > Show MacRemoteApp
Host/Viewer` (`Command-0`) provide the standard window controls.

Viewer Settings replaces the remote view within the same window. Use
`Back to Remote View`, `Command-0`, or close the settings page with `Command-W`
to return; switching pages keeps the session connected and releases any held
remote input. Closing the remote-view window itself quits the Viewer.
The settings page shows live connection, Host, discovery, round-trip time, input,
and clipboard status. The text clipboard checkbox uses the same session-only
opt-in as the main window. Settings also links to Local Network privacy controls
and the confirmed pairing-reset action. Local app shortcuts such as `Command-,`,
`Command-M`, and `Command-Q` operate the Viewer even when the remote surface is
focused.

The resident Host's top-right status menu also has `About` and `Settings…`.
Opening either shows its standard application menu and a temporary Dock icon;
closing those windows returns it to menu-bar operation. Host Settings shows the
current Host name, runtime state, and read-only Screen Recording, PostEvent, and
Accessibility permission checks. It provides Rename Host, Privacy & Security,
Retry setup when required, and Forget saved pairings. Permission checks refresh
when the Host becomes active again. Closing Host Settings does not stop the Host.
Bonjour activity is reported separately from the macOS-managed Local Network
permission; it is not a permission preflight result.

## Stop or uninstall

Quit both apps to end the session. For an app installed by dragging to
`/Applications`, use Finder's normal Move to Trash action. For an app installed
by the optional DMG helper, open the DMG and double-click the role-specific
`Uninstall-MacRemoteApp-*.command` file. It asks that role to quit first, then
moves only the exact per-user app from `~/Applications` to `~/.Trash`. It
clears both roles' per-user preferences, caches, and saved application state.
Each signed app removes only its own role-specific peer trust and generated
TLS identity; if the opposite role is installed, the helper asks that app's
signed binary to clear its own Keychain data too. It does not remove unrelated
Keychain records. It intentionally does not reset macOS TCC entries; use
System Settings to remove the exact permission when a fresh privacy decision
is required.
If the app is still running after the quit request, the script stops and asks
you to quit it before retrying. Moving the app to the Trash keeps the normal
macOS recovery path; empty the Trash separately if permanent deletion is
intended.

Host and Viewer now have separate Keychain namespaces. If both roles are
installed on the same Mac, either DMG uninstaller clears both roles' current
Keychain data but moves only the selected role's app to the Trash; the other
app stays installed and enrolls a fresh identity on next launch. If only one
role is installed, its uninstaller clears that role's Keychain data. Legacy
shared Keychain entries from older builds are not imported by the new version
and are preserved rather than deleted across app-role boundaries. Use the
in-app `Forget saved pairings…` action when you want to remove only the
selected role's peer trust while preserving its app and local identity.

The Host is an accessory app and should not need a persistent Dock icon. If an
older icon remains pinned, quit the old app first, then choose Options > Remove
from Dock or drag the icon out of the Dock.

Local development and UI reviews must finish with scoped cleanup of the test
apps, settings, pairing/identity records, and app-specific macOS permissions.
Follow [UI Review and Post-test Cleanup](TESTING_CLEANUP.md) for the order,
verification, and distinction from the broader repository `--clean-testing`
reset. This development cleanup also applies when the app was launched directly
from a review directory without being installed. Removed identities and
permissions require fresh pairing and consent on the next launch.

Before collecting a support bundle,
see the accompanying `MacRemoteApp-How-to-Collect-Debug-Logs.txt` in the DMG
or `docs/DEBUG_LOG_COLLECTION.md` in the repository.

## Clean uninstall including permissions

Both Host and Viewer DMGs starting with build `1009` include
`Uninstall-MacRemoteApp.command` beside the app. Use that full-cleanup helper,
or download the standalone
[`Uninstall-MacRemoteApp.command`](../scripts/Uninstall-MacRemoteApp.command)
when removing both roles and resetting their privacy decisions, rather than
the older role-specific DMG uninstaller described above. Save the file, then
run it with Bash in Terminal; an executable copy can also be double-clicked.
Run it as your normal logged-in user, not with `sudo`.
Quit Host and Viewer first; the helper refuses cleanup while either role is
running and does not force-quit applications. Use `--dry-run` to preview.
To authorize the actual cleanup, type `UNINSTALL` at its confirmation prompt.

The helper asks for confirmation before changing anything. Settings, saved
pairings, and generated role identities are not recoverable through the Trash.
App bundles moved to the Trash remain recoverable, but reinstalling afterward
requires fresh pairing and privacy consent. Copies with the same bundle IDs
share the current user's settings and permission decisions.

The helper checks the original Host/Viewer app names in `~/Applications` and
`/Applications`. Renamed copies or apps in other locations must be removed
manually. A system-wide copy that your user cannot move is retained with a
message to finish removal in Finder; the helper does not elevate privileges.

Only verified MacRemoteApp bundles and exact app-owned state locations are
eligible for cleanup. Signing keys, notarization credentials, unrelated apps,
other users' settings, repository sources, and build/release outputs are not
cleanup targets. Legacy shared Keychain records and imported diagnostic
identities are outside this script's role-owned cleanup contract.

If the installed signed cleanup executable is missing, its Keychain cleanup
cannot be verified; the script reports the gap rather than promising that all
records are gone. Keep a verified installed copy available until cleanup
finishes. Permission-reset or file-removal failures are also reported.
The signed cleanup command requires build `1003` or newer. Older copies are
not executed as cleanup helpers and are retained with an incomplete result.

The script resets TCC decisions only for `com.rudinyu.MacRemoteApp.Host` and
`com.rudinyu.MacRemoteApp.Viewer`. It never resets permissions for every app.
**Local Network is not covered by TCC reset.** In System Settings > Privacy &
Security > Local Network, turn off remaining MacRemoteApp Host/Viewer entries.
Apple provides no supported macOS command to return that permission to its
undetermined state; historical entries may remain after uninstall. The helper
does not edit the system database or disable security protections. See
[Apple's Local Network privacy note](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

The older role-specific `Uninstall-MacRemoteApp-Host.command` and
`Uninstall-MacRemoteApp-Viewer.command` remain available for removing only the
selected role's per-user app without resetting permissions. Choose the exact
`Uninstall-MacRemoteApp.command` filename for both-role cleanup including TCC.
Older `0.2.1008` DMGs do not contain this full-cleanup helper.

## Product boundaries

V1 does not provide Internet relay, WebRTC, audio, file transfer, simultaneous
multi-window control, background control, or locked-screen control.
The separately authorized P6 source extension provides consented
process-targeted background input with the limits above. It adds none of the
other capabilities and does not imply physical two-Mac acceptance.
