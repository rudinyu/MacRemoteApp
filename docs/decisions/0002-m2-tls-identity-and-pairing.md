# ADR-0002: M2 TLS identity, commit/reveal pairing, and revocation

- Milestone: M2
- Status: Accepted; deployment-specific key handling remains open validation
- Extracted from: `docs/SECURITY.md` ("M2 implementation decisions and open
  validation")

## Context

[SECURITY.md](../SECURITY.md#identity-pairing-and-trust) requires peer
authentication on every connection, Keychain-held identities, and explicit
two-sided consent before permanent trust. M2 had to fix the concrete TLS
configuration, peer identifier, pairing exchange, and key-provisioning paths.

## Decision

- M2 uses TLS 1.3 through Network.framework and derives the peer identifier
  from the SHA-256 fingerprint of the leaf certificate public-key
  representation. Peer authentication is required on both client and server
  paths.
- Known peers are compared against `SecurityCore` trust records stored in the
  macOS Keychain. A certificate that does not match the stored identity is
  rejected; an unknown but presented identity may enter the protected
  bootstrap flow but cannot send or receive protected session content until
  pairing and Host authorization complete.
- The Host initiates pairing with a commitment to a fresh random contribution.
  The Viewer commits its own fresh contribution, the Host reveals its
  committed value, and the Viewer verifies and reveals its contribution.
  `SecurityCore` derives the confirmation value from the challenge ID, both
  presented public identities, and both contributions; either endpoint rejects
  a reveal that does not match the corresponding commitment.
- Each endpoint records an explicit local consent event, and a remote
  confirmation is accepted only as the other side's consent for the same
  challenge. Both sides persist the peer identity only after the two-sided
  state is complete.
- Revocation deletes the trust record and requires pairing again. Reconnect
  clears session authorization, window scope, capability scope, and channel
  sequence state.
- The local device key is retained by Keychain-backed `SecurityCore`; the TLS
  adapter receives a platform `SecIdentity` loaded from Keychain or assembled
  from the locally generated Keychain key and certificate. PKCS#12 import is
  restricted to the explicit debug physical-smoke path.
- P-256 certificate and Network.framework peer-key representations are
  canonicalized before fingerprint comparison.

## Consequences

- Generated key/certificate continuity is fail-closed; missing or mismatched
  material is reported instead of silently rotating a trusted identity.
- Reinstall/rotation behavior, locked-Keychain failure, and access-control
  configuration remain deployment-specific open validation items.
- Loopback and deterministic evidence for this decision, and the physical
  interoperability gap, are tracked in [the status page](../STATUS.md#m2--secure-lan-session).
