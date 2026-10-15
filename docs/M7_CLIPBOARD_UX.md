# M7 Text Clipboard and Session UX

## Status

The M7 implementation and deterministic test gate is complete. The actual
Intel Host to Apple Silicon Viewer pasteboard walkthrough remains a physical
environment evidence item for M10 acceptance.

## Ownership and enforcement

M7 keeps the existing package boundaries explicit:

| Layer | M7 responsibility |
| --- | --- |
| `RemoteProtocol` | Bounded `ClipboardOffer`, `ClipboardText`, and `ClipboardAcknowledgement` schemas, UTF-8 validation, and the optional status-only `hasText` field |
| `TransportCore` | `ClipboardSyncCoordinator` state machine, transient-buffer clearing, Offer/ACK admission policy, and redacted `SessionUXProjection` |
| `Apps/Host` | Host-side `NSPasteboard` string bridge, enabled only for a trusted paired peer with the negotiated capability |
| `Apps/Viewer` | Viewer-side `NSPasteboard` string bridge and the operator's session-local opt-in UI |

The AppKit bridges never write directly to the transport. They call
`SessionCoordinator.send`, so TLS/authentication, capability negotiation, and
authorization remain enforced by `TransportCore`. The bridge reads and writes
only `NSPasteboard`'s public `.string` type; images, files, rich text, and
arbitrary pasteboard types are not transferred.

## Clipboard policy

- The Host enables its local bridge automatically after authenticated pairing
  trust and text-clipboard capability negotiation. The Viewer remains
  default-off and requires its operator's explicit session-local opt-in before
  it reads or writes clipboard text. There is no separate Host clipboard
  prompt.
- Enabling or disabling uses a status-only `ClipboardOffer` with
  `hasText = false`; an empty string remains a valid text transfer because it
  uses `hasText = true` and is followed by `ClipboardText`.
- A text change sends an Offer first. The receiver validates the origin,
  generation, opt-in state, and UTF-8 byte bound, then sends an
  `ClipboardAcknowledgement`. Only an accepted Offer releases the matching
  `ClipboardText` for delivery.
- The default logical bound is 65,515 UTF-8 bytes. The effective bound is the
  minimum of both Hello limits and remains within the 64 KiB control payload
  limit, including the 21-byte canonical `ClipboardText` overhead.
- A pending local Offer wins a concurrent remote Offer. If the local user edits
  after a remote Offer was accepted but before its text arrives, the incoming
  transfer is cancelled and the new local generation wins. Replayed or stale
  generations are rejected.
- If a local Offer is waiting for its acknowledgement, the newest local
  pasteboard change is retained in one bounded slot and emitted only after the
  current transfer completes. A failed clipboard send resets both endpoints'
  transient transfer state and closes the session, rather than leaving one
  peer with an accepted Offer that the other peer can no longer complete.
- If a native local change is non-text or exceeds the negotiated bound while a
  peer has already accepted a text Offer, the sender emits a newer status-only
  cancellation Offer. The receiver clears the pending incoming generation and
  can accept the next text Offer instead of retaining a stale conflict.
- A received text is marked with its origin/generation in transient memory.
  The AppKit bridge consumes that marker immediately after the programmatic
  pasteboard write; a later user copy of the same text is therefore not
  suppressed. No clipboard text, hash, or full diagnostic is logged.
- Stop, authorization loss, transport failure, and reconnect call `reset()`.
  That clears pending text, pending offers, echo markers, and local/remote
  enablement. On a new authorized session, the Host reuses pairing trust to
  enable its bridge after capability negotiation; the Viewer must opt in again
  for that session.

## Session UX projection

`SessionUXProjection` converts the authenticated `SessionSnapshot` plus
app-owned facts into a redacted `SessionUXSnapshot`. Its primary state
distinguishes discovered, connecting, pairing-required, paired, authenticated,
authorized, streaming, reconnecting, stopping, and failed. Its indicators can
simultaneously show authenticated, paired, authorized, streaming, input-ready,
clipboard-enabled, degraded, reconnecting, stopping, or failed.

