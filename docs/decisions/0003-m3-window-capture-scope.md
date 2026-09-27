# ADR-0003: M3 window capture scope and generations

- Milestone: M3
- Status: Accepted
- Extracted from: `docs/ARCHITECTURE.md` ("M3 decisions")

## Context

`CaptureCore` must request the smallest permitted ScreenCaptureKit scope and
stop or degrade safely when the window disappears, permission is revoked, or
the selected window becomes ineligible (see
[Capture path](../ARCHITECTURE.md#capture-path)). V1 forbids whole-desktop
capture as an unrequested fallback.

## Decision

- The Host uses ScreenCaptureKit's desktop-independent-window filter and does
  not fall back to whole-display capture.
- Window discovery requires Screen Recording authorization, an on-screen
  zero-layer window, a non-empty application bundle identifier, and positive
  bounds. Titles remain optional metadata and are not treated as credentials.
- `WindowCaptureSession` assigns a new generation per selection, accepts only
  matching window/generation frames, and uses a bounded newest-frame output.

## Consequences

- Permission loss, window disappearance, capture error, EOF, or cancellation
  invalidates the active capture before later codec or transport work.
- Windows without a bundle identifier, off-screen, or with non-zero layers are
  not offered for selection.
