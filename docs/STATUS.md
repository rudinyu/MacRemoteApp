# MacRemoteApp Milestone Status

This is the single source for current milestone state and open evidence gaps.
README, the product specification, and the development plan link here instead
of repeating the narrative. Milestone scope, exit criteria, and verification
items remain defined in [the development plan](DEVELOPMENT_PLAN.md).

Update this file whenever a milestone's state or evidence changes. An item
listed as pending physical or environment evidence stays pending until that
evidence is actually recorded; a successful local build, deterministic test,
loopback test, or synthetic benchmark does not upgrade it to verified.

## Summary

The public source snapshot at commit `a63222e`
is included in the signed and notarized `0.2.1011` RC; both app bundle plists
use Build `1011`. The latest completed in-house Debug diagnostic pair is Build
`1024`; both role apps, ZIPs, and DMGs were signed, notarized, stapled, and
Gatekeeper verified on 2026-10-15. These are diagnostic artifacts, not a public
release. Build `1025` is the current M10 source candidate. Its complete local
`.codex/ci.sh` validation passed on 2026-10-15, including Host arm64/x86_64 and
Viewer arm64 builds, deterministic package/app tests, and local testing-channel
packaging/audit. The separate signed/notarized Debug diagnostic pair has not
been built, and no physical retest has been performed. Build `1025` targets the
reproducible Viewer `incoming_message_backpressure` disconnect during video
streaming. Build `1021` added an ordered Viewer-receipt barrier for authorization
transitions to address an identified immediate-disconnect race. Build `1022`
adds selected-window capture continuity when the app is inactive,
transient-catalog protection, and bounded same-owner stream recovery. Its full
`.codex/ci.sh` validation passed on 2026-10-14. The reported two-Mac symptom
still requires manual retest. The [Debug log guide](DEBUG_LOG_COLLECTION.md)
records the fixed disconnect fields as available starting with Build `1019`.
Build `1017` exposed a Viewer watchdog crash and a Host clipboard consent sheet
that appeared only when Host quit. Build `1018` fixes both watchdog timing
paths and the consent sheet lifecycle. The prior
`0.2.1010` RC was built from commit
`1e422da8799f183487276e2295008c6ebe499ec8` and is superseded. Physical
acceptance remains pending operator-recorded evidence for the exact installed
build. Historical Build `1018` includes the negotiated P6 process-target path
with separate Host control approval and a per-session Host clipboard prompt.
Build `1022` uses Host acceptance of the authenticated
Viewer pairing as durable input trust and negotiated Host clipboard authority,
without a second Host control or clipboard prompt. The Viewer-local clipboard
opt-in remains. Peers without P6 remain foreground-only. The signed Build
`1021` artifacts predate the Build `1022` source changes. Build `1023`
adds fixed Viewer input-failure categories. Build `1024` records the actual
`SessionTransport.send` boundary: stale admission rejected before that call
refreshes input readiness without resetting the authenticated video session;
failures after the call remain delivery-uncertain and end the session to
release Host-held state. Physical acceptance remains pending.

Build `1024` passed the full `.codex/ci.sh` gate on 2026-10-15. The universal
Host Debug app and arm64 Viewer Debug app, their ZIPs, and both DMGs were
Developer ID signed with hardened runtime, accepted by Apple, stapled, and
passed the Debug artifact, Gatekeeper, and notarized-ticket audits. The Host
DMG submission ID is `8d57381d-00ec-4d2b-9a98-c76dbb28783f`; the Viewer DMG
submission ID is `413c6db9-2776-4753-b923-761e6e23c0e4`. The two DMGs were
uploaded to the Dropbox root as `MacRemoteApp-Host-debug-diagnostic-0.2.1024.dmg`
and `MacRemoteApp-Viewer-debug-diagnostic-0.2.1024.dmg`.

Build `1024` Viewer launched on the local workstation and wrote its startup
diagnostic entry, but its Host picker remained empty. No session or remote
input was exercised in that run. Two-Mac physical testing remains pending.

### 0.2.1025 M10 diagnostic test candidate

The Host and Viewer source plists identify Version `0.2`, Build `1025`. This
source candidate updates M10 media admission so a newer independently
decodable keyframe can replace older queued keyframes and delta frames while
preserving control messages and required media such as `VideoConfig`. Regression
coverage exercises a full incoming media queue containing multiple keyframes,
control-message retention, and the awaiting-keyframe behavior when required
media blocks admission.

Build `1024` Viewer diagnostics recorded repeated
`incoming_message_backpressure` failures at 01:37:17.850Z and 01:37:40.910Z;
the corresponding Host logs recorded Viewer-initiated transport EOF. The
Viewer receive/presentation path also showed roughly 0.8–1.0 second main-actor
stalls. The focused TransportCore regression, canonical `.codex/ci.sh`
validation, and local testing-channel packaging/audit passed on 2026-10-15.
The separate Build `1025` Debug diagnostic package has not been built or
signed. No physical retest has been performed; Build `1025` remains a source
candidate, not an installed diagnostic artifact or public release.

| Milestone | Implementation / deterministic gate | Evidence still pending |
| --- | --- | --- |
| M0 | Complete | — |
| M1 | Complete | — |
| M2 | Code gates complete; real loopback mutual-TLS/session smoke passed | Physical Intel Host to Apple Silicon Viewer Bonjour/TLS pass |
| M3 | CaptureCore foundation and deterministic tests complete; live frame verified on the current M5 | Logged-in window-server and Screen Recording evidence on other machines |
| M4 | Deterministic gate complete | VideoToolbox encode/decode hardware smoke is opt-in |
| M5 | Viewer input transport gate complete | — |
| M6 | Implementation/test gate complete | Real OS event posting (manual disposable-application test) |
| M7 | Implementation/test gate complete | Physical two-machine clipboard walkthrough |
| M8 | Deterministic measurement/resilience gate implemented | Physical clock-synchronized performance report |
| M9 | Release-audit gate implemented; current `0.2.1011` notarized RC artifacts verified | Physical acceptance remains separate |
| M10 | Production composition, pairing UI, deterministic capture/pairing recovery checks, and Build `1025` full local validation complete; signed/notarized Debug artifacts through Build `1024` | Build `1025` Debug diagnostic package and artifact retest; physical Intel-to-Apple-Silicon acceptance, including background stream, connected UI, and disconnect retest |

