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
- The system provider excludes desktop windows and requires a layer-0 window,
  a non-empty application bundle identifier, positive bounds, and a user-facing
  app. The catalog includes on-screen windows and at most one offscreen window
  per regular app that has no on-screen window. It prefers a titled window;
  when none is titled, it offers the largest untitled window. Agent/accessory
  app windows remain excluded. The default minimum selectable window is
  160×80 points, which prevents common 1×33 preview/service windows while
  preserving normal app windows such as LINE and ChatGPT.
- `CaptureWindow.isOnScreen` records the catalog visibility. Selecting an
  offscreen entry explicitly asks the Host to reveal and foreground that app
  before capture starts. This selection action does not authorize input; the
  independent foreground, permission, pairing, and session checks still apply.
- M8 changes the default capture pixel format to 4:2:0 bi-planar video range
  (`420v`) with a BT.709 YCbCr matrix, which H.264 encodes without a BGRA
  conversion. `CaptureConfiguration.pixelFormat` keeps BGRA available.

## Permission behavior

`ScreenRecordingWindowProvider` reports the current Screen Recording state
through `CGPreflightScreenCaptureAccess()` and exposes an explicit request
method for the Host application to guide the user through the macOS permission
flow. Capture never treats a failed or unavailable permission as an empty
window list.

## Output resolution policy

Window bounds from ScreenCaptureKit are global **points**; the capture stream
is sized in **pixels**. CaptureCore applies one rule, shared by the capture
engine and the Host encoder/`StreamConfig`:

1. At catalog read, each window records the backing scale (pixels per point)
   of the display holding the largest share of its frame. The scale is the
   display mode's `pixelWidth / width` (2 on Retina, 1 on a standard display).
   Equal overlaps prefer the higher scale; no overlap, an unavailable mode, or
   a non-finite value yields 1. Values are clamped to 1…4.
2. Source pixels are the point bounds times that scale.
3. The source is downscaled with preserved aspect ratio to fit
   `CaptureConfiguration.maximumWidth` × `maximumHeight`, 1920×1080 pixels by
   default. Capture never upscales.

Examples: 640×480 points at scale 2 captures 1280×960; 960×540 points at
scale 2 captures exactly 1920×1080; 1600×1000 points captures 1600×1000 at
scale 1 and 1728×1080 at scale 2.

The dimensions are fixed for one capture generation and exposed as
`CaptureSessionSnapshot.outputDimensions`; the Host builds its H.264 encoder
and `StreamConfig` from that value rather than recomputing it. If the window
moves to a display with a different scale (or is resized) during a
generation, the catalog entry and point bounds refresh, but the stream keeps
its configured pixel size and ScreenCaptureKit resamples the content into it.
The next selection (a new generation) samples the new scale. Mid-generation
renegotiation is not implemented.

Host input is unaffected: the Viewer normalizes pointer positions to the
displayed content rectangle and InputCore maps them to the selected window's
current point bounds, so the encoded pixel size never enters input mapping.
The Host advertises `CaptureConfiguration.default.maximumWidth`/`Height` as
its negotiated video limit, and `SessionCoordinator` rejects any
`StreamConfig` or `VideoFrame` above the negotiated minimum of both peers.

## Capture lifecycle

`WindowCaptureSession` requires an eligible window from a fresh catalog before
starting. Each selection receives a monotonically increasing generation. A
permission loss, selected-window disappearance, ScreenCaptureKit error, normal
stream end, or cancellation stops the engine and invalidates the session
output. Frames are accepted only when their window identifier and generation
match the active selection.

The output stream uses a bounded newest-frame buffer. This is a capture-stage
bound only; M8 owns end-to-end frame pacing and performance measurement.

`WindowCaptureSession.frames` is reusable across selections, but each
generation is backed by its own bounded stream. Swift terminates an
`AsyncThrowingStream` permanently when the task awaiting it is cancelled, and
the Host cancels its capture task whenever it stops or replaces the video
pipeline. With one shared stream, every capture after the first pipeline
restart delivered no frames and the Viewer froze on the last picture. `start`
now installs a fresh stream, so cancelling a consumer ends only its own
generation. A capture failure finishes that generation's stream with the
failure, so the Host's capture loop ends instead of waiting indefinitely.
`testCancelledConsumerDoesNotStopFramesForNextGeneration` covers the restart
sequence.

## Verification

Deterministic tests use fake window and capture providers to cover:

- selected-window start/stop and generation-tagged frame delivery;
- permission loss and window disappearance fail-closed behavior;
- rejection of ineligible windows;
- catalog policy for one representative offscreen window per regular app,
  preferring titles and falling back to the largest untitled window, plus
  visibility metadata;
- bounded output configuration;
- pixel output sizing at backing scale 1 and 2, oversized-window downscaling
  with preserved aspect ratio, display selection by largest overlap, and
  per-generation pinning of output dimensions.

A root smoke test proves that the same normalized pointer event lands on the
same Host point for scale-1 and scale-2 capture sizes.

The opt-in `scripts/run-m3-system-smoke.sh` checks the current macOS
ScreenCaptureKit path without requesting permission. It selects the largest
visible user-application window to avoid WindowManager overlays. A headless or
non-window-server environment may enumerate but produce no frame; that result
is an environment limitation, not a passing capture evidence claim.

Physical checks should also select a minimized, hidden, or other-Space regular
app window and verify that explicit selection foregrounds it before video
capture. Test that input remains unavailable unless the existing independent
input-authorization checks pass.

## Exit status

The CaptureCore implementation and deterministic tests are complete. The
operator's physical Viewer screenshot confirms a selected Host window frame
reached the Viewer, so the tested Host's ScreenCaptureKit capture path has
produced a real frame. Deterministic offscreen-catalog policy tests pass, but
physical offscreen selection/activation, Screen Recording revocation, and
selected-window change/close lifecycle checks are not separately recorded; see
the remaining M3 evidence in `docs/STATUS.md`.
