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

The production Host enrolls/reuses its local Keychain TLS identity, requests
Screen Recording through the signed app bundle before waiting for Bonjour
readiness, and then starts its listener so macOS can request Local Network
access. Accessibility/post-event input access is requested only after a Viewer
negotiates input and the operator selects a window. The Viewer enrolls/reuses
its local identity before its Bonjour browser starts. Local Network access is
therefore requested only after local identity setup succeeds.
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
- Accessibility is enabled for `MacRemoteApp-Host` when input is tested.
- Local Network access is allowed.

On the Viewer, verify Local Network access. Confirm both Macs are on the same
trusted LAN and that the Host is running before the Viewer starts discovery.
If a permission was just changed, quit and relaunch the affected app.
If a previous denial must be tested again, run the uninstall command with
`--clean-testing`; it resets the MacRemoteApp Host Screen Recording and
Accessibility entries plus the Host and Viewer Local Network TCC entries before
the next launch.

If the Host icon is still pinned in the Dock, quit it before choosing Options >
Remove from Dock. The new Host bundle is an accessory app and does not
intentionally require a persistent Dock icon.

## Check pairing

- Use the normal production flow without `MACREMOTEAPP_PEER_CERT`.
- A normal production install does not require `host.p12`, `viewer.p12`, or
  manual Keychain import. If identity setup fails, inspect the app's Keychain
  access and relaunch; do not substitute a Developer ID signing certificate.
- Confirm the code shown by the Host is entered on the Viewer.
- Approve the connection on both Macs.
- If one side has stale trust or the peer identity changed, stop both apps and
  complete a fresh explicit pairing flow. Do not delete unrelated Keychain
  records.

The debug physical smoke uses a different, explicitly provisioned PKCS#12 and
certificate flow. Follow the repository's M2 physical smoke runbook for that
path and never copy a `.p12` file to the other Mac.

## Check window selection and input

- Keep the target app visible, foreground, and unlocked on the Host.
- Select one eligible window in the Viewer picker.
- If the window closes, changes identity, loses focus, or the Host permission
  is revoked, select it again after the Host returns to a ready state.
- If pointer or keyboard input is unavailable, check Accessibility and ensure
  the selected window is still the authorized generation.
- Clipboard is text-only and opt-in; confirm it is enabled on both endpoints
  and do not use it as a binary/file-transfer channel.

## Debug-only commands

Release binaries intentionally reject or omit these diagnostics. Run them from
the repository with a debug build only:

```sh
cd <repository-root>

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