### 0.2.1024 in-house Debug diagnostic artifacts

The Build `1024` Host and Viewer in-house Debug diagnostic apps contain the M10
`sendInput` transport-boundary
correction. On 2026-10-15, `.codex/ci.sh` passed; Host and Viewer app ZIPs and
DMGs were Developer ID signed, accepted by Apple, stapled, and validated.
Dropbox upload completed for both DMGs in the root. The local Viewer launch
found no Host, so the fix has not yet been exercised over a live two-Mac
session.

### 0.2.1023 in-house Debug diagnostic artifacts

On 2026-10-14, Build `1023` Host and Viewer Debug apps were built from the
current source, Developer ID signed with hardened runtime, packaged with empty
Debug entitlements, and submitted to Apple. Host is universal `arm64`/`x86_64`;
Viewer is `arm64`. Both app ZIPs and both DMGs were accepted, stapled, and
passed signature, Gatekeeper, and notarized-ticket validation. The full
`.codex/ci.sh` gate and the focused Viewer lifecycle/diagnostic tests passed.

The paired logs for Build `1022` show that Viewer recorded one input send
failure in the five-second interval ending just after it cleared the selected
window; Host then recorded transport EOF and no input events. Build `1022` did
not record the fixed failure category, so this is strong evidence for a Viewer
input-send failure preceding teardown, not proof of its exact cause. Build
`1023` classifies local preflight, capability, and current-readiness failures
as input-only recovery; ambiguous send-stage failures, queue overflow, and
held-state release failures remain terminal.

| Artifact | Apple submission ID | Status |
| --- | --- | --- |
| Host app ZIP | `fff3c2b7-aded-4a5d-a15f-3023930d1681` | Accepted |
| Viewer app ZIP | `1344ed93-4c4f-45d8-956e-b743ee44bf30` | Accepted |
| Host DMG | `31b4b5c7-32f4-4e64-b32a-829e5860c7ed` | Accepted |
| Viewer DMG | `ed2040fa-29a0-4d0d-9aca-9837903e02b4` | Accepted |

| Delivered DMG | SHA-256 | Dropbox |
| --- | --- | --- |
| `MacRemoteApp-Host-debug-diagnostic-0.2.1023.dmg` | `734b3584f575c85f598751cb11b4cae18c2e742c33e93afa4f01f7f861d24d3a` | `/MacRemoteApp-Host-debug-diagnostic-0.2.1023.dmg` |
| `MacRemoteApp-Viewer-debug-diagnostic-0.2.1023.dmg` | `3735db78fc5d389271ceff83ecf8f609bd7a74be22b9079c4aa5e12abe2e475a` | `/MacRemoteApp-Viewer-debug-diagnostic-0.2.1023.dmg` |

Dropbox upload completed. Installation and physical two-Mac retest remain
pending because the local ScreenDock desktop was locked during preflight.

### 0.2.1021 in-house Debug diagnostic artifacts

On 2026-10-14, the M10 Debug diagnostic Host and Viewer were built with
Version `0.2`, Build `1021`, signed with the existing Developer ID Application
identity, submitted to Apple, stapled, and verified. Host is universal
`arm64`/`x86_64`; Viewer is `arm64`. Authorization transitions now wait for
an ordered Ping/Pong receipt barrier, so local transport enqueue is not
mistaken for Viewer processing. Deterministic regression coverage includes
delayed receipt, timeout, and authorization queued across reconnect.

| Artifact | Apple submission ID | Status |
| --- | --- | --- |
| Host app ZIP | `25964bbf-cc49-473a-81c5-21a1d9d26556` | Accepted |
| Viewer app ZIP | `dd51a4ab-a29c-4792-80c0-369978c3cbb7` | Accepted |
| Host DMG | `74cf1c15-47aa-4a67-a36d-bd727d3a2e5a` | Accepted |
| Viewer DMG | `1780e630-e2ca-4068-aae1-8c31f6c6ba53` | Accepted |

| Delivered DMG | SHA-256 |
| --- | --- |
| `MacRemoteApp-Host-debug-diagnostic-0.2.1021.dmg` | `ad630344026aef8dcccf74c8377f178f0691ceb74abc830b361063740193869d` |
| `MacRemoteApp-Viewer-debug-diagnostic-0.2.1021.dmg` | `09a3582d2973525f0289cf5e57d8394a16a07cdf178489a330acf9f24375e3f4` |

Build 1021's DMGs were superseded and removed from the retained diagnostic
channel when Build 1022 was promoted; the filenames and hashes above are
historical records. The complete `.codex/ci.sh` gate passed before packaging. The final audit
verified Developer ID signatures, hardened runtime, architecture and
metadata, ZIP equivalence, DMG contents, stapled tickets, and Gatekeeper
acceptance. These apps keep the production bundle identifiers, preserving
installed TCC permissions and Keychain pairings. They are in-house diagnostic
artifacts, not a public release. Physical Intel-to-Apple-Silicon acceptance
and confirmation that the reported disconnect is fixed remain pending.

### 0.2.1022 in-house Debug diagnostic artifacts

The Host and Viewer app bundles were built from source plists set to Version
`0.2`, Build `1022`. This M10 integration keeps a selected-window stream
independent of app foreground state. CaptureCore resolves the exact selected
target from the full ScreenCaptureKit catalog, preserves the stream across three
consecutive transient lookup misses, and makes at most two delayed restarts
after unexpected stream completion. Initial capture and restarts revalidate
window ID, bundle ID, PID, layer 0, and valid geometry; recovery does not
require `isActive`. Host withholds a refreshed picker catalog that omits its
active selection, and keeps the authenticated session alive while capture is
recovering. The Host reuses accepted pairing trust for input and negotiated
clipboard capability; the Viewer-local clipboard opt-in remains session-local.

Deterministic tests cover inactive/offscreen authorized startup, transient
catalog gaps and frame delivery, normal stream termination, retry exhaustion,
owner mismatch, pinned generation dimensions, Viewer recovery status, Host
session retention, and clipboard authorization without a Host prompt. The full
`.codex/ci.sh` passed on 2026-10-14, including Host arm64/x86_64 and Viewer
arm64 builds, deterministic package and app tests, local ad-hoc validation
packaging, and the M9 release audit. The script removed its successful
validation cache. The Host and Viewer apps and DMGs were then signed with the
existing Developer ID Application identity, submitted to Apple, stapled, and
verified on 2026-10-14. Host is universal `arm64`/`x86_64`; Viewer is `arm64`.

