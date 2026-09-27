# M4 H.264 codec and Metal presentation

M4 adds the local codec and presentation boundary. It does not connect the
codec to LAN transport, input injection, clipboard synchronization, or a
product UI flow.

## Ownership

- `Packages/CodecCore/Sources/CodecCore/H264Encoder.swift` wraps a bounded
  VideoToolbox H.264 compression session.
- `Packages/CodecCore/Sources/CodecCore/H264Decoder.swift` wraps the callback-
  compatible VideoToolbox decompression session so the package keeps the macOS
  13 deployment target.
- `CodecTypes.swift` owns the stable M4 metadata contract: generation,
  capture/presentation timestamps in nanoseconds, dimensions, keyframe state,
  access units, and the bounded decoder configuration payload.
- `BoundedVideoFrameQueue` never grows without bound. It evicts an older
  non-keyframe when capacity is exhausted and applies backpressure when no
  safe eviction is possible.
- `Apps/Viewer/MetalVideoRenderer.swift` accepts decoded `CVPixelBuffer`
  values and presents them through `MTKView`/Core Image. The shared
  `VideoContentLayout` helper preserves the source aspect ratio on resize.

## Codec defaults

The default encoder configuration is H.264 Main Auto Level, real-time mode,
8 Mbps average bitrate, 60 fps, and a 60-frame keyframe interval. M8 adds
`AllowFrameReordering = false` (no B-frame output delay) and a best-effort
one-second `DataRateLimits` cap at 1.5x the average bitrate. M4 uses the
VideoToolbox output's AVCC-style access unit bytes and carries one SPS/PPS pair
in the deterministic `MRAH264` decoder-configuration payload. The protocol
layer remains responsible for carrying these bytes; CodecCore does not import
`RemoteProtocol`.

## Recovery and safety

- A decoder requires configuration before accepting an access unit.
- A newer generation may reconfigure only when the incoming frame carries a
  decoder configuration; an older generation is rejected.
- A reset invalidates the VideoToolbox session and completes pending encoder
  callbacks with cancellation.
- Encoder in-flight work and the local frame queue are bounded.
- Corrupt/truncated configuration and empty access units are rejected before
  reaching VideoToolbox.

## Verification

Deterministic tests cover decoder-configuration round trips, malformed trailing
data, keyframe-preserving queue replacement, and aspect-fit layout. The
`MACREMOTEAPP_RUN_M4_CODEC_SMOKE=1` opt-in test creates 64x64 BGRA and `420v` fixtures,
encodes one forced keyframe, decodes it, and checks generation, timestamps,
dimensions, and output pixels. It is deliberately opt-in because VideoToolbox
hardware availability is host-specific. Metal presentation still requires a
Viewer window-server/manual check for drawable resize and frame pacing.

## Boundary

M4 does not add mouse/keyboard capture, Host-side event injection, clipboard
payloads, audio, HEVC, Internet traversal, or multi-window presentation.
