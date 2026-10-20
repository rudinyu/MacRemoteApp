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
- Window discovery requires Screen Recording authorization, a zero-layer
  window, a non-empty application bundle identifier, and positive bounds.
  On-screen windows qualify as before. Since the 2026-10-20 amendment below,
  offscreen windows also qualify when they have a non-empty title and belong
  to a regular (`NSApplication.ActivationPolicy.regular`) app. Titles remain
  optional metadata and are not treated as credentials.
- `WindowCaptureSession` assigns a new generation per selection, accepts only
  matching window/generation frames, and uses a bounded newest-frame output.

## Consequences

- Permission loss, window disappearance, capture error, EOF, or cancellation
  invalidates the active capture before later codec or transport work.
- Windows without a bundle identifier, with non-zero layers, or offscreen
  without a title or outside a regular app are not offered for selection.

## Amendment (2026-10-20): background windows

Physical Build 1036 testing found that apps in the background could not be
selected at all: the catalog listed only on-screen windows, and on the test
Host only one regular-app window was on screen at a time (others were
minimized, hidden, or on other Spaces / full-screen Spaces). The Build 1035
Host log shows 0–2 eligible windows per discovery.

- The catalog now queries the full ScreenCaptureKit window list and also
  offers titled offscreen windows of regular apps. Untitled offscreen windows
  and offscreen windows of agent/accessory apps stay excluded because they
  are commonly invisible utility surfaces.
- Each `CaptureWindow` records `isOnScreen`. Selecting an offscreen window is
  an explicit Viewer selection, so the Host runs the same bounded reveal and
  activation used for foreground restore before capture starts. That request
  never authorizes input by itself.
- Privacy: the paired, authenticated Viewer now also receives titles of
  offscreen windows of regular apps, the same metadata class it already
  received for on-screen windows. No whole-desktop capture is added.
