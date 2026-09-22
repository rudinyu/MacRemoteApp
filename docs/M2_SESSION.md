# M2 Secure LAN discovery and session

M2 implements the shared secure-session foundation used by the Host and Viewer.
It provides Bonjour discovery, Network.framework connection lifecycle, TLS peer
identity handling, pairing bootstrap, Keychain trust records, capability
negotiation, explicit authorization, heartbeat, bounded queues, teardown, and
reconnect. It does not implement capture, video encoding/decoding, input
injection, or clipboard transfer.

## Binding decisions

| Decision | M2 choice |
| --- | --- |
| Bonjour service | `_macremote._tcp` in `local.`; instance names and discovery metadata are advisory only |
| Connection | One ordered Network.framework TCP byte stream with the M1 envelope; control and media have separate bounded scheduling queues, with control priority between writes |
| TLS | TLS 1.3 minimum through `NWProtocolTLS`; peer authentication is required on every connection; peer identity is the leaf certificate public-key representation |
| Identity fingerprint | Lowercase SHA-256 of the presented public-key representation |
| Known peer policy | `SecurityCore` compares the presented identity with a Keychain-backed `TrustedPeer` record; a changed identity is rejected |
| Bootstrap policy | An unknown but actually presented certificate may establish the TLS-protected bootstrap session, but the session remains pairing-required and unauthorized until both endpoints record local consent and the displayed code matches |
| Queue policy | Control queue capacity 128; media queue capacity 3; a full media queue replaces only an unsent discardable video frame before wire admission, while a full control queue fails closed |

The local device key is generated and retained by `SecurityCore` in the login
Keychain. `KeychainIdentityProvider.loadOrCreate()` reuses an existing
identity or creates a non-exportable P-256 private key and a matching local
self-signed TLS certificate; `SecIdentity` is assembled in memory for
Network.framework. The private key and certificate record never leave the
endpoint. `KeychainIdentityProvider.importPKCS12()` remains only for the
explicit M2 diagnostic smoke workflow. `SecurityCore` canonicalizes P-256
public-key representations so the certificate path and Network.framework
metadata produce the same peer fingerprint. Key/certificate continuity is
fail-closed: a missing or mismatched generated certificate is not silently
rotated. The transport fails closed when local enrollment cannot complete.

## Pairing flow

1. The Host connects with a bootstrap TLS policy and creates a random challenge
   identifier. The session pairing nonce is deterministically derived from that
   identifier, so both peers can independently recompute the confirmation value.
2. `SecurityCore` derives a short confirmation value from both peer public-key
   identities and that nonce. The Host sends the displayable value over the
   protected bootstrap session; the Viewer verifies it locally before adopting
   the challenge.
3. The Viewer adopts the Host challenge and presents the same value to the
   local operator. The operator records local consent only after checking the
   value on the intended devices.
4. The Viewer sends `PairingConfirmation` as remote-consent evidence. Neither
   peer writes a permanent trust record until its own local consent and the
   matching remote consent for the same challenge/identity are both present.
5. Both sides negotiate `Hello` and `Capabilities`. The Host must send
   `SessionAuthorize` before protected window, media, input, or clipboard
   messages can be sent or accepted.

When a bootstrap connection has an existing local trust record, that endpoint
auto-consents to the same challenge and does not show its pairing prompt. The
Host still sends the challenge and both `PairingConfirmation` messages are
exchanged, so a one-sided or stale trust record cannot skip the other endpoint's
consent flow; a successful exchange repairs both Keychain records.

Pairing codes are confirmation data, not long-term credentials. They are not
written to diagnostics. Revocation deletes the peer record and returns future
connections to `pairingRequired`.

The production pairing challenge expires after five minutes. `TransportCore`
uses the challenge expiry as an independent teardown deadline, so a modal
consent prompt cannot hold the Host indefinitely; the ordinary handshake
deadline remains active until a challenge has been received.

## Session lifecycle

```text
connecting
  -> trusted or pairingRequired
  -> capabilitiesNegotiated
  -> windowSelectionAuthorized
  -> stopping, reconnecting, or failed
```

The session coordinator validates role and protocol version, computes the
capability intersection, rejects missing mandatory capabilities, and tracks a
separate sequence per channel. Control sequences are strict. A bounded media
queue may replace an unsent discardable frame with a newer frame, so media
sequences are strictly increasing but may have forward gaps; `VideoConfig` and
recovery keyframes are retained. Heartbeat uses `Ping`/`Pong`; connection and
handshake deadlines, normal EOF, cancellation, and timeout clear authorization
and close the transport. Reconnect resets identities, sequences, capabilities,
window scope, and authorization before a new handshake. When an authorization
epoch invalidates queued protected data, unsent protected media is discarded;
an admitted protected control envelope becomes an optional unknown tombstone
with the same sequence so strict control ordering remains valid and the peer
never applies the stale payload.

## Implementation map

- `Packages/SecurityCore`: peer identities, Keychain and in-memory trust
  stores, pairing state, confirmation values, trust comparison, and revocation.
- `Packages/TransportCore/BonjourDiscovery.swift`: `NWBrowser`, `NWListener`,
  and deterministic in-memory discovery double.
- `Packages/TransportCore/TLSOptions.swift`: TLS 1.3 configuration, pinned
  identity verification, and bootstrap identity resolution.
- `Packages/TransportCore/NetworkFramedTransport.swift`: incremental M1 frame
  parsing over `NWConnection`, bounded outbound/incoming buffering, typed
  connection-state handling, deadlines, and safe teardown.
- `Packages/TransportCore/SessionCoordinator.swift`: handshake, pairing,
  authorization, sequence/freshness checks, heartbeat, and reconnect policy.

## Verification

The deterministic M2 tests use in-memory transport doubles and cover:

- trust-store round trip, revocation, pairing confirmation, wrong-code and
  expiry handling;
- Host-initiated pairing with two-sided consent and no single-sided trust;
- bootstrap reconnect with matching Keychain trust bypasses the pairing prompt;
- capability negotiation and refusal to send protected content before
  authorization;
- capability/window-scoped authorization and revoke failure fail-closed;
- control-priority and media-replacement queue behavior with monotonic media
  sequence gaps, plus bounded incoming buffering;
- required peer authentication, typed connection-state failure, handshake
  deadline, normal EOF, replay/out-of-order failure, heartbeat timeout, safe
  close, and reconnect authorization reset.
- real loopback Network.framework mutual TLS using temporary self-signed
  PKCS#12 identities, followed by Host/Viewer capability negotiation.

The current Apple Silicon environment has validated native compilation,
deterministic in-memory tests, and real loopback mutual TLS/session startup.
`docs/M2_PHYSICAL_SMOKE.md` and the `--m2-physical-host` /
`--m2-physical-viewer` diagnostic flags now provide the repeatable physical
Intel Host to Apple Silicon Viewer Bonjour/TLS/capability smoke. The actual
two-machine pass is still an environment evidence item until it is run on the
Intel Host and recorded. The typed consent API is exercised by the pairing
tests; product UI remains outside M2 and belongs to the later session UX
milestone.

## M2 boundary

M2 itself does not own ScreenCaptureKit, VideoToolbox, Metal, CoreGraphics or
Accessibility event injection, clipboard payload transfer, product UI,
Internet relay, WebRTC, audio, or file transfer. M3 and M4 provide the capture
and codec/presentation foundations in their own packages; input, clipboard, and
the remaining out-of-scope capabilities remain future or excluded work.
