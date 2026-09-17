# MacRemoteApp Development Plan

## Plan status

This plan breaks the product into M0-M10 milestones. Each milestone has one
primary outcome, explicit boundaries, exit criteria, and verification work. A
milestone is complete only when its exit criteria and tests are satisfied or a
documented exception is explicitly accepted by the user.

The current repository contains only the planning package. M0 is the next
implementation task and must remain a repository-foundation task.

## Delivery principles

- Implement one milestone at a time.
- Read the complete planning package before coding.
- Keep Host, Viewer, and shared package boundaries explicit.
- Use test doubles for capture, network, codec, Keychain, and Accessibility
  dependencies where a live macOS capability is not available in CI.
- Prefer deterministic local tests before two-machine integration tests.
- Measure performance instead of describing it as "low latency" without
  evidence.
- Stop input first whenever authorization, focus, permission, or session health
  is uncertain.
- Do not add out-of-scope features as shortcuts or future-proofing.

## Dependency overview

```text
M0 Foundation
  -> M1 Protocol
  -> M2 Secure LAN session
  -> M3 Host capture
  -> M4 Codec and presentation
  -> M5 Viewer input
  -> M6 Host input injection
  -> M7 Clipboard and session UX
  -> M8 Performance and resilience
  -> M9 Security hardening and release readiness
  -> M10 V1 integration pilot
```

M3 and M4 may have limited parallel investigation after M2, but their
integration gate remains ordered. M5 must not claim end-to-end control until
M6 validates Host-side authorization and injection.

## M0 — Repository Foundation

### Scope

- Establish the repository/project format for Swift 6 and the recorded macOS
  deployment target.
- Create the minimum Host, Viewer, and six shared package/module skeleton.
- Create deterministic build/test validation, including `.codex/ci.sh` when
  appropriate.
- Add smoke tests that prove the skeleton compiles/imports without invoking any
  product capability.
- Record Intel Host and Apple Silicon Viewer build assumptions and any
  environment limitations.

### Explicit non-scope

No ScreenCaptureKit, VideoToolbox, Metal rendering, Network.framework session,
CoreGraphics/Accessibility injection, clipboard sync, pairing implementation,
or product UI behavior.

### Exit criteria

- A clean checkout can build the foundation with the documented toolchain.
- Host and Viewer targets/modules exist and are clearly separate.
- All six shared package boundaries exist and are testable.
- Validation is deterministic and does not require secrets, paid services, or
  a live remote machine.
- The deployment target and architecture matrix are documented as verified or
  explicitly pending.

### Tests and verification

- Run the executable `.codex/ci.sh` or the documented equivalent.
- Build and test on the available architecture; record the unavailable
  architecture as a gap rather than implying it passed.
- Confirm no forbidden product API or feature was added by inspecting the diff
  and dependency graph.

## M1 — RemoteProtocol foundation

### Scope

- Define the versioned envelope, channel identifiers, message types, schemas,
  bounds, error codes, and capability identifiers from `docs/PROTOCOL.md`.
- Implement serialization/deserialization contracts and incremental frame
  parsing with strict length/sequence validation.
- Produce golden vectors for stable messages and document the canonical wire
  encoding.

### Explicit non-scope

No live sockets, Bonjour, TLS, window capture, codec, input injection, or
clipboard side effects.

### Exit criteria

- Valid messages round-trip deterministically.
- Truncated, oversized, malformed, stale, and unsupported mandatory messages
  fail safely and predictably.
- Golden vectors and version/capability behavior are checked into tests.
- Protocol types contain no direct Swift UI, socket, or platform-capture
  dependency.

### Tests and verification

- Unit tests for every stable envelope/message family.
- Property/fuzz-style tests for bounded parsing and unknown optional fields.
- Tests for duplicate/out-of-order sequences, length overflow, and maximum
  clipboard payload handling.
- Run build, unit tests, and the repository validation script.

## M2 — Secure LAN discovery and session

### Scope

- Implement Bonjour discovery and Network.framework connection lifecycle.
- Implement TLS-backed peer authentication, pairing bootstrap, trust-record
  storage through `SecurityCore`, and capability/session negotiation.
- Implement explicit session state transitions, heartbeat, safe teardown, and
  reconnect that reauthorizes before input.

### Explicit non-scope

No video frames, capture, input injection, clipboard transfer, Internet relay,
or WebRTC.

### Exit criteria

- A Host and Viewer can discover and establish a protected test session on the
  LAN using the documented pairing flow.
- Identity mismatch, pairing denial, malformed handshake, timeout, and
  reconnect all fail closed.
- Control and media queue ownership is isolated enough to prevent video from
  starving authorization/input messages.
- Trust records and revocation behavior are documented and tested.

### Tests and verification

