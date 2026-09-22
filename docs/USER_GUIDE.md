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

1. Use `MacRemoteApp-Host.dmg` on the Intel Mac and
   `MacRemoteApp-Viewer.dmg` on the Apple Silicon Mac.
2. Open the DMG and double-click the role-specific
   `Install-MacRemoteApp-*.command` file.
3. Open the installed app bundle from `~/Applications`. On first launch, the
   app creates or reuses a local P-256 TLS identity in that Mac's login
   Keychain. The private key never leaves the Mac and no `.p12` file is needed.
4. On the Host, the first launch requests Screen Recording before it starts
   Bonjour. Accessibility/post-event input access is requested from the signed
   Host bundle only after a Viewer has negotiated input and the operator selects
   a window. Allow the requested access for `MacRemoteApp-Host` in System
   Settings > Privacy & Security. If input permission is missing, the Viewer
   remains view-only.
5. On the Viewer, the first Bonjour discovery requests Local Network access;
   allow it when macOS asks.

Launch the `.app` bundle itself from Finder or with `open`; do not launch the
executable inside `Contents/MacOS` when testing app permissions. macOS records
these decisions against the signed app bundle identity, not against an
unrelated Terminal process.

The installer rejects ad-hoc or non-Gatekeeper-approved bundles by default.
It uses only macOS signing and Gatekeeper checks on the target Mac; the
notarization/stapling checks run during release validation. If an older app was
already installed, run the installer again with `--replace` from the latest
notarized DMG, then verify it with `codesign --verify --deep --strict` and
`spctl --assess --type exec --verbose=4`. The `--allow-ad-hoc` option is for
disposable local testing only and is not suitable for permission or Gatekeeper
validation.

Use the notarized DMG for the physical test. Do not copy a private key, a
PKCS#12 file, a pairing secret, or the repository to the other Mac.

The repository's `scripts/create-m2-identities.sh` and PKCS#12 flow are for
disposable debug physical smoke only. They are not required for a production
installation. `MACREMOTEAPP_LOCAL_IDENTITY_LABEL` and
`MACREMOTEAPP_LOCAL_IDENTITY_P12` are controlled diagnostic overrides, not
normal user setup.

## First connection and pairing

1. Put both Macs on the same trusted LAN.
2. Start the Host first, then start the Viewer.
3. The Host displays a one-time pairing code and asks for local consent.
4. Enter the matching code on the Viewer and approve the connection there.
5. Both endpoints save the peer trust record in the macOS Keychain after both
   operators consent.

New production installations do not need `MACREMOTEAPP_PEER_CERT`. That
variable is reserved for the pinned-certificate migration and debug smoke
paths.

## Select and control a window

1. Use the Viewer window picker to select exactly one eligible Host window.
2. Keep the selected application foreground and unlocked on the Host.
3. Use the Viewer surface for pointer movement, button events, scrolling,
   keyboard input, and supported modifiers.
   If the session authorizes only mouse or only keyboard input, the Viewer
   keeps the other local controls disabled and continues to expose the
   authorized capability.
4. When the Host authorizes text clipboard, use the Viewer’s `Enable text
   clipboard` button to opt in for the current session. The button becomes
   unavailable when the Host has not granted the capability or the session
   ends. The protocol path is text-only, bounded, and opt-in; clipboard text
   is not written to diagnostics.

Screen Recording or Accessibility revocation, focus loss, window replacement,
disconnect, or failed reauthorization stops the affected operation. Recheck
the Host permission and select the window again before reconnecting.

## Stop or uninstall

Quit both apps to end the session. To remove only the installed app, open the
DMG and run the role-specific `Uninstall-MacRemoteApp-*.command` file. It
removes the exact app bundle from `~/Applications`; it does not remove other
applications or Keychain records by default.

The Host is an accessory app and should not need a persistent Dock icon. If an
older icon remains pinned, quit the old app first, then choose Options > Remove
from Dock or drag the icon out of the Dock.

For disposable repository testing state, run the repository copy instead of
the DMG copy from a repository checkout:

```sh
./scripts/uninstall-device-apps.sh \
  --clean-testing \
  --identities "$HOME/MacRemoteApp-identities" \
  --yes
```

Use `--dry-run` first. `--clean-testing` preserves the `build/beta`,
`build/rc`, and `build/release` channels. Before collecting a support bundle,
see the accompanying `MacRemoteApp-How-to-Collect-Debug-Logs.txt` in the DMG
or `docs/DEBUG_LOG_COLLECTION.md` in the repository.

## Product boundaries

V1 does not provide Internet relay, WebRTC, audio, file transfer, simultaneous
multi-window control, background control, or locked-screen control.
