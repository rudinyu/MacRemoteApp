# M8 Performance and Resilience

## Status

The M8 measurement model, deterministic benchmark harness, bounded-queue
stress path, and fault-injection test coverage are implemented. The current
workspace can produce a sanitized synthetic report. A physical 30-second
Intel Host to Apple Silicon Viewer capture/display report remains an M10
environment evidence item and must not be replaced by synthetic numbers.

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
the M8 collector boundary; one-way conversion remains invalid until the
authenticated clock-sync estimate is available.

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
| Queue bound and non-keyframe replacement | Verified by deterministic tests and harness |
| Reconnect/keyframe recovery state model | Verified by TransportCore/CodecCore tests |
| 1080p/60 synthetic contract | Harness pass; not a hardware result |
| Intel Host capture-to-display | Pending physical Intel Host |
| Apple Silicon Viewer Metal presentation latency | Pending physical two-machine run |
| CPU/GPU/memory under real capture load | Pending physical run; synthetic GPU sampling is unavailable |

No alternate transport was introduced. The baseline remains the authenticated
Network.framework TCP binding until a physical measurement demonstrates that
it misses the documented target.
