# M3 Host window discovery and capture

M3 adds the Host-side window catalog and one-window ScreenCaptureKit capture
foundation. It does not encode frames, render them, inject input, synchronize
clipboard content, or introduce whole-desktop capture.

## Scope and boundaries

- `CaptureCore` owns Screen Recording permission state, eligible window
  discovery, selected-window generation, capture lifecycle, and bounded raw
  `CVPixelBuffer` delivery.
- `RemoteProtocol` remains responsible for wire types; `CaptureCore` does not
  import or construct protocol messages.
- `CodecCore` owns the H.264 conversion implemented in M4. `InputCore` owns later input
  authorization/injection adapters.
- The system provider excludes desktop windows, requires an on-screen window
  layer of zero, requires a non-empty application bundle identifier, and
  rejects zero-sized, helper, renderer, or service surfaces. The default
  minimum selectable window is 160×80 pixels, which prevents common 1×33
  preview/service windows while preserving normal app windows such as LINE and
  ChatGPT.
- M8 changes the default capture pixel format to 4:2:0 bi-planar video range
  (`420v`) with a BT.709 YCbCr matrix, which H.264 encodes without a BGRA
  conversion. `CaptureConfiguration.pixelFormat` keeps BGRA available.

## Permission behavior

`ScreenRecordingWindowProvider` reports the current Screen Recording state
through `CGPreflightScreenCaptureAccess()` and exposes an explicit request
method for the Host application to guide the user through the macOS permission
flow. Capture never treats a failed or unavailable permission as an empty
window list.

## Capture lifecycle

`WindowCaptureSession` requires an eligible window from a fresh catalog before
starting. Each selection receives a monotonically increasing generation. A
permission loss, selected-window disappearance, ScreenCaptureKit error, normal
stream end, or cancellation stops the engine and invalidates the session
output. Frames are accepted only when their window identifier and generation
match the active selection.

The output stream uses a bounded newest-frame buffer. This is a capture-stage
bound only; M8 owns end-to-end frame pacing and performance measurement.

## Verification

Deterministic tests use fake window and capture providers to cover:

- selected-window start/stop and generation-tagged frame delivery;
- permission loss and window disappearance fail-closed behavior;
- rejection of ineligible windows;
- bounded output configuration.

The opt-in `scripts/run-m3-system-smoke.sh` checks the current macOS
ScreenCaptureKit path without requesting permission. It selects the largest
visible user-application window to avoid WindowManager overlays. A headless or
non-window-server environment may enumerate but produce no frame; that result
is an environment limitation, not a passing capture evidence claim.

## Exit status

The CaptureCore implementation and deterministic tests are complete. The
current M5 logged-in window-server session produced a real frame. Physical
Host capture evidence on other machines remains environment-dependent until
their own Screen Recording smoke test produces a frame.
