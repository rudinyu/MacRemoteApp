# M10 V1 Integration Pilot and Acceptance

## Scope

M10 is the final Intel Host to Apple Silicon Viewer acceptance run. It does
not add features beyond the V1 specification. Use a disposable foreground test
application whose content contains no private data.

The repository now contains a production runtime composition in
`Apps/Host/HostRuntime.swift` and `Apps/Viewer/ViewerRuntime.swift`. A Host
launches the Bonjour listener, advertises eligible windows, validates the
selected generation, captures and encodes it, and forwards authorized
input/clipboard messages. A Viewer discovers the Host, presents an explicit
picker for the eligible advertised windows, decodes and presents H.264 frames
through Metal, and forwards mouse/keyboard events from the same aspect-fit
surface. The production path now uses TLS bootstrap plus Keychain-backed
two-sided pairing: a first connection shows a Host consent prompt and a Viewer
code-entry prompt, while a later connection silently exchanges the same
challenge when both trust records match and reuses them without prompting. If
only one endpoint has a record, the other endpoint still receives the consent
flow and the completed exchange repairs both records. A local device identity
must still be provisioned in the Keychain. The physical evidence below remains
required; deterministic
build/test output must not be used as a substitute.

## Prerequisites

1. Build the release candidates on the current checkout:

   ```bash
   export MACREMOTEAPP_SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
   bash scripts/release-notarized.sh
   ```

   This first runs the repository validation (`.codex/ci.sh` when available,
   otherwise `scripts/validate.sh`). Only after deterministic CI passes does it
   build, submit, staple, and validate notarized `MacRemoteApp-Host.dmg` and
   `MacRemoteApp-Viewer.dmg`, together with the stapled app bundles. The
   default output is the repository-adjacent
   `../MacRemoteApp-Release/` directory, outside the repository and `.build`.
   The flow stages a new release and replaces the previous directory only
   after notarization validation succeeds, so a failed run does not discard the
   last known-good release.
   The successful CI and notarization flow removes the repository `.build`
   cache. The script uses the local `notarytool-profile` Keychain profile by
   default. Do not place the profile, its credentials, or the signing identity
   configuration in the repository.
   To validate that exact notarized directory without rebuilding or uploading,
   run:

   ```bash
   bash scripts/validate-notarized-release.sh \
     "$(cd .. && pwd)/MacRemoteApp-Release"
   ```

   `scripts/notarize-device-apps.sh` is the lower-level operation and requires
   an absent or empty output directory; use `scripts/release-notarized.sh` for
   the complete replacement-safe CI-gated release flow.

2. On the Intel Host, grant Screen Recording and Accessibility permission to
   the installed Host app (or the exact terminal used for the debug physical
   smoke). Install the role-specific app with
   `scripts/install-device-apps.sh` or the
   `Install-MacRemoteApp-*.command` file in its DMG. On the Apple Silicon
   Viewer, grant Local Network access.
3. Generate fresh M2 identities outside the repository and provision each
   endpoint's own identity in its local Keychain. Never copy a private key or
   PKCS#12 file into the repository or to the other Mac.

For the production runtime, provision the local identity in the Keychain under
the `MacRemoteApp` label (or set `MACREMOTEAPP_LOCAL_IDENTITY_LABEL`). When
launching the installed production bundles below, do not set
`MACREMOTEAPP_PEER_CERT` for the normal AirPlay-like first-pairing flow: the
Host and Viewer establish the presented TLS identities, show the same one-time
code, require local consent on both endpoints, and then save the peer records
in the Keychain. `MACREMOTEAPP_PEER_CERT` remains an optional pinned-peer
migration/diagnostic path.

The debug role commands below intentionally exercise the existing M2/M7
physical smoke harness, which uses explicit PKCS#12 identities and pinned
public certificates. For those commands only, set `MACREMOTEAPP_PEER_CERT` as
documented in `docs/M2_PHYSICAL_SMOKE.md`; that legacy test setup is separate
from the production bundle's first-pairing flow.

## Acceptance sequence

| Step | Acceptance evidence | State |
| --- | --- | --- |
| Fresh install | Host/Viewer app bundles launch and signatures verify | ☐ |
| Pairing | Host displays a code, Viewer enters the matching code, both operators consent, and trust records are stored | ☐ |
| Window selection | Exactly one eligible foreground window is selected | ☐ |
| Capture/display | Viewer renders the selected window with aspect preservation | ☐ |
| Performance | 30-second report has clock probes, valid samples, p50/p95, fps and resource data | ☐ |
| Input | Pointer, button, scroll, keyboard and modifiers work only while authorized | ☐ |
| Clipboard | Text-only opt-in works; opt-out and echo prevention work | ☐ |
| Permission recovery | Screen Recording/Accessibility denial or revocation disables the affected path | ☐ |
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
installed app bundle. For a direct terminal launch during setup, use the
bundle executable paths. No peer-certificate environment variable is needed
for the normal first-pairing flow:

```bash
"$HOME/Applications/MacRemoteApp-Host.app/Contents/MacOS/MacRemoteApp-Host"
"$HOME/Applications/MacRemoteApp-Viewer.app/Contents/MacOS/MacRemoteApp-Viewer"
```

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
