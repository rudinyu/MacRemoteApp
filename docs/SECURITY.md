# MacRemoteApp Security and Privacy Design

## Security scope

MacRemoteApp controls an application on another Mac. A security failure can
expose window contents, clipboard text, keystrokes, or the ability to operate
the selected application. V1 therefore treats pairing, transport
authentication, authorization, permission state, focus state, and logging as
part of the product contract rather than optional hardening.

V1 assumes a local-area network that may contain an untrusted or compromised
peer. It does not attempt to solve a compromised Host OS, compromised Viewer
OS, malicious administrators, or physical attacks on a running unlocked Mac.
Those assumptions must be stated rather than implied.

## Security goals

- Only an explicitly paired and authenticated Viewer can receive protected
  window content or send input.
- A discovered service name or LAN reachability never grants control.
- The Host remains authoritative for selected-window identity, permissions,
  focus eligibility, and input authorization.
- Transport confidentiality and integrity protect video, input, protocol state,
  and opt-in clipboard text in transit.
- Trust records and private identity material are stored in the macOS Keychain.
- Permission loss, malformed messages, stale authorization, and reconnects fail
  closed.
- Logs and diagnostics do not leak clipboard contents, raw keystrokes,
  credentials, private keys, or captured pixels.

## Assets

| Asset | Why it matters |
| --- | --- |
| Selected window pixels | May contain private work, credentials, or personal data |
| Input events | Can operate the selected application and may include sensitive typing |
| Text clipboard | May contain credentials, tokens, personal data, or confidential text |
| Device identity and trust record | Grants future session authentication |
| Pairing confirmation state | Bootstrap authority for a new peer |
| Session authorization | Determines whether input and media are active |
| Window/application metadata | Can reveal active work or private names |
| Logs and crash artifacts | Can become an unintended copy of the assets above |

## Threat model

| Threat | Example | Required response |
| --- | --- | --- |
| Rogue discovery client | A device scans Bonjour and connects | Require TLS peer validation and explicit pairing/trust; discovery alone is never enough |
| Impersonated Host | A rogue service advertises a familiar name | Bind trust to a stored identity/public key, show user-confirmed pairing data, reject mismatches |
| Eavesdropping | Another LAN device observes traffic | Encrypt and integrity-protect the session before protected data is sent |
| Message tampering/replay | Attacker changes input or replays old events | Authenticated transport, sequence numbers, session freshness, and state validation |
| Malformed peer | Oversized or adversarial frames | Incremental bounded parsing, rate limits, safe teardown, no unbounded allocation |
| Stale input after reconnect | Buffered events reach a new session/window | Stop input on disconnect; bind events to session/window generation and reauthorize |
| Clipboard leakage | Text is logged or synced without consent | Opt-in state, bounded text-only contract, redacted diagnostics, explicit teardown |
| Permission abuse | App injects input while not authorized | Check Accessibility permission, focus/foreground eligibility, and session authorization at use time |
| UI confusion | Operator thinks input is disabled when it is active | Visible states for pairing, authorization, focus, permissions, and input readiness |
| Local process compromise | Another local process reads app memory | Document as out of V1 protection scope; minimize retention and avoid unnecessary copies |

## Identity, pairing, and trust

### Device identity

Each installation has a device identity generated and stored through the macOS
Keychain. Private key material must never be serialized into protocol logs,
plain files, or discovery metadata. The public identity may be presented during
the authenticated pairing flow.

### First pairing

1. Discovery provides only an endpoint and non-sensitive display metadata.
2. The Viewer connects and authenticates the transport enough to establish the
   peer identity exchange.
3. The Host displays a short, human-comparable confirmation value derived from
   the pairing transcript. The Viewer verifies the value locally and displays
   the same value with a one-time code-entry field.
4. The local operator on each endpoint explicitly consents after checking that
   the values match. A remote `PairingConfirmation` is evidence of remote
   consent, not local consent.
5. The active challenge has a bounded expiry (five minutes in the production
   configuration). `TransportCore` owns a deadline task tied to that expiry,
   so an unanswered consent prompt cannot keep a Host connection occupied
   indefinitely; before a challenge is received, the generic handshake
   deadline still applies.
6. Both sides store the peer identity and trust metadata in the Keychain only
   after the same challenge, peer identity, matching code, and both local and
   remote consent states are complete. Reject, expiry, disconnect, or a
   mismatched identity must clear pending state without creating one-sided
   permanent trust.
7. The session remains separately authorized for the selected window and
   enabled capabilities.

The confirmation value is not a password and must not be used as a long-term
secret. The normal M10 path accepts the presented TLS identity only for the
protected bootstrap, then asks `SecurityCore` for the Keychain trust decision.
An exact matching trust record silently completes the bootstrap challenge
exchange and skips the prompt on later connections; an unknown identity
requires the two-sided UI flow, and an identity mismatch is rejected. A
one-sided trust record never suppresses the other endpoint's challenge or
consent UI; that connection can repair the missing record only after the same
two-sided proof completes. An optional public-certificate pin remains a
migration/diagnostic mode, not a replacement for user consent.

