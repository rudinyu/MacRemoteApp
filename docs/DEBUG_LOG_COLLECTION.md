# MacRemoteApp How to Collect Debug Logs

Collect logs only after reproducing the problem once. Use a new directory for
each incident and keep it outside the repository.

## 1. Create a support directory

```sh
stamp="$(date +%Y%m%d-%H%M%S)"
support_dir="$HOME/Desktop/MacRemoteApp-Debug-${stamp}"
mkdir -p "$support_dir"
```

## 2. Capture the production startup log

Quit the app first. Start the unified-log stream in one Terminal window, then
launch the signed app bundle itself from a second Terminal window. Stop the
stream with Control-C after reproducing the issue. These files contain the
macOS unified startup log, not the app process's stdout/stderr:

```sh
log stream --style compact \
  --predicate 'subsystem == "com.rudinyu.MacRemoteApp" AND category == "startup"' \
  2>&1 | tee "$support_dir/host-startup.log"
```

In the second Terminal window, launch the Host:

```sh
open -n "$HOME/Applications/MacRemoteApp-Host.app"
```

Use the Viewer app bundle for Viewer-side evidence:

```sh
log stream --style compact \
  --predicate 'subsystem == "com.rudinyu.MacRemoteApp" AND category == "startup"' \
  2>&1 | tee "$support_dir/viewer-startup.log"
```

In the second Terminal window, launch the Viewer:

```sh
open -n "$HOME/Applications/MacRemoteApp-Viewer.app"
```

For M8 latency-budget evidence, stream the per-stage aggregate lines on each
Mac during a session of at least 30 seconds. The Host writes them under
category `host-runtime` and the Viewer under `startup`; they contain timing
aggregates only:

```sh
log stream --style compact \
  --predicate 'subsystem == "com.rudinyu.MacRemoteApp" AND eventMessage BEGINSWITH "M8 stage"' \
  2>&1 | tee "$support_dir/m8-stage-budget.log"
```

Do not launch `Contents/MacOS/...` for permission validation: that can attach
macOS TCC decisions to the Terminal process instead of the signed app bundle.
The direct executable is reserved for a separately documented debug build and
must not be used as evidence for the production app's permission state. The
production startup error path is mirrored to unified logging specifically so
Keychain enrollment and permission failures are captured as bounded error codes
even when the app is opened with Finder; private filesystem paths and
underlying error descriptions are not written to the public startup stream.

For a debug repository run, capture the same way without recording the
password or private-key material:

Run the Host command on the Intel Host Mac. It is a blocking smoke test and
must remain running while the Viewer connects:

```sh
cd <repository-root>
bash scripts/run-m10-acceptance.sh host 2>&1 | tee "$support_dir/host-smoke.log"
```

Run the Viewer command on the Apple Silicon Viewer Mac (or in a separate
Terminal on a machine prepared for the Viewer role):

```sh
cd <repository-root>
bash scripts/run-m10-acceptance.sh viewer 2>&1 | tee "$support_dir/viewer-smoke.log"
```

These commands are intentionally not a sequential same-shell recipe: each
physical smoke process waits for the other endpoint.

## 3. Optional debug stdout/stderr

Only use this section for a debug build when the terminal output itself is
needed. It is separate from the production permission evidence above:

```sh
<repository-root>/.build/debug/Host 2>&1 | tee "$support_dir/host-stdio.log"
```

Run the corresponding Viewer command on the Viewer Mac or in another Terminal:

```sh
<repository-root>/.build/debug/Viewer 2>&1 | tee "$support_dir/viewer-stdio.log"
```

Do not use the direct executable for TCC permission validation, and do not
record passwords, private-key material, clipboard text, or raw input values.

## 4. Capture recent macOS unified logs

Run this soon after reproducing the issue:

```sh
log show --last 15m --style compact \
  --predicate 'process == "MacRemoteApp-Host" OR process == "MacRemoteApp-Viewer"' \
  > "$support_dir/unified-log.txt"
```

If the process name is unavailable, collect the last few minutes and filter
locally before sharing. Do not collect the entire system log by default.

## 5. Record non-secret environment metadata

```sh
sw_vers > "$support_dir/system.txt"
printf 'architecture: %s\n' "$(uname -m)" >> "$support_dir/system.txt"
codesign --display --verbose=4 \
  "$HOME/Applications/MacRemoteApp-Host.app" \
  > "$support_dir/host-signature.txt" 2>&1
```

Collect the corresponding Viewer signature on the Viewer Mac. The commands
above intentionally collect only the OS version/build, architecture, and app
signature metadata. Do not include the output of `env`, shell history, Keychain exports, hardware serial numbers,
Hardware UUIDs, Provisioning UDIDs, or private certificate files.

## 6. Redact and package

Before sharing, remove or redact pairing codes, passwords,
`MACREMOTEAPP_P12_PASSWORD`, private-key paths, home-directory details, IP
addresses if not needed, hardware serial numbers, Hardware UUIDs,
Provisioning UDIDs, full window titles, clipboard text, screenshots, and
unrelated application logs. Never include `.p12`, `.key`, or private `.pem`
files.

After review, package only the sanitized text files:

```sh
ditto -c -k --keepParent "$support_dir" "${support_dir}.zip"
```

Keep the original directory until the issue is closed, then remove both the
directory and archive if they are no longer needed.