| Artifact | Apple submission ID | Status |
| --- | --- | --- |
| Host app ZIP | `78e98aa5-0cfb-48b9-880e-ceebe55b64e3` | Accepted |
| Viewer app ZIP | `ded62ec3-e381-4dc5-b40f-8f3e48cb0324` | Accepted |
| Host DMG | `2025da60-c7d1-471c-b9f2-f330bf95bac0` | Accepted |
| Viewer DMG | `127602b3-5201-4155-b60d-a3f911c45f89` | Accepted |

| Delivered DMG | SHA-256 |
| --- | --- |
| `MacRemoteApp-Host-debug-diagnostic-0.2.1022.dmg` (superseded) | `3bc3b8aaa0d4a66643b56c261f47897825e278fd123f11d22c69c6f27fd728b3` |
| `MacRemoteApp-Viewer-debug-diagnostic-0.2.1022.dmg` (superseded) | `2c56bc572a2ddcd5f36d7a1fda9677cf255dfdf96421eeaaf9e62206b8172e6b` |

Build `1022` DMGs were removed from the retained Debug channel when Build
`1023` was promoted; the filenames and hashes above are historical evidence.

The final audit verified Developer ID signatures, hardened runtime,
architectures and metadata, ZIP equivalence, DMG contents, stapled tickets,
and Gatekeeper acceptance. Physical Intel-to-Apple-Silicon testing of
background frames, recovery, input, clipboard, and security restrictions
remains pending.

### 0.2.1020 in-house Debug diagnostic artifacts

On 2026-10-14, the current M10 Debug diagnostic Host and Viewer were built with
Version `0.2`, Build `1020`, signed with the existing Developer ID Application
identity, submitted to Apple, stapled, and verified. Host is universal
`arm64`/`x86_64`; Viewer is `arm64`. The Host peer-close path schedules teardown
after its input-message callback returns;
`HostRuntimeRecoveryPolicyTests.testCallbackTeardownSchedulerReturnsBeforeLoopTeardown`
covers that teardown-ordering primitive. All four Apple submissions were
accepted:

| Artifact | Apple submission ID | Status |
| --- | --- | --- |
| Host app ZIP | `12680e8e-284e-4fa2-bb54-7b22a91e2a11` | Accepted |
| Viewer app ZIP | `315515dd-8680-470a-b69d-451bdcc0e62a` | Accepted |
| Host DMG | `38e407dd-00f9-45dc-a467-041e428f56cb` | Accepted |
| Viewer DMG | `2d984c3e-ac1f-4e1e-bb18-23ba547cf6fd` | Accepted |

| Delivered DMG | SHA-256 |
| --- | --- |
| `MacRemoteApp-Host-debug-diagnostic-0.2.1020.dmg` (superseded) | `ef672503fe30e6ddd2e7fb3f314b42bbbd41a54a8da42dce1ac3d278b7f9e0b2` |
| `MacRemoteApp-Viewer-debug-diagnostic-0.2.1020.dmg` (superseded) | `52009499343fe2c227fdf4b47b00d2296c8b2d4e05a7ae62db4a84c8aabe5a8a` |

The complete `.codex/ci.sh` gate passed before packaging. The final audit
verified the Developer ID signatures, hardened runtime, architecture and
metadata, ZIP equivalence, DMG contents, stapled tickets, and Gatekeeper
acceptance. These app bundles retain the production bundle identifiers so
they replace installed apps and keep their TCC permissions and Keychain
pairings. They are in-house diagnostic artifacts, not a public release.
Physical Intel-to-Apple-Silicon acceptance, including connected UI rows, is
still pending for the exact installed build.

### 0.2.1018 in-house Debug diagnostic artifacts

On 2026-10-14, the operator authorized an in-house Debug diagnostic package for
manual testing. The dedicated script built Host `arm64`/`x86_64` and Viewer
`arm64` in SwiftPM Debug configuration. Both app plists use Version `0.2`,
Build `1018`. It signed the apps and role-specific DMGs, submitted both app
ZIPs and DMGs to Apple, stapled the accepted tickets,
and passed the final notarized-artifact audit before promoting the pair to
`build/debug-diagnostic/`. This channel keeps the production bundle identities
so it replaces the installed role apps and retains their TCC permissions and
Keychain pairings. It is not a public release.

All four Apple submissions were accepted:

| Artifact | Apple submission ID | Status |
| --- | --- | --- |
| Host app ZIP | `f2a6e513-bd39-4497-bada-18a641eb6c8c` | Accepted |
| Viewer app ZIP | `dc846409-f0ed-4d3e-ba88-f6082f53f668` | Accepted |
| Host DMG | `4eeb59f1-6f89-4d90-8252-3654bf5b3ee2` | Accepted |
| Viewer DMG | `b499abd8-53b7-4b13-b14c-4e6e700d07b0` | Accepted |

| Delivered DMG | SHA-256 |
| --- | --- |
| `MacRemoteApp-Host-debug-diagnostic-0.2.1018.dmg` (superseded) | `efe2bf0a682d621d873739354936007d5bef684b83d0ad92c17118bf48619a72` |
| `MacRemoteApp-Viewer-debug-diagnostic-0.2.1018.dmg` (superseded) | `61aa1863ef03b9220010ab8551a2c811c32f626461b0f37f10a2b1d0a8b00961` |

The full `.codex/ci.sh` validation passed before packaging. The final artifact
audit verified app signatures, architecture/metadata, ZIP equivalence, DMG
contents, stapled tickets, and Gatekeeper acceptance. Physical two-Mac input,
clipboard, and performance acceptance remains manual and pending; Apple
notarization and local CI do not establish it.

## Authorized source follow-ups (2026-10-08)

- **P6 / M6 input extension:** the Host-authorized, negotiated process-target
  path is active for supported peers. It keeps secure-input, target identity,
  permission, generation, and console-state checks fail-closed. Physical P6
  input/IME acceptance remains pending; see [the P6 contract](P6_BACKGROUND_CONTROL.md).
