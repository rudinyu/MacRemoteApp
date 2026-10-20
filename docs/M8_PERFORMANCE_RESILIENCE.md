# M8 Performance and Resilience

## Status

The M8 measurement model, deterministic benchmark harness, bounded-queue
stress path, and fault-injection test coverage are implemented. The production
session now collects up to 64 authenticated four-timestamp Ping/Pong probes,
and the Viewer feeds its drawable-presentation callback into a bounded,
sanitized collector (60 warm-up frames and at most 10,000 retained samples).
The collector exposes counts and percentiles only; it does not persist a frame
trace or claim a passing run by itself. A physical 30-second Intel Host to
Apple Silicon Viewer capture/display report remains an M10 environment
evidence item and must not be replaced by synthetic numbers.

## Measurement contract

The benchmark uses four authenticated monotonic timestamps for each clock
probe:

```text
Host:   H1 send ------------------------------ H4 receive
Viewer:              V2 receive --- V3 send
```

For each probe:

- `RTT = (H4 - H1) - (V3 - V2)`.
- `offset = ((V2 - H1) + (V3 - H4)) / 2`, expressed as Viewer-minus-Host.
- The minimum-RTT probe supplies the reported offset.
- Residual uncertainty is the larger of half the minimum RTT and the observed
  offset spread from that selected probe.
- Drift is the first-to-last offset change per elapsed Host second.
- One-way latency is eligible only after at least 20 valid probes and at most
  5 ms residual uncertainty. Otherwise report authenticated round-trip data
  and mark one-way latency unverified.

The production heartbeat may be initiated by either peer. For a Viewer-
initiated exchange the event order is `V1 send -> H2 receive -> H3 send -> V4
receive`; the runtime records the direction and uses
`RTT = (V4 - V1) - (H3 - H2)` and
`offset = ((V4 - H3) + (V1 - H2)) / 2`. This is the same Viewer-minus-Host
offset contract as the Host-initiated form above, rather than treating the
reverse-direction timestamps as a malformed Host-initiated probe.

The production `Pong` carries the receiver's optional monotonic timestamp for
this calculation. A peer that omits it remains compatible, but produces no
one-way estimate; the runtime never substitutes a local or synthetic clock.

Frame samples discard the first 60 warm-up frames and require at least 1,000
valid post-warm-up samples over a documented 30-second window. The harness's
`--samples` value counts valid samples; its 60 warm-up frames are added before
that count and are excluded from both the timestamp window and the reported
frame rate. The deterministic harness bounds `--samples` to 1,000,000 and
rejects an overflowing warm-up-plus-sample count before allocating result
arrays. Capture-to-display latency
is:

```text
(Viewer `MTLDrawable.presentedTime` timestamp - estimated offset) - Host
monotonic capture-arrival timestamp
```

The report contains p50 and p95, not only an average. Viewer presentation is
the timestamp taken by `MetalVideoRenderer` from the drawable's presented
handler at the display handoff boundary. `CaptureCore` records the Host
monotonic arrival timestamp separately from the media PTS. Queue-entry,
decoder-completion, or synthetic render timestamps are not accepted as
presentation evidence. The current Viewer callback retains the raw pair for
the M8 collector boundary. The production collector applies the same warm-up
rule and a hard 10,000-sample bound; one-way conversion remains invalid until
the authenticated clock-sync estimate is available. It is currently an
in-memory measurement boundary rather than a completed physical-run report.

## Per-stage latency budget

`LatencyBudget.v1` splits the 50 ms p95 target so a miss can be attributed:

| Stage | Clock | p95 budget | Measured by |
| --- | --- | ---: | --- |
| Host capture arrival → wire-queue admission (encode + scheduling) | Host | 12 ms | `HostRuntime` `BoundedStageLatencyCollector` |
| Wire admission → Viewer receipt (TCP + queues) | Both | 18 ms | Not measured directly; the end-to-end remainder |
| Viewer receipt → drawable presentation (decode + display wait) | Viewer | 20 ms | `ViewerRuntime` `BoundedStageLatencyCollector` |
| End to end | Both, clock-aligned | 50 ms | `BoundedPresentationSampleCollector` |