Input-ready requires authorization, granted permission, and no degraded state.
Clipboard-enabled requires authorization, the negotiated text-clipboard
capability, Host pairing trust, Viewer-local opt-in, and no degraded state.
Missing or revoked permission therefore remains visibly degraded and removes
both ready indicators without pretending that the session is disconnected.

## M10 app-shell integration

In the production Viewer, the remote view and Settings are two pages of one
main window. The Host reuses accepted pairing trust to enable its local
clipboard bridge on reconnect when the capability is negotiated; only the
Viewer retains a per-session clipboard opt-in.
Connection/input/clipboard values feed both from the same app-owned state;
Settings does not establish another session or persist a second clipboard
preference. Its clipboard checkbox calls the existing session opt-in action
and is unavailable when the current session cannot offer the capability.
Disconnect/reconnect clears transient clipboard state and Viewer opt-in.

Settings is reached through the local native menu (Command-,). Back,
Command-0, or Close on Settings restores the remote view and input surface.
Page switching preserves the session but releases held input when the surface
leaves the window. A disconnected Viewer reports input as Not connected rather
than Authenticating. Host Settings displays permission/runtime facts without
granting authorization. Full navigation and ownership are specified in the
[UI architecture](ARCHITECTURE.md#native-app-shell-and-release-identity).

## Validation

The deterministic tests cover:

- Host trusted-pairing authorization without a Host prompt and Viewer
  default-off per-session opt-in;
- status-only enablement, Offer/ACK/Text ordering, UTF-8 byte limits, and
  malformed acknowledgement reason combinations;
- origin/generation matching, echo suppression, replay/conflict handling, and
  near-simultaneous edits;
- authorization-loss reset through the Host and Viewer session lifecycles;
- authorization and capability revalidation immediately before applying a
  received text value;
- newest-change queuing while an Offer is awaiting ACK, plus send-failure
  session reset and peer-disable queue cleanup;
- reset on disconnect/reconnect and redacted UX states under permission loss;
- protected clipboard message direction/capability admission through
  `SessionCoordinator`.

The public validation scripts also permit `NSPasteboard` only in the Host and
Viewer app targets. WebRTC, audio, and other later-milestone APIs remain
forbidden. A physical pasteboard walkthrough still requires signed bundles,
an authenticated two-machine session, and operator confirmation on both Macs;
it is not claimed by the deterministic package tests.

## Manual walkthrough when the two Macs are available

1. Build the signed Host and Viewer bundles using
   `scripts/package-device-apps.sh` and install one on each target Mac.
2. Pair the Viewer with the Host, accept pairing on both peers, and confirm
   that negotiated Host clipboard capability is available without a second
   Host prompt.
3. Leave the Viewer clipboard toggle disabled and change text on either Mac;
   no clipboard text should flow.
4. Enable clipboard only in Viewer Settings. Copy a short Unicode string in
   either direction and verify one update arrives without bouncing back.
5. Try a non-text pasteboard item and a text value above the negotiated bound;
   both must be rejected without exposing their contents in logs.
6. Change text on both sides close together and verify the documented arrival-
   order policy. Disconnect/reconnect and confirm the Host reuses pairing trust
   without a prompt while the Viewer toggle returns to off.
7. In the production GUI, toggle clipboard sharing from Viewer Settings and
   return to the remote view. Confirm both pages report the same state and
   navigation alone neither resets nor enables sharing. Run the connected
   navigation/input-release checks in [M10 acceptance](M10_ACCEPTANCE.md).
8. After collecting sanitized evidence, follow
   [UI Review and Post-test Cleanup](TESTING_CLEANUP.md). A local Settings
   walkthrough does not replace the physical clipboard or input checks.