- **M9 signing adapter:** both canonical release entry points now resolve the
  shared owner-only Codex configuration, preserve explicit project profile
  overrides, and support the existing external API-key reference. Focused
  synthetic configuration fixtures and Bash syntax checks passed. At this
  source-validation stage, no Developer ID signing or Apple submission was
  performed; the subsequent authorized release is recorded below.

Final local validation on 2026-10-08:

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./.codex/ci.sh`
  passed in the host-permitted context, including Host `arm64`/`x86_64`, Viewer
  `arm64`, root and package tests, deterministic benchmark checks, and ad-hoc
  `0.2.1010` testing DMG packaging/audit. The successful validation cache was
  removed by the canonical script. Log: `build/p6-final-validation.log`.
- Focused `swift test --configuration debug --scratch-path
  .build/public-validation/root --filter HostControlAuthorizationTests`
  passed, 12 tests / 0 failures, with the same explicit Xcode and local cache
  environment. Log: `build/p6-control-focused.log`.
- The first sandbox attempt stopped before compilation with
  `sandbox-exec: sandbox_apply: Operation not permitted`; this was an execution
  boundary, followed by the successful host validation above.
- Final Codex self-review covered tracked and untracked source, tests,
  release tooling, documentation, and relevant call sites; no remaining
  actionable findings. No separate reviewer or nested Codex process ran.

Physical P6 input/IME and Intel-to-Apple-Silicon M10 acceptance remain pending.
No commit, push, public release promotion, global configuration change, or
additional post-V1 feature was performed.

## Milestone detail

### M0 — Repository Foundation

- Complete. The Host target is validated for both `x86_64` and `arm64` builds;
  the V1 physical Host target remains Intel, while the Viewer target is Apple
  Silicon.

### M1 — RemoteProtocol

- The RemoteProtocol wire contract is complete.

### M2 — Secure LAN session

- The secure LAN session implementation, local Keychain identity enrollment,
  PKCS#12 diagnostic provisioning, and real loopback mutual-TLS/session smoke
  test are complete. M2 code gates are complete.
- The M5 environment has passed real loopback mutual-TLS/session startup with
  temporary identities; that is not evidence of physical Intel Host to Apple
  Silicon Viewer Bonjour/TLS interoperability.
- The repository includes a repeatable physical Intel Host to Apple Silicon
  Viewer Bonjour/TLS/capability smoke harness, signed app/DMG packaging, and
  role-specific install/uninstall scripts. The actual two-machine run remains
  an environment evidence gate.

### M3 — Host capture

- The Host window catalog and ScreenCaptureKit capture foundation are complete
  with deterministic fake-provider tests.
- A successful M5 live frame smoke test verified live frame evidence on the
  current M5 logged-in window-server session. Other machines still require
  their own logged-in window-server and Screen Recording evidence.

### M4 — Codec and presentation

- Bounded H.264 VideoToolbox encode/decode adapters, decoder-generation
  recovery rules, and a Viewer Metal presentation surface with deterministic
  layout/queue tests are in place. The deterministic gates are complete.
- The VideoToolbox encode/decode smoke is an explicit opt-in hardware check.

### M5 — Viewer input

- The Viewer-side typed input foundation and authenticated event transport are
  complete; the Viewer input transport gate passes with deterministic tests.

### M6 — Host input injection

- Host-side authorization-aware coordinate mapping and typed
  CoreGraphics/Accessibility injection adapters are implemented; the Host
  authorization/mapping implementation gate is complete with deterministic
  fake-adapter tests. M6 deterministic authorization and adapter gates pass.
- Real OS event posting remains an environment evidence item. It requires the
  documented disposable test application and PostEvent permission; P6
  background input also requires known-safe Accessibility inspection.
  On an explicit Viewer window selection, Accessibility can also provide a
  best-effort exact-window raise when geometry uniquely matches; missing or
  ambiguous matches remain blocked by the independent foreground check on the
  legacy path. P6 background input is blocked when Accessibility inspection is
  unavailable or reports an unsafe state; a detected secure field always
  remains fail-closed.

### M7 — Clipboard and session UX

- The opt-in text clipboard coordinator, bounded Offer/ACK/Text flow,
  echo/conflict handling, explicit session UX projection, and Host/Viewer
  AppKit string-pasteboard bridges are implemented. The implementation/test
  gate is complete, including the two app-layer pasteboard bridges.
- The physical Intel-Host/Apple-Silicon-Viewer clipboard walkthrough remains
  an environment evidence item.

### M8 — Performance and resilience

- The authenticated clock-sync/percentile model, deterministic performance
  harness, bounded-queue stress coverage, and reconnect/keyframe resilience
  evidence are implemented; the deterministic measurement/resilience gate is
  in place.
- Keyframe-aware media queues, the optional Viewer `KeyframeRequest`, the
  ordered encoder-to-wire relay, low-latency encoder settings, TCP `noDelay`,
  `420v` capture, and the per-stage latency budget with sanitized log lines
  are implemented with deterministic tests
  ([ADR-0006](decisions/0006-m8-transport-baseline-and-benchmark.md)).
- The physical report is pending. The clock-synchronized p50/p95 evidence
  and the per-stage `M8 stage` log lines must come from the physical
  Intel-to-Apple-Silicon run.

### M9 — Security hardening and release readiness

- Release-only debug gating, hardened-runtime artifact audit, negative-test
  documentation, and a residual-risk record are implemented; the
  release-audit gate is implemented.
- The current `0.2.1011` RC apps and DMGs are Developer ID signed, Apple
  notarized, stapled, and verified; both DMGs include the full-cleanup helper,
  alongside input-source following and the reliability fixes below.
  Credentials remain outside the repository in the shared configuration. See the
  [release evidence](#021011-notarized-rc).

### M10 — V1 integration pilot

2026-10-08 handoff: `0.2.1010` implementation and canonical local validation
are complete, and source commit `1038419` was pushed to `origin/main`.
The operator explicitly owns manual physical acceptance. The updated
[M10 checklist](M10_ACCEPTANCE.md) identifies the P6 background-control behavior,
notarization configuration, support/evidence matrix, and manual run record.
This handoff does not close the physical acceptance or release decision.
Documentation-only link/anchor, Bash-example syntax, milestone, and
`git diff --check` validation passed. Codex self-review found no remaining
actionable issue in the handoff diff; no new product build or physical run
is claimed for these documentation changes.

Implemented:

- Standalone [`Uninstall-MacRemoteApp.command`](../scripts/Uninstall-MacRemoteApp.command)
  for confirmed current-user cleanup of verified standard installations,
  role-owned data, and bundle-scoped TCC decisions. All 18 isolated safety
  fixtures passed on 2026-10-04, the real-host read-only preview passed, and
  the canonical `.codex/ci.sh` validation passed. An initial run encountered
  an existing TransportCore input-source test failure; its focused recheck
  and the subsequent complete validation passed. The last process-status
  safety adjustment was covered by a fresh 18-case fixture run and syntax checks.
  Live uninstallation and permission revocation were not performed. Local
  Network requires manual revocation; legacy shared/imported Keychain records
  are preserved. Both `0.2.1009` DMGs include the executable helper; release
  auditing checks source equivalence and its payload-manifest entry.
- The deterministic final gate, the production Host/Viewer composition with
  interactive pairing and Keychain trust reuse, and the two-machine acceptance
  checklist.
- Launchable Host and Viewer runtimes with TLS bootstrap, interactive
  two-sided pairing, Keychain trust reuse, resident permission recovery,
  explicit Host selection, same-session one-window replacement, and one
  selected-window capture/display/control path covering Bonjour/TLS, capture,
  H.264 encode/decode, Metal presentation, authenticated mouse/keyboard input,
  and opt-in text clipboard delivery.
- While a Viewer is authorized for a window, the Host menu-bar icon is tinted
  and the status menu names the shared app and whether the Viewer brought it
  to the front.
- The Viewer presents the eligible Host windows in a picker so a
  system/helper window is not selected silently. The Host remains
  authoritative for window eligibility, authorization, and replacement
  validation.
- Host permission/listener failures are recoverable from a resident
  status-menu action, and Bonjour readiness includes service registration.
- The Metal presentation path reports the actual `MTLDrawable.presentedTime`
  display boundary.
- The eligible window catalog refreshes during active sessions; the legacy
  input path foregrounds an explicitly selected regular app while P6 preserves
  its activation state. Both retain per-event input gates. The Viewer exposes
  truthful connection-button states, and both
  roles exchange short hostnames as display-only Hello metadata.
- Explicit trust reset controls on both endpoints (Host status menu and Viewer
  window) and editable Host discovery naming; the Host discovery name can be
  changed without rotating its TLS identity.
- Host and Viewer use separate Keychain identity labels and peer-trust
  services, so they can also be tested on the same Mac without sharing a
  private key, with signed per-role cleanup for uninstall. An upgrade from the
  previous shared-trust namespace requires one fresh pairing; legacy Keychain
  entries are left untouched by the upgrade.
- The M10 UI uses the shared `AppSupport` package for native menus, settings
  content, and version/build formatting. Native app menus, single-main-window
  Viewer Settings (a page in its main window), and resident Host Settings
  (retaining the menu-bar lifecycle) are implemented. Local evidence and
  cleanup are recorded in [UI Review and Post-test Cleanup](TESTING_CLEANUP.md)
  and the dated
  [UI review evidence](TESTING_CLEANUP.md#local-evidence-2026-09-26-021003).

Pending:

- The actual Intel-to-Apple-Silicon run, OS Accessibility/input evidence, and
  the physical two-machine acceptance remain environment gates until they are
  executed on both Macs; see [M10 acceptance](M10_ACCEPTANCE.md).
- The clock-synchronized performance report and the two-Mac
  clipboard/performance evidence remain unverified on this Apple Silicon
  workspace.
- The recorded local UI checks do not mark connected two-Mac UI acceptance
  complete: connected page switching (navigation/input release) and Host
  window lifecycle still require the physical acceptance rows.

#### 0.2.1008 input-source following

The user-approved M10 extension follows the Viewer's selected Chinese/English
input source using an optional negotiated capability. The Host applies a
desired state, never a toggle: English/English is a no-op, and Chinese requires
the exact enabled input method. Physical key delivery and Host-side IME
composition remain unchanged. See
[ADR-0007](decisions/0007-m10-input-source-following.md).

- Source selection retains the selected-window, permission, foreground,
  secure-input, session, and authorization-epoch admission checks.
- Viewer keyboard input waits for the matching acknowledgement. Pending work
  is bounded and invalidated across source changes, focus loss, window
  replacement, reconnect, and reauthorization; mouse input is independent.
- Missing sources and failed synchronization show a retry action. Settings
  can disable following for manual source selection; older peers use that
  manual behavior without receiving unsupported wire messages.
- Local verification: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  ./.codex/ci.sh` passed the architecture matrix, root/package tests, M8
  benchmark, and M9 ad-hoc packaging audit. The sandbox attempt stopped at
  SwiftPM manifest loading; the identical permitted-host retry passed.
  InputCore has 48 tests, RemoteProtocol 21, and TransportCore 72. After the
  final physical-modifier cleanup fix, root tests passed again, including
  20 Viewer lifecycle tests. The release flow repeated the full canonical
  validation against that final tree successfully before signing/notarization.
