# M10 V1 Integration Pilot and Acceptance

## Scope

M10 is the final Intel Host to Apple Silicon Viewer acceptance run. It does
not add features beyond the V1 specification. Use a disposable foreground test
application whose content contains no private data.

The repository now contains a production runtime composition in
`Apps/Host/HostRuntime.swift` and `Apps/Viewer/ViewerRuntime.swift`. A Host
starts Bonjour to trigger Local Network consent, requests Screen Recording,
advertises eligible windows, validates the
selected generation, captures and encodes it, and forwards authorized
input/clipboard messages. A Viewer discovers the Host, presents an explicit
picker for the eligible advertised windows, decodes and presents H.264 frames
through Metal, and forwards mouse/keyboard events from the same aspect-fit
surface. The production path now uses TLS bootstrap plus Keychain-backed
two-sided pairing: a first connection shows a Host consent prompt and a Viewer
code-entry prompt, while a later connection silently exchanges the same
challenge when both trust records match and reuses them without prompting. If
only one endpoint has a record, the other endpoint still receives the consent
flow and the completed exchange repairs both records. Each endpoint
automatically enrolls its own local P-256 identity in the login Keychain. The
physical evidence below remains required; deterministic
build/test output must not be used as a substitute.

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

2. On the Intel Host, grant Local Network and Screen Recording permission to
   the installed Host app (or the exact terminal used for the debug physical
   smoke). The Host starts Bonjour first so Local Network consent can appear.
   After a
   Viewer negotiates input and the operator selects a window, the signed Host
   requests Accessibility/post-event access from the Host bundle. Until those
   input permissions are authorized, the Host remains view-only and does not
   authorize mouse/keyboard capabilities.
   The capability may still appear in the negotiation offer; authorization is
   the security gate that reflects the current permission state.
   Install the role-specific app with the DMG's standard `Applications` alias,
   or use its optional `Install-MacRemoteApp-*.command` helper. The DMG helper
   is double-click-only and has no CI or testing options. The repository-only
   `scripts/install-device-apps.sh` is reserved for debug/release workflows.
   On the Apple Silicon Viewer, grant Local Network access.
3. No production identity file is required. On first launch, each app creates
   or reuses its own P-256 TLS identity in that Mac's login Keychain. Never
   copy a private key or PKCS#12 file into the repository or to the other Mac.
   Generate fresh M2 identities outside the repository only when running the
   explicit debug physical-smoke commands below.

When launching the installed production bundles below, do not set
`MACREMOTEAPP_PEER_CERT` for the normal AirPlay-like first-pairing flow: the
Host and Viewer enroll their local TLS identities, establish the presented
peer identities, show the same one-time code, require local consent on both
endpoints, and then save the peer records in the Keychain.
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
| Pairing | Host displays a code, Viewer enters the matching code, both operators consent, and trust records are stored | ☐ |
| Window selection | Exactly one eligible foreground window is selected | ☐ |
| Capture/display | Viewer renders the selected window with aspect preservation | ☐ |
| Performance | 30-second report has clock probes, valid samples, p50/p95, fps and resource data | ☐ |
| Input | Each authorized input capability works only while authorized; mouse-only or keyboard-only authorization keeps the other local controls disabled | ☐ |
| Clipboard | Text-only opt-in works; opt-out and echo prevention work | ☐ |
| Permission recovery | Local Network, Screen Recording, or Accessibility denial/revocation disables the affected path and gives a recoverable instruction | ☐ |
| Window recovery | Close/change/focus loss disables input and reports a recoverable state | ☐ |
| LAN recovery | Disconnect shows reconnecting; reauthorization is required before input resumes | ☐ |
| Stale trust | Revocation or identity mismatch requires explicit re-pairing | ☐ |
| Failure UX | Malformed/unsupported/oversized input fails closed without sensitive diagnostics | ☐ |

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
