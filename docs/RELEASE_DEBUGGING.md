# MacRemoteApp How to Debug

Use this guide for a local diagnosis. Start with the smallest check that can
explain the symptom, and do not weaken macOS permission or pairing checks.

## Decide whether the issue is installation or runtime

For an installed notarized app, verify the bundle and signature first:

```sh
app="$HOME/Applications/MacRemoteApp-Host.app"
codesign --verify --deep --strict "$app"
spctl --assess --type exec --verbose=4 "$app"
```

`codesign --verify` prints nothing when it succeeds; the `accepted` or
`rejected` line in this pair comes from `spctl`. Use `MacRemoteApp-Viewer.app`
on the Viewer. A valid release app should be reported as accepted by
Gatekeeper and should have a Developer ID signature. If `spctl` reports
`rejected`, the installed bundle is normally an old ad-hoc/testing build or
an app that was changed after signing. Reinstall from the latest notarized DMG
using the DMG's per-user `Applications` drop target, or use its role-specific
Install command and confirm the interactive replacement prompt. The DMG helper
rejects an ad-hoc or non-Gatekeeper-approved bundle before it can replace the
installed app. Stapled-ticket validation is performed by the release validation
script, not by the target Mac installer.

If the app does not launch, retry the role-specific Install command from the
notarized DMG with the old app removed only through the uninstall command.
Do not replace an app with an unsigned or modified bundle during a production
test.

## Check permissions and network

The production Host requests Screen Recording through the signed app bundle,
then performs a short Bonjour readiness probe so macOS can request Local
Network access before Keychain identity enrollment. This keeps a Keychain
problem from hiding the Host's Local Network permission state. The Host then
enrolls/reuses its local TLS identity and starts the authenticated listener.
PostEvent input access is requested only after a Viewer negotiates input and
the operator selects a window. Accessibility is optional for ordinary
foreground input, including P6; P6 uses known-safe process inspection only to
classify an inactive target for safe cleanup.
The Viewer enrolls/reuses
its local identity before its Bonjour browser starts.
Launch the bundles themselves:

```sh
open "$HOME/Applications/MacRemoteApp-Host.app"
open "$HOME/Applications/MacRemoteApp-Viewer.app"
```

Do not launch `Contents/MacOS/MacRemoteApp-Host` or `Contents/MacOS/MacRemoteApp-Viewer`
when testing app permissions; that associates TCC decisions with a different
process context on some macOS versions.

On the Host, verify:

- Screen Recording is enabled for `MacRemoteApp-Host`.
- PostEvent access is enabled for `MacRemoteApp-Host` when input is tested;
  Accessibility is optional for ordinary foreground input, including P6, and
  is used for P6 inactive-target cleanup safety checks.
- Local Network access is allowed.

On the Viewer, verify Local Network access. Confirm both Macs are on the same
trusted LAN and that the Host is running before the Viewer starts discovery.
If a permission was just changed, quit and relaunch the affected app.
If a previous denial must be tested again, follow
[UI Review and Post-test Cleanup](TESTING_CLEANUP.md) for an app-specific
permission reset. Its scoped reset covers all approvals for the exact Host and
Viewer bundle identifiers, including PostEvent; do not assume the broader
legacy `--clean-testing` helper clears every current role-specific setting.

If the Host icon is still pinned in the Dock, quit it before choosing Options >
Remove from Dock. The new Host bundle is an accessory app and does not
intentionally require a persistent Dock icon.

## Check pairing

- Use the normal production flow without `MACREMOTEAPP_PEER_CERT`.
- A normal production install does not require `host.p12`, `viewer.p12`, or
  manual Keychain import. If identity setup fails, inspect the app's Keychain
  access and relaunch; do not substitute a Developer ID signing certificate.
- Open the Host status-menu item and confirm that `Pairing code: 000000`
  (a six-digit value) is visible; compare it with the value displayed in the
  Viewer prompt. A Host with an existing trust
  record may skip the Allow/Deny dialog, but it must still expose the code in
  the status menu while the Viewer decides. Select Allow on the Host and Accept
  on the Viewer only after verifying that the values match.
