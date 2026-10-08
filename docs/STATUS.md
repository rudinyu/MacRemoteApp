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

Current source metadata is `0.2.1010`; the retained notarized RC remains
`0.2.1009`. The source contains the separately authorized
[P6 Host-controlled input extension](P6_BACKGROUND_CONTROL.md), whose local
completion and physical evidence are tracked separately from V1 below.

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
| M9 | Release-audit gate implemented; current `0.2.1009` notarized RC artifacts verified | Notarization profile remains host-specific |
| M10 | Production composition, final gate, pairing UI, and checklist implemented | Physical Intel-to-Apple-Silicon acceptance, including connected UI rows |

## Authorized source follow-ups (2026-10-08)

- **P6 / M6 input extension:** complete the existing Host-controlled
  process-input path under [the P6 contract](P6_BACKGROUND_CONTROL.md).
  Implementation and the canonical local gate passed. The grant coordinator
  has 12 passing regressions, including pending revocation across session
  replacement; transport tests cover stale control generations while video
  remains authorized. Legacy peers retain foreground control. This is separate
  from V1 M10 physical acceptance and is not included in the retained
  `0.2.1009` RC.
- **M9 signing adapter:** both canonical release entry points now resolve the
  shared owner-only Codex configuration, preserve explicit project profile
  overrides, and support the existing external API-key reference. Focused
  synthetic configuration fixtures and Bash syntax checks passed; no Developer
  ID signing or Apple submission was performed.

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
No commit, push, release promotion, global configuration change, or additional
post-V1 feature was performed.

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
  documented disposable foreground test application and PostEvent permission.
  On an explicit Viewer window selection, Accessibility can also provide a
  best-effort exact-window raise when geometry uniquely matches; missing or
  ambiguous matches remain blocked by the independent foreground check.
  Accessibility is optional for secure-input inspection, and a detected
  secure field remains fail-closed.

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
- The current `0.2.1009` RC apps and DMGs are Developer ID signed, Apple
  notarized, stapled, and verified; both DMGs include the full-cleanup helper,
  alongside input-source following and the reliability fixes below.
  The notarization profile remains host-specific. See the
  [release evidence](#021009-notarized-rc).

### M10 — V1 integration pilot

2026-10-08 handoff: `0.2.1010` implementation and canonical local validation
are complete, and source commit `1038419` was pushed to `origin/main`.
The operator explicitly owns manual physical acceptance. The updated
[M10 checklist](M10_ACCEPTANCE.md) identifies the current P6 behavior,
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
- The eligible window catalog refreshes during active sessions; an explicitly
  selected regular app is foregrounded while per-event input gates are
  retained. The Viewer exposes truthful connection-button states, and both
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

#### 0.2.1009 notarized RC

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
3. Real OS event posting against a disposable foreground test application
   (M6), and OS Accessibility/input evidence on both Macs (M10).
4. Two-machine clipboard walkthrough (M7).
5. Clock-synchronized p50/p95 latency and 1080p/60 report from the physical
   run (M8, attached at M10).
6. Connected Viewer Settings navigation with held-input release, and Host
   window lifecycle, on the physical pair (M10).
7. Deployment-specific key handling: reinstall/rotation behavior,
   locked-Keychain failure, and access-control configuration
   ([ADR-0002](decisions/0002-m2-tls-identity-and-pairing.md)).
