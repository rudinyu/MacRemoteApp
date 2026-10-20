# Decision Records

Short, milestone-scoped decision records (context, decision, consequences).
They were extracted from the design documents so that the design narrative
stays readable; the design documents link back to the relevant record.

A record describes a decision, not current evidence. Milestone state and open
evidence gaps live in [the status page](../STATUS.md).

| Record | Milestone | Topic | Linked from |
| --- | --- | --- | --- |
| [ADR-0001](0001-m2-discovery-transport-and-trust-bootstrap.md) | M2 | Bonjour service, stream binding, TLS peer identity, trust bootstrap | [Architecture](../ARCHITECTURE.md#architecture-decisions-to-record-during-implementation) |
| [ADR-0002](0002-m2-tls-identity-and-pairing.md) | M2 | TLS identity storage, commit/reveal pairing, revocation | [Security](../SECURITY.md#decision-records) |
| [ADR-0003](0003-m3-window-capture-scope.md) | M3 | Window capture filter, eligibility, capture generations | [Architecture](../ARCHITECTURE.md#architecture-decisions-to-record-during-implementation) |
| [ADR-0004](0004-m5-viewer-input-binding.md) | M5 | Viewer coordinate, ordinal, rate, and transport binding | [Protocol](../PROTOCOL.md#input-contract) |
| [ADR-0005](0005-m6-host-input-binding.md) | M6 | Host input admission, mapping, and cleanup binding | [Protocol](../PROTOCOL.md#input-contract) |
| [ADR-0006](0006-m8-transport-baseline-and-benchmark.md) | M8 | Transport baseline, clock-sync probes, video queue | [Architecture](../ARCHITECTURE.md#architecture-decisions-to-record-during-implementation) |
| [ADR-0007](0007-m10-input-source-following.md) | M10 | Viewer-led Chinese/English input-source synchronization | [Protocol](../PROTOCOL.md#viewer-led-input-source-synchronization-m10) |
| [ADR-0008](0008-m10-viewer-text-composition.md) | M10 | Viewer-side text composition and committed-text input events | [Protocol](../PROTOCOL.md#viewer-side-text-composition-m10) |
