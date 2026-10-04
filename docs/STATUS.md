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
| M9 | Release-audit gate implemented; existing `0.2.1006` notarized RC artifacts verified | Notarization profile remains host-specific; subsequent source fixes need a new release |
| M10 | Production composition, final gate, pairing UI, and checklist implemented | Physical Intel-to-Apple-Silicon acceptance, including connected UI rows |

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
- The existing `0.2.1006` RC artifacts are signed, notarized, and verified. The
  authorized `0.2.1007` release candidate includes the reliability fixes below;
  its signing/notarization remains pending until the release flow succeeds.
  Until then, `build/rc/` still contains `0.2.1006`. The notarization profile
  remains host-specific.

### M10 — V1 integration pilot

Implemented:

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

#### Post-0.2.1006 reliability review

This M10 source review stays within the existing V1 contract; it does not add
wire messages or post-V1 features. Its changes are included in the
`0.2.1007` release candidate, not the existing `0.2.1006` DMGs.

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
skips in this source-review run. No apps were installed during the review;
Apple signing/notarization for `0.2.1007` is a subsequent authorized step.
The final current-task Codex self-review covered the staged/unstaged/untracked
diff and the relevant input, capture, transport, and presentation call paths;
after the two review fixes, no further actionable finding remained. This was
a self-review, not an independent Desktop/CLI or Claude review.

The expanded physical recovery rows in [M10 acceptance](M10_ACCEPTANCE.md)
remain unchecked until exercised on the target pair.

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