- Current-task Codex self-review covered the complete diff and directly
  relevant source-selection, input-delivery, lifecycle, and queue call paths.
  Review fixes cover first-scope synchronization, acknowledgement dispatch,
  stale epoch/request rejection, ordered key release on focus loss, and
  preserving physical modifier state through synthetic remote cleanup.
  No P0–P2 finding remained; this was not an independent Desktop/CLI or
  Claude review. A P3 UI limitation remains: the Settings-page retry action
  is inactive while the remote surface is unfocused. Returning to the remote
  view starts a fresh sync and its failure-state retry button works, so this
  redundant-action polish is deferred from the input-correctness release.
- Actual macOS input-source switching, Chinese composition, and the two-Mac
  keyboard/mouse walkthrough remain manual acceptance items. Third-party IME
  modes not exposed as macOS input sources are not claimed supported.

#### 0.2.1011 notarized RC

On 2026-10-13, the operator authorized the canonical `rc` release flow for
source commit `a63222e`. The Host and Viewer
bundle build numbers were advanced to `1011` for this release, yielding
Version `0.2`, Build `1011`. The flow used the configured Keychain-backed
Developer ID identity and shared API-key reference; no credentials were
copied into the repository or global configuration.

The canonical `rc` command ran with the installed Xcode toolchain and the
unique valid Developer ID Application identity resolved from Keychain. The
delivered rebuild refreshed the user guide included in both DMGs to name
`0.2.1011`. It passed deterministic CI, built a universal `x86_64 arm64` Host
and `arm64` Viewer, signed both apps and DMGs, and received `Accepted` for all
four Apple submissions. Stapling, ticket, signature, Gatekeeper, and M9
release-audit checks passed before the verified staging directory was
promoted to `build/rc/`.

