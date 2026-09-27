# ADR-0006: M8 transport baseline, clock-sync probes, and video queue

- Milestone: M8
- Status: Accepted
- Extracted from: `docs/ARCHITECTURE.md` ("M8 decisions")

## Context

M8 must record benchmark evidence before any performance-driven transport
change (see
[Architecture decisions to record](../ARCHITECTURE.md#architecture-decisions-to-record-during-implementation)).
The [quality targets](../PRODUCT_SPEC.md#quality-targets) require p50/p95
latency with a bounded clock-offset uncertainty.

## Decision

- The baseline remains one authenticated Network.framework TCP stream with
  separate bounded control/media queues (see
  [ADR-0001](0001-m2-discovery-transport-and-trust-bootstrap.md)). No
  alternate transport is enabled without physical evidence that the baseline
  misses the target.
- The benchmark exchanges at least 20 authenticated four-timestamp probes,
  selects the minimum-RTT offset, reports residual uncertainty and drift, and
  refuses to label one-way latency verified when uncertainty exceeds 5 ms.
- Video queue capacity remains three. The Host outgoing queue and both Viewer
  incoming queues share `KeyframeAwareMediaAdmission`: a discarded delta frame
  starts a skip-until-keyframe state so no delta frame is ever decoded against
  a missing reference, and protected-media invalidation starts the same wait.
  `SessionCoordinator.send` reports `.replacedMedia` only when the queue
  enters that wait (a keyframe purging superseded delta frames does not), and
  the Host forces its next encode to a keyframe. A Viewer-side gap or decode
  failure sends the rate-limited `KeyframeRequest` described in
  [the protocol](../PROTOCOL.md#video-contract).
- Encoder output reaches the wire through one FIFO relay
  (`Apps/Host/HostEncodedFrameRelay`) instead of one unstructured task per
  frame, so frames cannot be reordered before sequence numbers are assigned.
  Its bounded buffer follows the same skip-until-keyframe rule on overflow.
- The encoder disables B-frame reordering and applies a best-effort
  one-second `DataRateLimits` cap at 1.5x the average bitrate. The TCP binding
  sets `noDelay` so small control/input envelopes are not held by Nagle
  coalescing behind video segments.
- The encoder bitrate adapts to congestion: 16 Mbps maximum, 2 Mbps floor,
  multiplicative decrease to 70% on loss or at least 40 ms Viewer-measured
  queuing delay, and stepwise recovery after 3 s of clear reports. Queuing
  delay comes from the optional Viewer `ReceiverReport`, which rises before
  frames are dropped; Host queue discards remain a fallback signal. See
  [the protocol](../PROTOCOL.md#video-contract).
- Capture defaults to 4:2:0 bi-planar video-range pixels tagged BT.709, the
  encoder's native input, removing a per-frame BGRA conversion on the Host.
- The p95 latency budget is split per stage in `LatencyBudget.v1`: Host
  capture-to-send 12 ms, network transit 18 ms, Viewer receive-to-present
  20 ms, summing to the 50 ms target. Host and Viewer log sanitized per-stage
  p50/p95 aggregates so a miss can be attributed to one stage (see
  [M8 per-stage budget](../M8_PERFORMANCE_RESILIENCE.md#per-stage-latency-budget)).

## Consequences

- Control/input ordering and authorization gates are never traded for a
  latency optimization.
- Physical benchmark evidence is still pending; see
  [the status page](../STATUS.md#m8--performance-and-resilience).
