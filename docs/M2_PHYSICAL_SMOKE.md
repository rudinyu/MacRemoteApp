# M2 physical Intel Host to Apple Silicon Viewer smoke

This runbook validates the M2 boundary on two real Macs: Bonjour discovery,
TLS 1.3 mutual authentication with pinned public identities, capability
negotiation, and Host authorization. It intentionally does not start capture,
video encoding, Metal presentation, mouse/keyboard injection, or clipboard
transfer.

## What is exchanged

Each device keeps its own private key inside its PKCS#12 file. Only the public
DER certificate for the opposite device is copied to the local machine:

| Device | Keep private | Copy to this device |
| --- | --- | --- |
| Intel Host | `host.p12` | `viewer.cer` |
| Apple Silicon Viewer | `viewer.p12` | `host.cer` |

Do not copy either `.p12` file to the other Mac or commit the generated files.
The smoke flag uses those pre-provisioned identities as the deterministic M2
trusted-peer test; it is not a replacement for the later user-facing pairing
flow.

## 1. Build signed app bundles

Run this on the development Mac. The script builds a universal Host
(`x86_64` + `arm64`) and an Apple Silicon Viewer, creates the `.icns` from the
checked-in SVG, embeds Local Network/Bonjour metadata, and packages both app
bundles under `.build/device-binaries/release/`.

For stable macOS TCC identity, use a Developer ID Application certificate. Do
not put the certificate name in the repository; pass it only in the shell:

```sh
cd /Users/rudin_yu/codexworkspace/MacRemoteApp
export MACREMOTEAPP_SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
./scripts/package-device-apps.sh
```

For a compile-only local bundle, omit the variable and the script will use
ad-hoc signing. Ad-hoc output is suitable for protocol smoke development but
can cause macOS privacy permission identity to reset when the app changes.

Copy these artifacts to the Macs without copying repository metadata:

- Intel Mac: `MacRemoteApp-Host.app` or its zip.
- Apple Silicon Mac: `MacRemoteApp-Viewer.app` or its zip.

The common icon is the source-of-truth vector at
`Resources/MacRemoteAppIcon.svg`; the packaging script produces the Finder
`.icns` from it.

## 2. Generate test identities

Run once on a trusted development Mac and transfer only the files listed in
the table above:

```sh
cd /Users/rudin_yu/codexworkspace/MacRemoteApp
./scripts/create-m2-identities.sh "$HOME/MacRemoteApp-identities"
```

The output directory must be outside the repository; the script rejects the
repository itself and all of its descendants before creating any identity
files. Its parent directory must already exist. Keep the generated directory
restricted and never commit or copy either `.p12` private key to the opposite
device.

The script prompts for one password without echoing it. It creates:
`host.p12`, `host.cer`, `viewer.p12`, and `viewer.cer`. Store the directory
with restrictive permissions and remove the generated identities after the
test if they are no longer needed.

## 3. Start the Intel Host

On the Intel Mac, install the Host app and set paths to the local `host.p12`
and the copied `viewer.cer`:

```sh
export MACREMOTEAPP_LOCAL_IDENTITY_P12="$HOME/MacRemoteApp-identities/host.p12"
export MACREMOTEAPP_PEER_CERT="$HOME/MacRemoteApp-identities/viewer.cer"
read -r -s MACREMOTEAPP_P12_PASSWORD
export MACREMOTEAPP_P12_PASSWORD
export MACREMOTEAPP_SERVICE_NAME='MacRemoteApp-Host'
export MACREMOTEAPP_M2_TIMEOUT_SECONDS=60

"$HOME/Applications/MacRemoteApp-Host.app/Contents/MacOS/MacRemoteApp-Host" \
  --m2-physical-host
```

The Host should print that it is listening on `_macremote._tcp` and wait for
the Viewer. If macOS asks for Local Network or incoming-connection access,
allow it. The Host's Screen Recording permission is not needed for this M2
session-only flag; it is needed later for `--m3-list-windows` and capture.

## 4. Start the Apple Silicon Viewer

On the Apple Silicon Mac, install the Viewer app and set paths to the local
`viewer.p12` and the copied `host.cer`:

```sh
export MACREMOTEAPP_LOCAL_IDENTITY_P12="$HOME/MacRemoteApp-identities/viewer.p12"
export MACREMOTEAPP_PEER_CERT="$HOME/MacRemoteApp-identities/host.cer"
read -r -s MACREMOTEAPP_P12_PASSWORD
export MACREMOTEAPP_P12_PASSWORD
export MACREMOTEAPP_HOST_NAME='MacRemoteApp-Host'
export MACREMOTEAPP_M2_TIMEOUT_SECONDS=60

"$HOME/Applications/MacRemoteApp-Viewer.app/Contents/MacOS/MacRemoteApp-Viewer" \
  --m2-physical-viewer
```

The Viewer should report Bonjour discovery, a trusted peer fingerprint prefix,
capability negotiation, and authorization. A successful run ends with:

```text
M2 physical smoke PASS (Host authorized Viewer)
M2 physical smoke PASS (Viewer received Host authorization)
```

The fingerprint is deliberately truncated and no password, private key, raw
input, clipboard text, window title, or captured frame is logged.

## Failure triage

| Symptom | Check |
| --- | --- |
| Viewer times out before discovery | Same LAN/subnet, Host process still running, macOS Local Network permission, firewall, and exact `MACREMOTEAPP_SERVICE_NAME`/`MACREMOTEAPP_HOST_NAME` |
| PKCS#12 import fails | Local `.p12` path, password, file permissions, and that the file belongs to the same role |
| TLS authentication fails | Each side has the opposite `.cer`, not its own certificate; regenerate the pair if files were mixed |
| Host sees a connection but session fails | Both binaries come from the same repository revision and both advertise `pingPong`; rerun with a longer timeout |
| macOS permission appears attached to Terminal | The direct internal-binary command is launched by Terminal. Grant Terminal Local Network/Screen Recording for this diagnostic, or launch the signed app with `open -n` and inspect its own permission entry |

## Scope boundary

This run proves the M2 transport/session gate across two architectures. It does
not prove Intel ScreenCaptureKit behavior, H.264 hardware encoding, Viewer
Metal presentation, or end-to-end input/clipboard behavior. Those require the
M3-M7 milestones and their own explicit physical tests.