- Protocol/session tests using in-memory transport doubles.
- Two-process or two-machine LAN smoke test when available.
- Tests for TLS/configuration failure, wrong peer identity, stale trust,
  replay/freshness, heartbeat timeout, and reconnect authorization.
- Verify no protected content is sent before authorization.

## M3 — Host window discovery and capture

### Scope

- Enumerate eligible applications/windows on the Host.
- Add Screen Recording permission state and user-guided permission flow.
- Capture only one selected window through ScreenCaptureKit.
- Propagate window identity, geometry, timestamps, lifecycle, and permission
  changes to the session layer.

### Explicit non-scope

No H.264 encoding, Viewer rendering, remote input injection, clipboard sync,
whole-desktop default capture, background/locked-screen control.

### Exit criteria

- The Host can list eligible windows and start/stop capture for one selection.
- Window close, selection change, permission loss, and capture failure cancel
  the capture safely and produce explicit state.
- Capture output is bounded and testable with a fake capture provider.
- No whole-desktop capture is introduced as an unrequested fallback.

### Tests and verification

- Unit tests using fake window/capture providers.
- Manual Host test with Screen Recording permission granted and revoked.
- Verify selected-window identity changes and lifecycle cancellation.
- Record actual supported OS/hardware behavior separately from mocked tests.

## M4 — H.264 codec and Metal presentation

### Scope

- Wrap VideoToolbox compression/decompression in `CodecCore`.
- Define H.264 configuration, keyframe, timestamp, generation, and bounded
  frame contracts.
- Add Viewer Metal presentation with aspect-ratio and resize correctness.
- Connect a local capture fixture or synthetic frame source to a local
  encode/decode/display path.

### Explicit non-scope

No remote input, clipboard, Internet transport, audio, HEVC, or multi-window
presentation.

### Exit criteria

- A known frame fixture can be encoded, decoded, and presented with validated
  dimensions/timestamps.
- Decoder reset, missing config, stale generation, and keyframe recovery are
  handled safely.
- Encoder/decoder queues are bounded and cancellation works.
- H.264 profile and rate-control defaults are documented.

### Tests and verification

- Codec unit tests with deterministic fixtures and metadata assertions.
- Corrupt/truncated access-unit and stale-generation tests.
- Manual Metal presentation test for aspect ratio, resize, and frame pacing.
- Memory/queue observations demonstrate no unbounded frame accumulation.

## M5 — Viewer interaction and input transport

### Scope

- Capture Viewer pointer, button, scroll, keyboard, and modifier events in the
  remote-content surface.
- Normalize coordinates and create the typed `InputEvent` protocol records.
- Deliver events through the authenticated control path with ordering,
  rate/size limits, and visible input-ready state.

### Explicit non-scope

No Host-side event injection yet, no background control, no secure-input
handling, no clipboard, and no arbitrary serialized `CGEvent` transport.

### Exit criteria

- Viewer events are normalized against the displayed remote-content rectangle.
- Viewer disables input when the session is not authenticated/authorized or
  the stream/content surface is unavailable.
- Event ordering, modifiers, coordinate bounds, and rate limits are tested.
- Host test doubles can receive and inspect typed input records without
  injecting them into the OS.

### Tests and verification

- Unit tests for coordinate transforms, resize, button/key state, modifiers,
  and scroll normalization.
- Tests for disabled states, invalid events, duplicate sequences, and queue
  backpressure.
- Manual Viewer test with a local synthetic stream fixture.

## M6 — Host focus-aware input injection

### Scope

- Implement Host-side InputCore mapping and the CoreGraphics/Accessibility
  adapter.
- Require current session authorization, selected-window generation, required
  permission, and foreground/focus eligibility before each injection.
- Add explicit failure states and stop-input behavior for window/focus/
  permission changes.

### Explicit non-scope

No background/unfocused control, locked-screen control, secure-input bypass,
system authentication-dialog automation, or privilege escalation.

### Exit criteria

- Authorized pointer, button, scroll, keyboard, and modifier events affect
  only the selected eligible foreground window.
- Losing permission, focus, window identity, or session state disables/rejects
  input immediately and visibly.
- No arbitrary event archive or unvalidated remote event reaches the OS API.

### Tests and verification

- Unit tests with fake injection adapters and authorization matrices.
- Manual test against a safe test application for pointer and keyboard events.
- Tests for permission revocation, focus loss, stale window generation,
  malformed events, and reconnect.
- Verify secure-input and locked-screen scenarios are rejected/documented.

## M7 — Text clipboard and session UX

### Scope

- Implement opt-in, text-only clipboard synchronization with bounded UTF-8
  payloads, origin/generation tracking, acknowledgements, and conflict policy.
- Complete Host/Viewer session status, permission, pairing, input, clipboard,
  stream, error, stop, and reconnect UX.
- Add user-facing trust revocation affordance if required by the M2 design.

### Explicit non-scope