| Artifact | Apple submission ID | Status |
| --- | --- | --- |
| Host app ZIP | `aeec0724-5eb6-4989-baa2-a09a6d26c915` | Accepted |
| Viewer app ZIP | `3b574772-a3ba-4f02-91fd-4df31d0943b8` | Accepted |
| Host DMG | `b6bfc339-1d23-459e-84c9-539459ef85da` | Accepted |
| Viewer DMG | `288e0ece-ef3b-40d3-8d74-6c169338a7eb` | Accepted |

| Delivered artifact | SHA-256 |
| --- | --- |
| `MacRemoteApp-Host-0.2.1011.dmg` | `8aacf0d80aa9ea1a0d5ca517a5ff9b3d7df7e69a746d51135ccbd98f405429a6` |
| `MacRemoteApp-Viewer-0.2.1011.dmg` | `d5f5c1f3ebcfe144d16d7d3ca84de39f36478cc6708e472999602bcbc24349a8` |
| `MacRemoteApp-Host-0.2.1011.app.zip` | `b403cadff68d0c9b8400cc983f803004009d747ff4984e8f00450e0ab29df1d5` |
| `MacRemoteApp-Viewer-0.2.1011.app.zip` | `8c64e36876e7d0bef2db40f9d50f2f082c9375ce815d2047c319f75b80958c2f` |

The same four checksums are in `build/rc/SHA256SUMS.txt`; verification with
`shasum -a 256 -c SHA256SUMS.txt` passed from that directory.

Log: `build/notarized-1011-release-attempt-5.log`. The successful flow
removed its documented build caches and superseded the prior `0.2.1010` RC
only after all final checks passed. P6 physical input/IME and V1 M10 two-Mac
acceptance remain operator-owned manual evidence; Apple acceptance does not
close them.

#### 0.2.1010 notarized RC (superseded)