The two single-clock stages need no clock synchronization. Each collector
skips 60 warm-up samples, keeps at most 10,000 intervals, and stores interval
lengths only. During a session the Host and Viewer write aggregate lines to the
unified log about every ten seconds, for example
`M8 stage host-capture-to-send samples=… p50Ns=… p95Ns=… budgetNs=…
withinBudget=…`. Alongside it the Host logs `M8 stage host-capture-to-encoded`
(capture arrival to VideoToolbox output, recorded on the encoder callback
thread), so a slow capture-to-send stage can be attributed to encoding
(for example thermal throttling) or to send-side waiting. The capture loop
reads keyframe requests without an actor hop, and window discovery resolves
each owning process's activation policy once per pass rather than per window.
The Host uses category `host-runtime`; the Viewer uses
`startup` and also logs `viewer-receive-to-present` and, once the clock
estimate is eligible, `end-to-end`. These lines contain no pixels, titles,
input, or clipboard data. The physical run should collect them with the
commands in `docs/DEBUG_LOG_COLLECTION.md`.

## Harness and artifacts

Run the deterministic harness with:

```bash
bash scripts/run-m8-benchmark.sh
```

The default run uses 1,800 valid synthetic 60 fps samples plus 60 warm-up
frames over 30 seconds, and writes a sanitized JSON report under
`.build/m8-benchmark/`. The synthetic timestamps are generated from the
declared sample window so `validFrameSamples`, achieved fps, and the latency
population refer to the same post-warm-up interval.
It records only timing aggregates, queue counters, reconnect/keyframe counts,
architecture labels, and process resource counters. It never stores pixels,
clipboard text, input values, or window titles.

The harness also stresses the bounded H.264 queue with a slow consumer. The
queue remains at capacity three, replaces only non-keyframes, and preserves a
recovery keyframe. Existing TransportCore tests cover control overflow,
media replacement, malformed frames, replay, heartbeat timeout, reconnect,
authorization invalidation, and codec reset behavior.

The benchmark executable and `scripts/run-m8-benchmark.sh` return a non-zero
status when the report verdict is `fail`; the report is retained for diagnosis
before the acceptance gate stops.

## Current evidence boundary

| Evidence | State |
| --- | --- |
| Clock-probe math and p50/p95 calculation | Verified by deterministic tests |
| Production Ping/Pong probe wiring and bounded presentation collector | Verified by focused unit tests; physical timing not measured here |
| Queue bound and keyframe-aware delta-frame discard | Verified by deterministic TransportCore tests and harness |
| Encoder no-reordering and `DataRateLimits` settings | Accepted by the Apple Silicon VideoToolbox smoke; Intel encoder pending physical run |
| TCP `noDelay` input latency effect | Configured; not measured |
| Viewer `KeyframeRequest` gating, throttling, and gap trigger | Verified by RemoteProtocol golden vector and TransportCore session tests; physical recovery time not measured |
| Ordered encoder-to-wire relay | Compiles into Host; ordering is structural (single FIFO consumer); not exercised by a physical run |
| `420v` capture input | Accepted by the Apple Silicon VideoToolbox smoke; Intel capture/encode pending physical run |
| Per-stage budget collectors and log lines | Collector math verified by deterministic tests; stage values pending physical run |
| Adaptive bitrate (`ReceiverReport`, `AdaptiveBitrateController`, live encoder update) | Controller and delay-measurement math verified by deterministic tests; session delivery verified by a TransportCore test; live `AverageBitRate` change accepted by the Apple Silicon VideoToolbox smoke; behavior on a degraded physical LAN not measured. The Host logs `M8 bitrate bps=… reason=…` on each change |
| Reconnect/keyframe recovery state model | Verified by TransportCore/CodecCore tests |
| 1080p/60 synthetic contract | Harness pass; not a hardware result |
| Intel Host capture-to-display | Pending physical Intel Host |
| Apple Silicon Viewer Metal presentation latency | Pending physical two-machine run |
| CPU/GPU/memory under real capture load | Pending physical run; synthetic GPU sampling is unavailable |

No alternate transport was introduced. The baseline remains the authenticated
Network.framework TCP binding until a physical measurement demonstrates that
it misses the documented target.

The physical run must report resolution as the encoded pixel size from
`StreamConfig` and note the Host display backing scale, per the
[M3 output resolution policy](M3_CAPTURE.md#output-resolution-policy); the
deterministic harness does not capture and records neither.
