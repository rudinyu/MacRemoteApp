# MacRemoteApp Agent Instructions

## Repository status

This repository is currently a planning package. It intentionally contains no
product implementation code. The first implementation task is M0, which may
create the repository skeleton and build/test scaffolding but must not add
capture, encoding, networking, input injection, or clipboard behavior.

## Required reading before any change

Before making a change, read the following files in this order:

1. `README.md`
2. `docs/PRODUCT_SPEC.md`
3. `docs/ARCHITECTURE.md`
4. `docs/PROTOCOL.md`
5. `docs/SECURITY.md`
6. `docs/DEVELOPMENT_PLAN.md`

Then identify the single milestone that owns the requested work. If the user
gives a newer or more specific instruction, follow it while preserving the
scope and safety rules below.

## Milestone discipline

- Every implementation change must name exactly one milestone, `M0` through
  `M10`, in its task description and completion report.
- Work on one milestone at a time. Do not combine a later milestone's feature
  with the current milestone for convenience.
- If a request spans multiple milestones, split it into explicit follow-up
  tasks and complete only the currently authorized milestone.
- Use the milestone's scope, exit criteria, and verification items in
  `docs/DEVELOPMENT_PLAN.md` as the definition of done.
- Keep unresolved design choices visible in the relevant document; do not hide
  them in code or silently choose a speculative feature.

## Architecture boundaries

The planned product has two applications and six shared packages:

- `Apps/Host`
- `Apps/Viewer`
- `Packages/RemoteProtocol`
- `Packages/CaptureCore`
- `Packages/CodecCore`
- `Packages/TransportCore`
- `Packages/InputCore`
- `Packages/SecurityCore`

Respect the responsibility and dependency boundaries in
`docs/ARCHITECTURE.md`. In particular:

- `RemoteProtocol` owns wire types, framing, versioning, and message codecs;
  it must not depend on AppKit UI, ScreenCaptureKit, or CoreGraphics event
  injection.
- `TransportCore` owns Network.framework connections, discovery, framing
  delivery, backpressure, and reconnect state; it must not own product UI.
- `CaptureCore` owns host-side window discovery and capture orchestration; it
  must not own the wire protocol.
- `CodecCore` owns VideoToolbox encode/decode and codec configuration; it must
  not decide which window is selected.
- `InputCore` owns the platform-neutral event model and host-side mapping/
  injection adapters; it must enforce the permission and focus rules.
- `SecurityCore` owns identities, pairing records, authentication policy, and
  security-sensitive validation; it must not bypass user consent.
- `Apps/Host` and `Apps/Viewer` compose the packages and own app-specific UI,
  lifecycle, and user-facing permission flows.

Do not introduce a new shared package, third-party dependency, or alternate
transport without documenting the reason and updating the architecture and
security documents in the same milestone.

## Product constraints

The V1 product is a LAN-first remote view/control tool for one selected macOS
application window:

- Host: Intel Mac.
- Viewer: Apple Silicon Mac.
- Stack: Swift 6, ScreenCaptureKit, VideoToolbox, Metal, Network.framework,
  CoreGraphics, and Accessibility APIs.
- V1 interaction: mouse, keyboard, and text clipboard.
- Target: 1080p, up to 60 fps, with low end-to-end latency; the measurable
  target and test method are defined in `docs/PRODUCT_SPEC.md` and
  `docs/DEVELOPMENT_PLAN.md`.
- V1 is LAN-only and does not include WebRTC, Internet NAT traversal, audio,
  file transfer, iPad support, simultaneous multi-window control,
  background control, or locked-screen control.

Out-of-scope behavior must not be implemented as a hidden convenience or as a
"temporary" fallback. If a later feature would affect an existing boundary,
record it as a design decision before coding it.

## Security and privacy rules

- Never commit credentials, private keys, pairing secrets, personal data, or
  captured media.
- Never accept remote input before the session is authenticated, paired, and
  authorized for the selected window.
- Do not weaken Screen Recording or Accessibility permission checks to make a
  test pass.
- Treat Bonjour discovery metadata as untrusted input.
- Redact clipboard contents, window titles when sensitive, tokens, and raw
  input values from logs.
- Keep trust records in the platform Keychain through `SecurityCore`; do not
  invent an insecure file-based secret store.
- Preserve the explicit V1 rule that the selected app must be foreground/
  eligible for control. Do not add background or locked-screen control.

## Validation workflow

Before editing:

1. Inspect the current working tree and existing validation scripts.
2. Read the required documents above.
3. State the milestone and the acceptance criteria being addressed.

After editing:

1. Run the repository's executable `.codex/ci.sh` when it exists.
2. Otherwise run the narrowest deterministic build and tests required by the
   current milestone, then broaden checks when the milestone requires it.
3. For documentation-only changes, validate required files, internal links,
   headings, and milestone identifiers; do not claim a product build passed.
4. Review the final diff for scope leakage, accidental secrets, and unrelated
   changes.
5. Report the exact checks run, their result, and any environment limitation.

Do not commit, push, publish, or change global Codex configuration unless the
user explicitly asks for that action.

## Completion report

Every milestone task must end with a concise report containing:

- the milestone completed;
- changed files and their purpose;
- requirements or exit criteria satisfied;
- exact build/test/validation commands and results;
- known gaps, deferred decisions, and the next milestone;
- confirmation that no out-of-scope features were added.