On 2026-10-08, the operator authorized notarized DMG generation for source
commit `1e422da8799f183487276e2295008c6ebe499ec8`. The exact command was:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
MACREMOTEAPP_SIGNING_IDENTITY='Developer ID Application: chienchung Yu (LYK4LV2859)' \
bash scripts/release-notarized.sh rc
```

The canonical clean validation passed before signing. Both apps and DMGs
were Developer ID signed; all four Apple submissions were `Accepted`:

| Artifact | Apple submission ID | Status |
| --- | --- | --- |
| Host app ZIP | `0776ff03-4658-4425-b9df-fd875bb98543` | Accepted |
| Viewer app ZIP | `5adffff7-de2c-430d-ae75-4a358b8f3e08` | Accepted |
| Host DMG | `aa61ac31-0694-4bd6-ace0-bc2591b39f5f` | Accepted |
| Viewer DMG | `a06d0a60-95bb-41cd-b4ae-48ef8792da02` | Accepted |

The apps were stapled before rebuilding the shipped ZIPs and DMGs. Final
signature, mounted payload, archive equivalence, notarization-ticket, and
Gatekeeper checks passed, then the verified staging directory was promoted
to `build/rc/`. Both plists identify Version `0.2`, Build `1010`; Host is
universal `x86_64 arm64`, Viewer is `arm64`. The shared API-key reference was
used without copying credentials into the repository or changing global
configuration. No history preflight or credential probe was used.

| Delivered artifact | SHA-256 |
| --- | --- |
| `MacRemoteApp-Host-0.2.1010.dmg` | `29cdd8adf559dbc3420a64e57cc1a277615d54b91f5b04273625cdfe7de0e181` |
| `MacRemoteApp-Viewer-0.2.1010.dmg` | `ae315ba16bec5b8779a74668cf5deaa99df4536ebd63b0c33ef1bb0d60e00a2b` |
| `MacRemoteApp-Host-0.2.1010.app.zip` | `cc3e6540d75498d836f9f5785ec4968d86cd5a07c8ea5a52439c09f366680795` |
| `MacRemoteApp-Viewer-0.2.1010.app.zip` | `823eb6c91c7ccfe15791b1b846db503b4bb43fde139176d324b3d50e06f4b19e` |

Log: `build/notarized-1010-release.log`. The successful workflow removed only
its documented build caches and superseded the previous RC after validation.
P6 physical input/IME and V1 M10 two-Mac acceptance remain operator-owned
manual evidence; Apple acceptance does not close them.

#### 0.2.1009 notarized RC (superseded)

M10 user-facing packaging update created locally on 2026-10-04 with
`scripts/release-notarized.sh rc`, Xcode at
`/Applications/Xcode.app/Contents/Developer`, Developer ID signing, and the
existing Keychain profile. Both DMGs now include the unchanged executable
`Uninstall-MacRemoteApp.command`, its payload-manifest hash, the updated user
guide, and the older role-specific helpers. No credentials were copied into
the repository, and no live uninstall or permission reset was performed.

| Artifact | Apple submission ID | Result |
| --- | --- | --- |
| Host app | `72b90fe8-eaf0-421d-a300-54ed1bb2c808` | Accepted; stapled and Gatekeeper accepted |
| Viewer app | `49e64231-2a9b-4c54-bd0d-75294e396fea` | Accepted; stapled and Gatekeeper accepted |
| Host DMG | `cfed7775-c0b2-4120-bfaf-4949b047d307` | Accepted; stapled and Gatekeeper accepted |
| Viewer DMG | `3457b153-1c5e-429b-a1f2-4b40471cc9c1` | Accepted; stapled and Gatekeeper accepted |

Both bundle plists identify Version `0.2`, Build `1009`. Host remains universal
(`x86_64`/`arm64`) and Viewer remains `arm64`. The release workflow passed strict
signatures, hardened runtime, archive equivalence, read-only DMG payload/source
checks, notarization tickets, and Gatekeeper before promotion into `build/rc/`.

| Distributable in `build/rc/` | SHA-256 |
| --- | --- |
| `MacRemoteApp-Host-0.2.1009.dmg` | `e5983335fd61e4328880be1fc42746915b23071b9416908e93ea370b5abf3925` |
| `MacRemoteApp-Viewer-0.2.1009.dmg` | `08393632f6582178e587f6c844a0a59febae79de0c072fcb86705dfb398c956b` |

After the operator moved the original DMGs to Dropbox, identical-byte copies
were placed back in `build/rc/` with the versioned names above. The Dropbox
originals remain untouched. This filename-only change preserves the recorded
hashes and submitted content; the revised naming guidance in the source user
guide will be included on the next packaging run, not retroactively injected
into the existing signed DMGs.

The M10 artifact-naming follow-up derives `major.minor.build` from matching
Host/Viewer bundle metadata. Testing, beta, and RC DMGs/app archives include
that identity in their filenames; formal release filenames remain fixed.
The channel is carried explicitly through staging, and inconsistent channel
or malformed metadata is rejected. App bundles and installation identities
remain unchanged. On 2026-10-04 the required `.codex/ci.sh` passed, including
isolated naming fixtures, uninstaller fixtures, and actual versioned test-DMG
packaging/audit. Read-only Codex self-review of the complete pending diff and
the naming call sites found no actionable findings.

The versioned existing RC artifacts passed
`scripts/validate-notarized-release.sh build/rc`, including archive equivalence,
strict signatures, mounted payload checks, tickets, and Gatekeeper. Logs are
`build/versioned-artifact-validation.log` and
`build/versioned-1009-notarized-audit.log`. Initial sandbox checks stopped at
SwiftPM `sandbox_apply` and stapler's Launch Services file lookup; the same
checks passed in permitted host context. No new Apple submission, commit,
push, live uninstall, or physical two-Mac acceptance was performed for this
filename-only follow-up.

The required `.codex/ci.sh` passed on the final code tree, including all 18
isolated uninstaller fixtures and mounted DMG checks; the release workflow's
additional clean validation also passed. The initial host validation had three
TransportCore failures (input-source admission, queued-input revocation, and
one-sided pairing bootstrap). All three passed their focused recheck, followed
by the complete passing run; this records intermittent failures, not a claim
that their underlying timing was fixed. The Codex sandbox attempt stopped at
SwiftPM `sandbox_apply`; the same validation was rerun in host context.

Logs remain ignored under `build/`: `dmg-uninstaller-1009-validation.log`,
`dmg-uninstaller-1009-transport-recheck.log`,
`dmg-uninstaller-1009-final-validation.log`, `release-0.2.1009.log`, and
`notarized-0.2.1009-final-audit.log`. The final read-only
`scripts/validate-notarized-release.sh build/rc` recheck passed after promotion.
The selected RC channel was replaced only after successful verification; the
workflow cleared its project-local build cache. Installed apps, settings,
Keychain records, and TCC permissions were not changed. Physical two-Mac
acceptance and a real uninstall walkthrough remain unverified.

#### 0.2.1008 notarized RC

Created locally on 2026-10-04 using the existing
`scripts/release-notarized.sh rc` workflow, Xcode at
`/Applications/Xcode.app/Contents/Developer`, Developer ID signing, and the
existing Keychain profile. The final code tree passed the workflow's clean
canonical validation before signing. No credential material was copied into
the repository, and no apps were installed during this release.

| Artifact | Apple submission ID | Result |
| --- | --- | --- |
| Host app | `43f7e265-0758-4ef6-8f0f-66f79946f3b3` | Accepted; stapled and Gatekeeper accepted |
| Viewer app | `1ee8c1f7-3920-440e-afa5-605802e85bce` | Accepted; stapled and Gatekeeper accepted |
| Host DMG | `90b07b1e-bdbb-43cb-bb65-e209f34afe16` | Accepted; stapled and Gatekeeper accepted |
| Viewer DMG | `f60ce944-1cd9-423f-8cbf-227d263cae95` | Accepted; stapled and Gatekeeper accepted |

`scripts/validate-notarized-release.sh` passed strict signatures, hardened
runtime, role metadata, archive equivalence, DMG payload, ticket, and
Gatekeeper checks before atomic promotion into `build/rc/`. Both bundle
plists contain Version `0.2`, Build `1008`; the Host is universal
(`x86_64`/`arm64`) and the Viewer is `arm64`.

| Distributable in `build/rc/` | SHA-256 |
| --- | --- |
| `MacRemoteApp-Host.dmg` | `c05b63f5886959034f200f468d42d1c1ab4e68844e267748bda9679bb97439c8` |
| `MacRemoteApp-Viewer.dmg` | `8c49cd99bbf5d87323185291f924d60c033cfb8e8ea994defbefd39dcb189b46` |

After verification, the old `0.2.1007` RC payload and its two build logs were
moved into the recoverable local Trash directory
`MacRemoteApp-0.2.1007.nV1ka0/`. A filesystem audit found no remaining `1007`
release payload under `build/` or `.build`. The original build cache was
restored, and existing beta/release DMG checksums are unchanged. Installed
apps, preferences, Keychain trust/identities, TCC grants, and other versions
were not reset or removed. New logs and generated artifacts remain ignored.
The historical `1007` submission evidence below is retained as a release record.

Both endpoints must use the updated build to negotiate source following.
Real Chinese/English switching, composition/candidate panels, and physical
Intel-to-Apple-Silicon input remain pending in [M10 acceptance](M10_ACCEPTANCE.md).

#### Post-0.2.1006 reliability review

This M10 source review stays within the existing V1 contract; it does not add
wire messages or post-V1 features. Its changes are included in the
`0.2.1007` notarized RC, not the earlier `0.2.1006` DMGs.

- Capture teardown is generation-bound: a delayed stop or failure from the
  previous engine cannot clear a replacement selection or end its frame
  stream. Both races were reproduced before the fix; CaptureCore's 23 tests
  pass afterward, with the live ScreenCaptureKit check still opt-in/skipped.
- Optional keyframe requests and receiver reports now share the protected
  queue invalidation rule. Old envelope entries become sequence-preserving
  tombstones; decoded old messages are removed. Three regression tests
  reproduced the omission and pass after the fix; the 14 clipboard tests
  and the authorization-invalidation regression also pass.
- Input admission can require the authorization epoch observed when an event
  was queued, so reauthorizing the same window cannot grant an old event a
  new token. The regression also verifies that fresh input arrives unchanged.
- Precise scroll deltas retain per-axis fractional remainder rather than
  rounding every small event to zero; readiness/window changes reset the
  remainder. InputCore's 41 tests and TransportCore's 68 tests pass.
- The bounded encoder relay marks the first accepted frame after a drop.
  Earlier buffered keyframes cannot clear recovery for a later gap; only a
  post-gap keyframe resumes dependent deltas. Three Host relay regressions
  pass, including concurrent producer coverage, and the pre-fix recovery
  behavior reproduced the failure.
- Viewer input now uses a bounded single-consumer FIFO tied to the original
  session, authorization epoch, and window generation. Scope changes discard
  old queued work; saturation closes the affected session instead of silently
  losing key/button releases. Settings navigation within the same scope keeps
  ordered releases intact.
- Viewer decode/drawable callbacks carry an app-local presentation lifetime,
  in addition to session and authorization checks; stream invalidation clears
  the retained image to black. H.264 capability revocation is checked even if
  other capabilities remain authorized. Connection attempts are serialized,
  and old callbacks cannot reset a replacement session. The Viewer rebuild
  and nine deterministic lifecycle tests pass; these do not exercise a real
  Metal drawable or the desktop.
- Final self-review fixes keep automatic-retry cleanup visibly Reconnecting
  with disabled controls before awaiting teardown, guarded by all original
  owners. Older authorization snapshots are rejected without applying their
  readiness/video/failure state; a replacement session may restart at a lower
  epoch. The added regressions cover blocked teardown and late snapshot order.

Local verification on 2026-10-04: the final source passes
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./.codex/ci.sh`,
including Host `arm64`/`x86_64`, Viewer `arm64`, root/package tests, the M8
deterministic benchmark, and the M9 ad-hoc packaging audit. The first attempt
stopped at the SwiftPM sandbox boundary; the same validation in permitted host
context passed, including a repeat after the final review fixes. Network.framework
loopback TLS, ScreenCaptureKit, and VideoToolbox system smokes remain opt-in
skips in this source-review run. No apps were installed during the review or
release; Apple signing/notarization evidence is recorded below.
The final current-task Codex self-review covered the staged/unstaged/untracked
diff and the relevant input, capture, transport, and presentation call paths;
after the two review fixes, no further actionable finding remained. This was
a self-review, not an independent Desktop/CLI or Claude review.

