# UI Review and Post-test Cleanup

## Completion rule

Finish a local UI review or installation test by stopping the test apps and
cleaning the test installation, preferences, pairing records, generated local
identities, and app-specific macOS permissions. Cleanup and verification are
part of the test handoff. Do not leave a review app running after the work is
complete unless the user explicitly asks to keep that test state.

Keep source changes, Git state, unrelated checkouts, and existing `build/beta`,
`build/rc`, and `build/release` artifacts. Prefer moving disposable app bundles
and review output to the Trash so the files remain recoverable.

## UI requirements

- Viewer Settings replaces the remote view in the same main window. Do not
  create a second Viewer Settings window. `Back to Remote View`, `Command-0`,
  and `Command-W` on the settings page return to the remote view.
- Page switching must preserve the session and release held remote input.
  Verify active-session behavior on two Macs; an unconnected UI walkthrough
  does not prove it.
- Both roles provide About, Settings (`Command-,`), Minimize (`Command-M`),
  Hide (`Command-H`), and Quit (`Command-Q`). About is a separate information
  window and shows the release and build.
- Host remains a menu-bar app. Its status menu also opens About and Settings.
  While these windows are open, the standard application menu and temporary
  Dock icon are available. Closing Host Settings does not stop the Host.
- Use `major.minor.build`: release `0.2.1003` means Version `0.2`, Build `1003`.
  Store these separately in `CFBundleShortVersionString` and `CFBundleVersion`.
- Report actual connection/input state. Disconnected input is `Not connected`.
  Bonjour readiness is not a macOS Local Network permission preflight result.

