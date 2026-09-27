# ADR-0001: M2 discovery, transport binding, and trust bootstrap

- Milestone: M2
- Status: Accepted
- Extracted from: `docs/ARCHITECTURE.md` ("M2 decisions")

## Context

M0-M2 must record the Bonjour service identity, TLS/certificate strategy, and
stream connection binding (see
[Architecture decisions to record](../ARCHITECTURE.md#architecture-decisions-to-record-during-implementation)).
Discovery happens on a LAN that may contain an untrusted peer, and control
must not be starved by stale media.

## Decision

- Bonjour uses `_macremote._tcp` in `local.`. Discovery results are treated as
  untrusted endpoint hints and contain no pairing secret or captured content.
- The initial connection binding is one ordered Network.framework TCP byte
  stream carrying the M1 control/media channels. `TransportCore` keeps bounded
  control and media queues separate so stale media cannot starve control.
- TLS requires version 1.3 or newer and peer authentication on every
  connection. `SecurityCore` identifies a peer by the SHA-256 fingerprint of
  the leaf certificate public-key representation and compares it with a
  Keychain trust record.
- Unknown peers use a certificate-presented bootstrap session followed by
  explicit two-sided local-consent pairing.
- A matching local trust record auto-consents to the bootstrap challenge and
  suppresses that endpoint's prompt, but the Host still sends the challenge and
  both consent messages must complete.

## Consequences

- Trust does not imply window authorization; the Host must separately
  authorize the session after capability negotiation.
- Always sending the challenge and requiring both consent messages keeps
  one-sided Keychain state from deadlocking or silently bypassing consent on
  the endpoint that needs repair.
- TCP head-of-line blocking remains an M8 measurement concern; see
  [ADR-0006](0006-m8-transport-baseline-and-benchmark.md).