The expanded physical recovery rows in [M10 acceptance](M10_ACCEPTANCE.md)
remain unchecked until exercised on the target pair.

#### 0.2.1007 notarized RC

Released locally on 2026-10-04 from source commit `5cdb321`, pushed to
`origin/main`. The authorized release used the existing
`scripts/release-notarized.sh rc` flow with Xcode at
`/Applications/Xcode.app/Contents/Developer`, Developer ID signing, and the
existing Keychain profile. No signing material was copied into the repository.
The flow repeated deterministic validation from a clean build cache before
signing, then promoted the staging payload only after all checks passed.

| Artifact | Apple submission ID | Result |
| --- | --- | --- |
| Host app | `0a677fdd-3a2f-4038-b409-a815c6a6ad05` | Accepted; stapled and Gatekeeper accepted |
| Viewer app | `c5ca1061-eed2-4a12-bc67-647fbd2c455d` | Accepted; stapled and Gatekeeper accepted |
| Host DMG | `6b04a07d-8297-40ad-bc85-901f18a03b75` | Accepted; stapled and Gatekeeper accepted |
| Viewer DMG | `d5c6f13e-acf3-41c9-9b3c-5b6a904c4a0c` | Accepted; stapled and Gatekeeper accepted |

`scripts/validate-notarized-release.sh` passed strict signature, hardened
runtime, role metadata, archive equivalence, DMG payload, notarization-ticket,
and Gatekeeper checks. Both app plists contain Version `0.2` and Build `1007`;
the Host is universal (`x86_64`/`arm64`) and the Viewer is `arm64`.

| Distributable in `build/rc/` | SHA-256 |
| --- | --- |
| `MacRemoteApp-Host.dmg` | `a7e60c27aab66b1d95ef91882a42cadad8c1e1d54059e05756234d57802ffd7f` |
| `MacRemoteApp-Viewer.dmg` | `94373dcfde9c86d0aabf478d3f57906fee7375d793aa9e1ca1d915b9cdce90d7` |

The previous `0.2.1006` RC is preserved in the checkout-local
`build/rc-build1006.M2caBo/payload/`. The original 1.9 GB `.build` cache was
moved aside and restored; existing beta/release DMG checksums are unchanged.
No apps were installed, and no app settings, trust records, identities, or TCC
grants were reset. Logs and generated artifacts remain ignored, not committed.
This release does not resolve the physical two-Mac evidence gaps above.

The intentionally deferred capabilities are listed in
[the post-V1 roadmap](POST_V1_ROADMAP.md).

## Open evidence gaps

Consolidated from the milestone detail above; none of these is verified:

1. Physical Intel Host to Apple Silicon Viewer Bonjour/TLS interoperability
   (M2 harness: [M2 physical smoke](M2_PHYSICAL_SMOKE.md)).
2. Screen Recording and live-capture evidence on machines other than the
   current M5 (M3).
3. Real OS event posting against a disposable test app (M6): foreground legacy
   behavior and Host-authorized inactive-app P6 behavior, including required
   Accessibility safety inspection on both Macs (M10).
4. Two-machine clipboard walkthrough (M7).
5. Clock-synchronized p50/p95 latency and 1080p/60 report from the physical
   run (M8, attached at M10).
6. Connected Viewer Settings navigation with held-input release, and Host
   window lifecycle, on the physical pair (M10).
7. Deployment-specific key handling: reinstall/rotation behavior,
   locked-Keychain failure, and access-control configuration
   ([ADR-0002](decisions/0002-m2-tls-identity-and-pairing.md)).