No image/file/rich-text transfer, file promises, cloud sync, analytics, or
unbounded clipboard history.

### Exit criteria

- Clipboard sync is disabled by default and clearly enabled/disabled per
  session.
- Text transfers respect size bounds and do not echo indefinitely.
- Disconnect clears transient transfer state and disables sync/input.
- UI states accurately distinguish discovered, paired, authenticated,
  authorized, streaming, input-ready, clipboard-enabled, degraded, and failed.

### Tests and verification

- Unit/integration tests for opt-in, text encoding, size limit, acknowledgement,
  origin loop prevention, near-simultaneous edits, and disconnect.
- Log audit proves clipboard content and sensitive input are not emitted.
- Manual UX walkthrough covering permission denial and recovery.

## M8 — Performance and resilience

### Scope

- Build the documented benchmark harness and measure capture-to-display and
  input latency, frame rate, dropped/superseded frames, CPU/GPU/memory, and
  reconnect behavior.
- Tune bounded queues, frame pacing, bitrate/rate control, and cancellation.
- Test LAN interruption, slow Viewer, Host load, stream reset, and codec
  recovery.
- Evaluate an alternate Network.framework media binding only if baseline data
  shows the need; record the decision and compatibility impact.

### Explicit non-scope

No WebRTC, Internet relay, NAT traversal, audio, or unmeasured speculative
optimization.

### Exit criteria

- Benchmarks report p50/p95 latency under documented conditions.
- The 1080p/60 fps target and 30 fps fallback are measured as pass, partial, or
  fail with evidence.
- No tested slow-peer condition causes unbounded memory growth or unsafe input.
- Reconnect and keyframe recovery are visible, bounded, and reauthorized.

### Tests and verification

- Repeatable benchmark runs on the documented Intel Host and Apple Silicon
  Viewer where available.
- Fault-injection tests for packet/stream interruption, queue saturation,
  malformed frames, codec reset, and permission change.
- Capture resource and latency reports as release artifacts, excluding private
  pixels and clipboard text.

## M9 — Security hardening and release readiness

### Scope

- Complete threat-model review against `docs/SECURITY.md`.
- Audit TLS/trust/pairing, Keychain use, authorization gates, permission
  handling, parser limits, rate limits, logging redaction, and revocation.
- Review dependencies, build configuration, entitlements, signing/notarization
  requirements, and user-facing security documentation.
- Resolve validated security findings and document residual risks.

### Explicit non-scope

No new product feature or scope expansion under the label of hardening.

### Exit criteria

- Security checks and negative tests pass for every protected capability.
- No known P0/P1 security issue remains; lower-risk exceptions are documented
  with owner and mitigation.
- Release builds do not enable debug capture, unsafe logging, test trust, or
  development bypasses.
- Permissions, trust revocation, data handling, and V1 non-goals are explained
  in user-facing documentation.

### Tests and verification

- Repeat parser fuzz/boundary tests and malformed-peer tests.
- Pairing mismatch, replay/freshness, unauthorized input, permission revoke,
  clipboard redaction, and reconnect tests.
- Inspect entitlements, signing configuration, dependencies, and release logs.
- Run the full deterministic validation suite and record environment gaps.

## M10 — V1 integration pilot and acceptance

### Scope

- Run the complete Intel Host to Apple Silicon Viewer workflow on the same LAN.
- Validate pairing, one-window selection, 1080p/60 target/fallback, display,
  mouse, keyboard, text clipboard, disconnect/reconnect, and failure UX.
- Finalize support matrix, operator documentation, known limitations, and
  release checklist.

### Explicit non-scope

No feature additions beyond the accepted V1 specification. Any new request
becomes a post-V1 milestone proposal.

### Exit criteria

- Product acceptance checklist in `docs/PRODUCT_SPEC.md` is complete or every
  exception is explicitly recorded.
- M8 performance evidence and M9 security evidence are attached to the release
  decision.
- The support matrix identifies verified, unverified, and unsupported
  hardware/OS combinations.
- A clean build/release candidate can be installed and operated using the
  documented steps.
- Known limitations do not contradict the product scope or imply unsupported
  remote-desktop behavior.

### Tests and verification

- Full two-machine integration test with a safe test application.
- Repeat acceptance after a clean install and fresh pairing.
- Test permission denial/revocation, window close/change, LAN interruption,
  stale trust, unsupported capability, clipboard opt-out, and input disable.
- Run final build/test/security/release validation and archive only sanitized
  evidence.

## Milestone completion report format

Each milestone handoff should include:

```text
Milestone: M<number> — <name>

Changed files:
- <path> — <purpose>

Exit criteria:
- [pass|partial|blocked] <criterion>

Validation:
- <exact command> — <result>

Verified:
- <hardware/OS/environment facts>

Open gaps and decisions:
- <item or "none">

Scope check:
- No later milestone or V1 out-of-scope feature was added.
```
