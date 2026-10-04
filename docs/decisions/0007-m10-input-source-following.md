# ADR-0007 — M10 Viewer-led input-source following

## Context and authorization

The user explicitly approved implementation, commit/push, and a new notarized
test build on 2026-10-04. This is a narrow M10 extension to the accepted
keyboard journey. It supersedes the rule that the operator must manually
align Host input sources; physical key transport and Host-side IME composition
remain unchanged. It does not authorize Viewer-side text composition, Unicode
text insertion, dictation, background control, or installation of input methods.

## Decision

- Viewer is the authority for the desired Chinese/English input-source state.
  Observe the actual selected macOS input source, not the press of a toggle.
  The Host sets a requested state; it never replays a toggle to infer it.
- An English request leaves an already-English Host source unchanged. A
  Chinese request uses the exact enabled Host input-source identifier matching
  the Viewer (including the input mode). Never silently substitute Pinyin for
  Zhuyin or enable/install a missing input source. An English transition from
  Chinese prefers the requested enabled English source, with an existing
  enabled English layout as a bounded local fallback.
- New peers negotiate optional `inputSourceSync` capability `0x0009`, keeping
  protocol `2.0`. Older peers remain usable with manual Host input-source
  selection and never receive the new messages.
- `InputSourceSelection` (`0x0019`, Viewer to Host) carries a nonzero
  `windowGeneration`, a nonzero monotonically increasing `requestID`,
  `KeyboardInputSourceKind` (`english = 1`, `chinese = 2`), and a bounded
  `sourceIdentifier` (1–256 UTF-8 bytes, no control characters).
- `InputSourceAcknowledgement` (`0x001A`, Host to Viewer) carries the same
  generation/request ID and `InputSourceSelectionStatus`: `applied = 1`,
  `unavailable = 2`, `denied = 3`, or `failed = 4`. It carries no text or
  arbitrary diagnostic string. Both messages use the existing canonical
  field codec and ordered control channel, with a maximum 512-byte payload.
- Both messages require selected-window authorization plus `keyboardInput`
  and `inputSourceSync`. They participate in every protected-queue invalidation
  path. Sending and acknowledgement handling are bound to the original local
  session, authorization epoch, window generation, and request ID.
- Host selection runs inside the non-reentrant session admission fence and
  the selected-window replacement barrier. Immediately before OS selection it
  rechecks the same foreground, target identity, permission, console, and
  secure-input conditions used for keyboard injection. Source synchronization
  is not a permission or focus bypass.
- Viewer synchronization is active only in the focused remote input surface
  of an authorized session. Initial control, a source change, surface reentry,
  window replacement, and reauthorization require a fresh acknowledgement.
  Leaving the surface invalidates pending synchronization and stops new
  requests. An operation already admitted by Host can complete; the Viewer
  does not issue a background restore or a new source change.
- A bounded gate preserves input ordering across synchronization. Keyboard
  input must not reach the Host under an unacknowledged source. Newer source
  requests supersede older pending work, and late acknowledgements cannot
  release another session/epoch/window/request. Timeout/failure stops pending
  keyboard input and shows an actionable state; no silent English fallback
  after failed Chinese synchronization. Mouse control may remain available.
- Switching shortcuts are local to the Viewer and must not toggle the Host a
  second time. Observe source changes made by macOS system shortcuts and
  release modifiers previously sent remotely in order. JIS Eisu can select a
  supported English source locally; ambiguous Eisu selection and JIS Kana's
  Japanese/internal mode show a manual-selection limitation and are not
  replayed as Host toggles while following is enabled.
- Input-source identifiers, names, raw keys, and arbitrary platform errors are
  not logged. Local sanitized status can show synchronized/pending/unavailable;
  third-party IME internal modes that are not exposed as macOS input sources
  are not claimed supported.

## Ownership and verification

`RemoteProtocol` owns the two wire records. `TransportCore` owns direction,
capability/window/epoch admission and queue invalidation. `InputCore` owns
platform-neutral source selection policy and the public macOS TIS adapter
behind fakes. The app layers own source observation, focused-surface lifetime,
ordering/acknowledgement gates, and UI. No new package or dependency is needed.

Deterministic tests must cover EN/EN no-op, Chinese to EN, EN to matching
Chinese, Chinese no-op, missing/disabled/mismatched source, safe rejection,
codec bounds/direction/capabilities, same-window reauthorization, queued and
late acknowledgements, timeout, focus loss, shortcuts, held-state cleanup,
and older-peer compatibility. Real TIS/IME behavior and Intel-to-Apple-Silicon
control remain manual acceptance evidence; tests must not change the local
desktop input source automatically.
