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
| Permission abuse | App injects input while not authorized | Check PostEvent permission, focus/foreground eligibility, and session authorization at use time |
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
3. The Host commits to a fresh random contribution. The Viewer commits to its
   own fresh random value, after which the Host reveals its committed value.
   The Viewer verifies that reveal and then reveals its committed value. Both
   endpoints independently derive a short, human-comparable confirmation value
   from the challenge ID, both public identities, and both contributions. The
   Viewer displays the same value with explicit **Accept** and **Deny**
   actions; no code is typed or treated as a credential.
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

### User-initiated trust reset

The Host status menu and Viewer window provide an explicit `Forget saved
pairings…` action. The action stops the active session first, then deletes only
the saved peer `TrustedPeer` records from that app role's Keychain service. It
does not delete the endpoint's own TLS identity, the other role's trust
records, permissions, or unrelated Keychain items. The next connection
therefore returns to the two-sided pairing flow and requires a new confirmation
code. The operation is all-peer for the current role by design so an operator
cannot leave an unknown stale peer record behind for that app.

The Host's editable Bonjour instance name is local-network discovery metadata.
It is bounded, may be visible to untrusted LAN browsers, and must never be
used as an identity, authorization signal, or secret. Changing it does not
change the TLS key or peer trust records.

The optional `Hello.deviceName` is also untrusted, bounded display metadata.
The Host defaults its advertised/device display name to the macOS short
hostname, and the Viewer sends its own short hostname. A Host rename is
reflected in its Hello display name but does not change the certificate,
pairing identity, or authorization. Receivers validate and sanitize this value
before showing it and never use it to select a trust record.

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

An explicit Viewer selection may activate an eligible regular application
and, when the Host already has Accessibility trust, request the public
Accessibility raise action for the exact selected window. The AX window must
match the selected window's global point geometry and, when known, its local
title; a title also disambiguates otherwise identical geometry. Ambiguity or a
known-title mismatch fails closed. This
is not background control: Host-side input remains rejected unless WindowServer
confirms the selected target is foreground-eligible, authorized, and permitted
at the time of each event. AXRaise is only a best-effort local focus action;
it neither grants input authority nor replaces the per-event focus check.
Because a remote selection changes the Host's frontmost app, the Host shows
it locally: the menu-bar icon is tinted while a window is shared, and the
status menu names the app and states when the Viewer brought it to the front.
The app name is local UI only; it is not logged or sent to the Viewer.

## macOS permission boundaries

The user-approved M10 input-source extension is another protected keyboard
operation, not an exception to the input-safety predicate above. It requires
both `keyboardInput` and `inputSourceSync`, the selected generation, and a
fresh foreground/target/permission/console/secure-input check immediately
before changing the Host's selected source. Host source selection must run
inside the synchronous session-admission fence and the window-replacement
barrier; an intervening revocation cannot admit queued old work.

The Viewer sends a bounded source identifier only through the authenticated
control channel. It is not an identity, authorization credential, arbitrary
text-insertion command, or diagnostic field. Neither endpoint logs source
identifiers, input-method names, raw keys, or platform error descriptions.
Missing Chinese sources fail closed without installing/enabling input methods
or selecting a different Chinese mode. Acknowledgements and pending keyboard
delivery are scoped to the original session, authorization epoch, window,
and request ID. Losing Viewer surface focus stops new source requests and
invalidates pending keyboard delivery; an operation already admitted by Host
can complete. There is no background restoration of the Host's prior source. See
[ADR-0007](decisions/0007-m10-input-source-following.md).

- Screen Recording is required for Host-side ScreenCaptureKit capture.
- PostEvent permission is required for Host-side Quartz keyboard, pointer, and
  scroll injection. Accessibility is optional for secure-input inspection and
  best-effort exact-window raising, and is never treated as a substitute for
  PostEvent permission.
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
- Disable or reject input if the Host loses PostEvent permission, the
  selected window closes/changes, the window is no longer foreground-eligible,
  or the session state becomes uncertain.
- Never send or log passwords, secure-input contents, or authentication-dialog
  interaction as a V1 feature.
- A malformed input event must fail closed without partially applying a
  sequence of unrelated events.

M6 enforcement is split explicitly:

- `TransportCore` admits the authenticated message, `Apps/Host` supplies the
  current session and selected-window facts, and
  `InputCore.HostInputController` performs the final per-event check.
- `CoreGraphicsAccessibilityContextProvider` rechecks PostEvent permission,
  optional AX secure-input state, current bounds, on-screen window identity,
  foreground ordering, and lock state.
- Each typed command carries the target window, owning application
  identifier, process, and generation.
  `CoreGraphicsAccessibilityInputAdapter` repeats the complete
  target/focus/permission check immediately before posting and never
  activates a background window.
- A known secure-input field is rejected. When the optional Accessibility
  signal is unavailable, the independent foreground/window checks still
  protect the base PostEvent path. No private API or bypass is used.

Held-input cleanup (release-before-clear, target-bound release after
revocation, selection-change ordering, permission-loss pending cleanup,
cleanup retry after stream end, queued-input discard, and the admission
fence) is specified as a state diagram with numbered invariants in
[Host input admission and cleanup](ARCHITECTURE.md#host-input-admission-and-cleanup).

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

The M10 runtime enrolls each endpoint's own private identity locally in its
login Keychain on first use. `SecurityCore` generates a non-exportable P-256
private key and a matching self-signed TLS certificate, then supplies the
resulting `SecIdentity` to Network.framework. Normal pairing does not require
an operator to import `host.p12`/`viewer.p12` or copy the other endpoint's
certificate; peer trust is stored only after the existing two-sided pairing
consent completes. The M10 Host and Viewer use distinct Keychain identity
labels and peer-trust services, including when both apps run under one macOS
account. A legacy `MACREMOTEAPP_LOCAL_IDENTITY_LABEL` diagnostic value is
role-suffixed before use. The apps therefore do not read or sign with each
other's generated private key. Trust records and local identities from the
older shared namespace are not migrated or deleted during upgrade; new code
does not consult those old trust records, so the operator must pair once again.
A private key is never copied between devices.

## Security non-goals and residual risks

V1 does not protect against a Host or Viewer that is already compromised, a
malicious user with local administrative control, physical memory inspection,
or a user who intentionally approves a rogue pairing code. The product must
make these assumptions visible in documentation and must not claim protection
that the implementation does not provide.

Any missed control, unverified cryptographic configuration, or environment-only
test limitation must be recorded as an open security risk before V1 release.

## Decision records

The M2 TLS identity, commit/reveal pairing, key-provisioning, and revocation
decisions, including the deployment-specific key-handling items that remain
open validation, are recorded in
[ADR-0002](decisions/0002-m2-tls-identity-and-pairing.md). The M6 Host input
binding is [ADR-0005](decisions/0005-m6-host-input-binding.md). Loopback,
deterministic, and physical evidence status is tracked in
[the status page](STATUS.md).