### Subsequent sessions

Known peers may reconnect only when their stored identity matches the presented
identity and the session policy permits it. A trust mismatch requires an
explicit re-pair or trust revocation flow; silently accepting a changed key is
not allowed.

## Authorization model

Authorization is the intersection of all of the following:

```text
authenticated transport
  AND trusted peer
  AND current session authorization
  AND selected-window generation matches
  AND required macOS permission is present
  AND Host focus/foreground eligibility is valid
  AND capability is explicitly enabled
```

The Host must evaluate this before sending protected content and before each
input injection operation or bounded batch. The Viewer must disable its input
surface when the state is not ready. A UI label such as "connected" must not
be treated as equivalent to "authorized to control".

## macOS permission boundaries

- Screen Recording is required for Host-side ScreenCaptureKit capture.
- Accessibility is required for Host-side CoreGraphics/Accessibility input
  injection where macOS requires it.
- Permission prompts are initiated by the owning app at a user-understandable
  point; a remote peer cannot approve them.
- The implementation must detect permission revocation and stop the affected
  capability rather than retrying indefinitely or bypassing the check.
- Locked-screen, secure-input, login-window, and system-authentication-dialog
  control remain out of scope even if an API appears to expose a technical
  path.

## Transport protection

- Use Network.framework with a TLS 1.3-capable configuration for the protected
  session and explicitly require peer authentication on every connection.
- A bootstrap may accept an unknown but actually presented certificate for the
  pairing flow; it must reject a missing peer identity or failed certificate
  verification. Validate a known peer identity against the pairing/trust
  record before protected session data is delivered.
- Keep control and media queue isolation, but apply the same session identity,
  authorization, and teardown rules to both.
- Do not invent custom cryptography. Use platform-provided primitives and
  document the chosen configuration in M2/M9.
- Include freshness and sequence validation so old control/input messages are
  not accepted after reconnect or window changes.
- `TransportCore` owns the session delivery gate and clears its authorization
  record before teardown/revocation notification. `SecurityCore` supplies
  identity, pairing, trust, and capability policy decisions; it does not infer
  current window generation, macOS permission, or focus eligibility.

## Input safety

- Input messages are typed protocol records, not arbitrary serialized
  `CGEvent` objects.
- Validate event type, coordinate range, modifier state, sequence, rate, and
  selected-window generation.
- Disable or reject input if the Host loses Accessibility permission, the
  selected window closes/changes, the window is no longer foreground-eligible,
  or the session state becomes uncertain.
- Never send or log passwords, secure-input contents, or authentication-dialog
  interaction as a V1 feature.
- A malformed input event must fail closed without partially applying a
  sequence of unrelated events.

M6 enforcement is split explicitly: `TransportCore` admits the authenticated
  message, `Apps/Host` supplies the current session and selected-window facts,
  and `InputCore.HostInputController` performs the final per-event check.
  `CoreGraphicsAccessibilityContextProvider` rechecks Accessibility/post-event
  permission, current bounds, on-screen window identity, foreground ordering,
  and lock state; each typed command carries the target window, owning
  application identifier, process, and generation, and
  `CoreGraphicsAccessibilityInputAdapter` repeats the complete target/focus/
  permission check immediately before posting. The adapter never activates a
  background window. Unknown secure-input or console state is rejected because
  macOS does not provide a reliable general public status API; no private API
  or bypass is used. Host reset attempts safe release of admitted pressed
  state before clearing it and uses a reserved state-ending rate lane. If
  session authorization has already been revoked, that cleanup path may only
  release controller-admitted state while the same window identity,
  generation, current bounds, and permission still match. A selected target
  that is known to be not foreground is allowed only for this target-bound
  release path; normal input still requires eligible foreground focus. A local
  selection transition must be announced before the provider changes so the
  old target can be released while it is still selected. If the ordering is
  missed, the stale release is rejected and the Host closes the session rather
  than carrying pressed state into the replacement target. If permission
  temporarily disappears, cleanup remains pending and is surfaced as
  unavailable until a safe snapshot returns; if the session stream ends first,
  the Host retains a target-bound cleanup retry until recovery or target
  replacement. Queued input is discarded on local authorization, permission,
  focus, and selection transitions. Input already handed directly to the sole
  stream waiter is additionally fenced by the non-reentrant
  `SessionCoordinator.withIncomingInputAdmission` operation, so local revoke,
  reconnect, or stop cannot invalidate authorization between the check and the
  Host injection call. Unmatched releases are rejected.

## Clipboard privacy