The user-facing commands and settings are described in
[the User Guide](USER_GUIDE.md#app-menus-and-settings). Their required behavior
is defined in [the product specification](PRODUCT_SPEC.md#settings-and-standard-macos-controls),
with ownership and lifecycle in [the architecture](ARCHITECTURE.md#native-app-shell-and-release-identity)
and physical checks in [M10 acceptance](M10_ACCEPTANCE.md).

## Scoped cleanup sequence

1. Inventory the exact running executable paths, installed bundles, review
   output directory, and app-owned data. Check both `/Applications` and the
   current user's `~/Applications`; a bundle launched directly from a build
   directory is not an installed copy. Verify bundle identifiers and reject
   unexpected symlinks before changing files. App settings, identities, and
   approvals are shared by copies using the same role identifiers. If a
   production copy must retain its state, resolve that scope before clearing
   any shared data or permissions.
2. Quit both test roles and verify that their processes have exited. Avoid
   reopening a bundle merely to inspect whether it quit. If graceful shutdown
   fails, verify the exact test executable and PID before stopping that process.
   Do not stop a different checkout or a production session by process name.
3. Before moving the bundles, invoke each verified role's existing
   `--remove-all-data` command. This clears that role's current peer-trust
   namespace, generated local identity, and preference domain. It does not
   export credentials or delete unrelated/imported identities.

   Replace the example paths below with the verified absolute bundle paths:

   ```sh
   review_host_app='/absolute/path/to/MacRemoteApp-Host.app'
   review_viewer_app='/absolute/path/to/MacRemoteApp-Viewer.app'
   "$review_host_app/Contents/MacOS/MacRemoteApp-Host" --remove-all-data
   "$review_viewer_app/Contents/MacOS/MacRemoteApp-Viewer" --remove-all-data
   ```

   This explicit cleanup mode is the exception to the normal instruction to
   launch the `.app` bundle. Do not run the executable directly when testing
   startup permissions. If cleanup fails, retain the bundle and report the
   failed role instead of claiming that its Keychain state is gone.
4. For an authorized fresh-state test reset, reset approvals for only the two
   exact bundle identifiers:

   ```sh
   tccutil reset All com.rudinyu.MacRemoteApp.Host
   tccutil reset All com.rudinyu.MacRemoteApp.Viewer
   ```

   Record command success or failure; do not edit the TCC database or weaken
   Keychain permissions.
5. Remove remaining exact role-owned preferences, caches, and saved window
   state, if present. Relevant paths under the current user's Library include
   `Preferences/<bundle-id>.plist`, `Caches/<bundle-id>`, and
   `Saved Application State/<bundle-id>.savedState`. The full list used by the
   production uninstaller is in
   [`scripts/dmg-uninstall.sh`](../scripts/dmg-uninstall.sh). Never remove the
   user's whole Library, Applications directory, or an unresolved path.
6. Move the verified test installations and the dedicated review output to
   the Trash. For this review, the disposable output was `.build/ui-review/`,
   including its apps, DMGs, and build cache. Do not delete all of `.build/`
   just to remove one UI review. Preserve other release artifacts and source.
7. Verify no scoped test process remains, installation paths and preference
   domains are absent, and the role-specific trust/identity records are gone.
   Keychain verification should report presence/absence or status codes only;
   never print secret values. Check Git status to confirm source changes remain.

| Role | Bundle identifier / preference domain | Peer-trust service | Generated identity label |
| --- | --- | --- | --- |
| Host | `com.rudinyu.MacRemoteApp.Host` | `com.rudinyu.MacRemoteApp.Host.trust` | `MacRemoteApp.host` |
| Viewer | `com.rudinyu.MacRemoteApp.Viewer` | `com.rudinyu.MacRemoteApp.Viewer.trust` | `MacRemoteApp.viewer` |

## Existing uninstall workflows

For an end user's current-user cleanup including bundle-scoped TCC decisions,
use the standalone [`Uninstall-MacRemoteApp.command`](../scripts/Uninstall-MacRemoteApp.command).
See [the user guide](USER_GUIDE.md#clean-uninstall-including-permissions) for
confirmation, recoverability, Keychain limitations, and the separate manual
Local Network revocation. Creating or testing this helper does not authorize
running it against a live installation; use isolated fixtures instead. It
does not clean repository build outputs or replace the test-state audit above.

The older role-specific DMG uninstaller verifies Developer ID/Gatekeeper acceptance,
clears role-owned data through the signed apps, and moves the selected installed
app to the Trash. It rejects ad-hoc review bundles and does not reset TCC.

The repository's `scripts/uninstall-device-apps.sh --clean-testing` is a
broader, destructive development reset: it removes `build/testing/` and the
whole repository `.build/`, invokes the legacy Keychain cleanup helper, and
resets selected TCC services. Do not run it concurrently with validation or
other builds because it removes the entire `.build/` tree, including active
validation caches and locks. Use its `--dry-run` before an explicitly intended
broad reset. It does not invoke the current per-role `--remove-all-data` commands
and is not a substitute for the scoped cleanup and verification above. Imported
M2 identities require the separate, explicitly selected `--identities` workflow.

Restoring app files from the Trash does not restore removed Keychain identities
or TCC approvals. The next launch needs fresh permission consent and pairing.

## Local evidence: 2026-09-26, 0.2.1003

- `bash scripts/validate.sh` passed, including Host arm64/x86_64 and Viewer
  arm64 builds, package tests, deterministic benchmark, and release audit.
- Viewer Settings and `Back to Remote View` were exercised in the same window.
  Host Settings displayed runtime and read-only permission information.
- The local review artifacts used ad-hoc signatures; they were not notarized.
  Two-Mac streaming/input and connected page-switching acceptance were not
  repeated. Opt-in physical/system checks remained skipped.
- Cleanup stopped the review processes. No Host/Viewer installation existed
  in either Applications directory. Both preference domains and current
  role-specific Keychain trust/identity metadata were confirmed absent, and
  both app-specific `tccutil reset All` commands succeeded.
- Approximately 527 MB of review apps, DMGs, build cache, and the remaining
  preference file were moved to the Trash. Source edits were retained; this
  cleanup did not commit or push them.

Record future runs separately. This dated evidence is not a claim about another
Mac, a later build, or a future installation.
