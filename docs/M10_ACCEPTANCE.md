# M10 V1 Integration Pilot and Acceptance

## Scope

M10 is the final Intel Host to Apple Silicon Viewer acceptance run. It does
not add features beyond the V1 specification. Use a disposable foreground test
application whose content contains no private data.

## Prerequisites

1. Build the release candidates on the current checkout:

   ```bash
   bash scripts/package-device-apps.sh
   bash scripts/audit-release.sh
   ```

2. On the Intel Host, grant Screen Recording and Accessibility permission to
   the installed Host app (or the exact terminal used for the debug physical
   smoke). On the Apple Silicon Viewer, grant Local Network access.
3. Generate fresh M2 identities outside the repository and pair both local
   operators. Never copy a private key or PKCS#12 file into the repository.

## Acceptance sequence

| Step | Acceptance evidence | State |
| --- | --- | --- |
| Fresh install | Host/Viewer app bundles launch and signatures verify | ☐ |
| Pairing | Both operators consent; trusted identity is shown | ☐ |
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

## Evidence and residual limitations

Archive only sanitized logs and the JSON performance report. Do not archive
screen captures, clipboard content, raw input values, private keys, or full
window titles. Record the exact Mac model, architecture, macOS build, app
signature identity, permission state, network conditions, selected test app,
and every unchecked item above. An unchecked physical item is an explicit V1
exception; it is not reported as verified.
