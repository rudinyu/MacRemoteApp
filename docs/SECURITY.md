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
3. The Host and Viewer display a short, human-comparable confirmation value
   derived from the pairing transcript.
4. The Operator confirms that the values match on the intended devices.
5. Both sides store the peer identity and trust metadata in the Keychain.
6. The session remains separately authorized for the selected window and
   enabled capabilities.

The confirmation value is not a password and must not be used as a long-term
secret. The exact TLS certificate/public-key pinning and transcript-binding
mechanism is an M2 decision, subject to M9 review.

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
  session.
- Validate peer identity against the pairing/trust record after the first
  user-confirmed bootstrap.
- Keep control and media queue isolation, but apply the same session identity,
  authorization, and teardown rules to both.
- Do not invent custom cryptography. Use platform-provided primitives and
  document the chosen configuration in M2/M9.
- Include freshness and sequence validation so old control/input messages are
  not accepted after reconnect or window changes.

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

## Clipboard privacy

- Clipboard synchronization is disabled by default and visibly opt-in.
- Only bounded text is accepted; all other pasteboard types are rejected.
- Do not log clipboard contents, hashes that could be used as identifiers, or
  full error payloads containing text.
- Track origin and generation to prevent echo loops.
- Clear transient outgoing/incoming clipboard buffers when the session ends,
  subject to the minimum retention needed by the active UI state.
- M7 must document the conflict policy when both sides change text close
  together and must add tests for the policy.

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
- **M2**: pairing, identity mismatch, TLS failure, replay/freshness, and
  unauthorized-session tests.
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

## Security non-goals and residual risks

V1 does not protect against a Host or Viewer that is already compromised, a
malicious user with local administrative control, physical memory inspection,
or a user who intentionally approves a rogue pairing code. The product must
make these assumptions visible in documentation and must not claim protection
that the implementation does not provide.

Any missed control, unverified cryptographic configuration, or environment-only
test limitation must be recorded as an open security risk before V1 release.
