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
- Video queue capacity remains three; only unsent non-keyframes may be
  superseded.

## Consequences

- Control/input ordering and authorization gates are never traded for a
  latency optimization.
- Physical benchmark evidence is still pending; see
  [the status page](../STATUS.md#m8--performance-and-resilience).