- If one side has stale trust or the peer identity changed, use `Forget saved
  pairings…` on the Host status menu and on the Viewer, then select the Host
  again and complete a fresh explicit pairing flow. This removes only peer
  trust records; it does not delete the local TLS identity or permissions. Do
  not delete unrelated Keychain records.
- If a complete reset is required, double-click the role-specific
  `Uninstall-MacRemoteApp-*.command` in the notarized DMG. It moves the selected
  installed app to the Trash, clears each installed role's own trust/generated
  identity through its signed app, and clears both roles' exact app-data paths.
  It intentionally does not reset macOS TCC grants; remove the exact
  entries in System Settings when a fresh privacy decision is required.
  Reinstalling either role after this reset requires fresh pairing.
- To change the discovery name, choose `Rename Host…` from the Host status
  menu. The name is local-network metadata, not a certificate identity; the
  listener briefly restarts after it is saved.

The debug physical smoke uses a different, explicitly provisioned PKCS#12 and
certificate flow. Follow the repository's M2 physical smoke runbook for that
path and never copy a `.p12` file to the other Mac.

## Check window selection and input

- Keep the Host unlocked. The Viewer can show a selected app while it is
  backgrounded, but explicit window selection must bring the selected regular
  app to the foreground before input. P6 adds pairing and process-safety checks;
  it does not support inactive-app input. Confirm the selected PID remains
  frontmost while testing.
- Select one eligible window in the Viewer picker.
- If the window closes, changes identity, loses focus, or the Host permission
  is revoked, select it again after the Host returns to a ready state.
- If pointer or keyboard input is unavailable, check PostEvent permission,
  foreground eligibility, and that the selected window is still the authorized
  generation. Accessibility may be enabled for the optional global
  AX/secure-input signal; target-process inspection is used for P6 inactive-
  target cleanup only.
- Clipboard is text-only and opt-in; confirm it is enabled on both endpoints
  and do not use it as a binary/file-transfer channel.

### Check input-source synchronization

- Click the remote surface before switching Chinese/English. Local Viewer
  settings and other apps do not drive Host source changes.
- A pending source waits for the matching Host acknowledgement before sending
  keyboard events. If it times out, check the existing connection, selected
  Host foreground window, PostEvent permission, console, and secure-input
  state; use `Retry source sync` or return to the remote surface after
  correcting the cause.
- An unavailable Chinese source requires the same enabled input method/mode
  on both Macs. Enable it locally on Host; the app never installs/enables a
  source or substitutes Pinyin for Zhuyin automatically.
- EN on an already-English Host is deliberately a no-op. Source following is
  state synchronization, not forwarding the switch shortcut a second time.
- A peer without the optional `inputSourceSync` capability uses manual Host
  source selection. Third-party IME internal mode changes that are not exposed
  as macOS source changes are not claimed supported.
- For unsupported layouts or input methods, turn off `Follow Viewer input
  source` in Viewer Settings and select the Host source manually.
- Reports may include the sanitized synchronization state and release/build,
  not raw keys, input-source identifiers/names, or arbitrary platform errors.

## Debug-only commands

Release binaries intentionally reject or omit these diagnostics. Run them from
the repository with a debug build only:

```sh
cd "/absolute/path/to/MacRemoteApp" # Replace with your repository path.

# Host window discovery and Screen Recording permission
swift run --configuration debug Host --m3-list-windows

# Authenticated M2 pairing/session smoke (requires the documented test env)
bash scripts/run-m10-acceptance.sh host
bash scripts/run-m10-acceptance.sh viewer
```

The M2 commands require the role's local PKCS#12 path, peer certificate path,
and `MACREMOTEAPP_P12_PASSWORD` in the environment. Never paste that password
or a private-key path into a support ticket.

For the deterministic repository gate, use:

```sh
bash scripts/run-m10-acceptance.sh deterministic
```

This does not prove a two-Mac physical connection. Record that limitation in
the acceptance report.