- Clipboard synchronization is disabled by default and visibly opt-in.
- Only bounded text is accepted; all other pasteboard types are rejected.
- Do not log clipboard contents, hashes that could be used as identifiers, or
  full error payloads containing text.
- Track origin and generation to prevent echo loops.
- Clear transient outgoing/incoming clipboard buffers when the session ends,
  subject to the minimum retention needed by the active UI state.
- M7 uses deterministic arrival-order conflict handling: a pending local offer
  wins over a concurrent remote offer; a local edit after a remote offer has
  been accepted cancels that incoming offer and creates a new local generation.
  Replayed generations are rejected, and all transient state is cleared on
  stop/reconnect. Unit tests cover this policy, size bounds, acknowledgements,
  and echo suppression.

## Logging, diagnostics, and data retention

- Use structured event codes and redacted metadata.
- Safe fields may include protocol state, capability names, bounded dimensions,
  frame counts, error categories, and timing aggregates.
- Sensitive fields that must be excluded include raw pixels, clipboard text,
  key values, private keys, pairing secrets, full window titles when policy
  marks them sensitive, and arbitrary underlying error strings.
- Debug capture dumps and packet traces require an explicit development-only
  mode and must never be enabled by default or included in a release artifact.
- Retain trust records only until the user revokes them or uninstalls/clears
  the installation according to the documented Keychain policy.

## Validation requirements

Security validation is staged rather than deferred entirely to release:

- **M1**: fuzz/boundary tests for envelope and message validation.
- **M2**: required peer authentication, pairing consent, identity mismatch,
  TLS failure, replay/freshness, bounded lifecycle, and unauthorized-session
  tests.
- **M3-M6**: permission revocation, stale window, focus loss, and input fail-
  closed tests.
- **M7**: clipboard opt-in, size limit, redaction, conflict, and echo-loop
  tests.
- **M8**: disconnect/reconnect, queue exhaustion, malformed peer, and resource
  exhaustion tests.
- **M9**: threat-model review, dependency review, logging audit, trust-revocation
  review, and release configuration audit.
- **M10**: Intel/Apple Silicon integration acceptance with a written residual
  risk list.

M8-M10 release evidence is produced without retaining pixels, clipboard text,
raw input values, private keys, or full sensitive window titles. The release
audit rejects development commands and unsafe entitlements from packaged
artifacts. Physical acceptance remains an explicit gate; synthetic benchmark
results and loopback tests do not establish Intel/Apple Silicon
interoperability.

The M10 runtime still requires each endpoint's own private identity to be
provisioned in its local Keychain. It does not require copying the other
endpoint's public certificate for normal pairing, and it never copies a
private key between devices.

## Security non-goals and residual risks

V1 does not protect against a Host or Viewer that is already compromised, a
malicious user with local administrative control, physical memory inspection,
or a user who intentionally approves a rogue pairing code. The product must
make these assumptions visible in documentation and must not claim protection
that the implementation does not provide.

Any missed control, unverified cryptographic configuration, or environment-only
test limitation must be recorded as an open security risk before V1 release.

## M2 implementation decisions and open validation

M2 uses TLS 1.3 through Network.framework and derives the peer identifier from
the SHA-256 fingerprint of the leaf certificate public-key representation.
Peer authentication is required on both client and server paths. Known peers
are compared against `SecurityCore` trust records stored in the macOS
Keychain. A certificate that does not match the stored identity is rejected;
an unknown but presented identity may enter the protected bootstrap flow but
cannot send or receive protected session content until pairing and Host
authorization complete.

The Host initiates pairing. The challenge identifier deterministically binds the
pairing nonce, and both peers independently derive the confirmation value from
that nonce and the two presented public identities; the Viewer rejects a value
that does not match its local derivation. Each endpoint records an explicit
local consent event, and a remote confirmation is accepted only as the other
side's consent for the same challenge. Both sides persist the peer identity only
after the two-sided state is complete. Revocation deletes the trust record and
requires pairing again. Reconnect clears session authorization, window scope,
capability scope, and channel sequence state.

The local device key is retained by Keychain-backed `SecurityCore`; the TLS
adapter receives a platform `SecIdentity` loaded from Keychain or imported
from a PKCS#12 provisioning bundle. P-256 certificate and Network.framework
peer-key representations are canonicalized before fingerprint comparison.
Certificate enrollment policy, key-to-certificate continuity,
reinstall/rotation behavior, locked-Keychain failure, and access-control
configuration remain deployment-specific. The M5 environment has now passed
real loopback mutual-TLS/session startup with temporary identities; that is not
evidence of physical Intel Host to Apple Silicon Viewer Bonjour/TLS
interoperability, which remains an environment validation item. M6
deterministic authorization and adapter gates now pass; real OS input posting
still requires the documented disposable-application manual test.
