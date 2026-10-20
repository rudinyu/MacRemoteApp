# ADR-0008 — M10 Viewer-side text composition

## Context and authorization

Physical Build 1039 testing found that Chinese input could not be used: the
Host input method composed the text, but its candidate window is a separate
input-method window outside the captured app window, so the Viewer never saw
it. English typing was unaffected. The user explicitly chose Viewer-side
composition on 2026-10-20. This ADR supersedes the parts of ADR-0007 and the
M6 keyboard policy that excluded Viewer-side composition and Unicode text
insertion. Physical key forwarding, ADR-0007 source following for English,
dictation exclusion, and every Host safety check remain unchanged.

## Decision

- New peers negotiate optional `textInput` capability `0x000B` under protocol
  `2.0`. Older peers never negotiate it, never receive text events, and keep
  Host-side composition with physical keys.
- `InputEvent` gains kind `text = 7` and optional field 12 `text` (UTF-8,
  1–256 bytes, no Unicode control characters). A `text` event carries no
  coordinate, button, delta, key code, or modifier fields; other kinds must
  not carry field 12. Longer commits are split on character boundaries.
- Admission requires selected-window authorization plus `keyboardInput` and
  `textInput` (and the P6 control generation when negotiated). Text events
  use the same ordered input stream, sequence numbers, rate limiter, admission
  fence, and protected-queue invalidation as key events, so key/text order is
  preserved. The Host authorizes `textInput` only together with keyboard input.
- The Viewer composes with its own input method only when `textInput` is
  negotiated, keyboard input is ready, and its current macOS input source is a
  Chinese input method. The remote surface is then an `NSTextInputClient`:
  marked text and candidate selection stay on the Viewer (an inline label
  shows the marked text; the candidate window is placed at the last pointer
  position in the remote content). Only committed text is sent. Keys the input
  method does not use (Return, Delete, arrows, Escape with no marked text) and
  every Command/Control shortcut are forwarded as physical keys. Composition is
  discarded, not sent, on focus loss or when input stops being ready.
- While local composition is active, ADR-0007 source following asks the Host
  for an English source, so no Host input method re-composes forwarded keys.
  English typing on the Viewer keeps the physical-key path unchanged.
- The Host posts committed text as key-down/key-up pairs carrying a Unicode
  string (`keyboardSetUnicodeString`), at most 20 UTF-16 units per event and
  never splitting a character. Each event passes the same final target,
  generation, permission, foreground, console, and secure-input checks as a
  key; a detected secure-input field rejects text. Text events create no held
  input state.
- Text content is a raw input value: it is never logged, put in error strings,
  status, receipts, or diagnostics. Debug diagnostics count `text` events by
  kind only. `scripts/validate.sh` allows `NSTextInputClient`/`insertText` only
  in `Apps/Viewer/ViewerInputSurface.swift` and `keyboardSetUnicodeString` only
  in the Host adapter; character translation, Unicode string reading,
  `interpretKeyEvents`, and secure-input bypass APIs stay forbidden.

## Consequences

- A few apps that ignore Unicode keyboard events (for example some games)
  may not accept committed text; physical keys still work there.
- The candidate window follows the last pointer position, not the remote
  text caret, which the Viewer cannot observe.
- Real input-method behavior and the Intel-to-Apple-Silicon path remain manual
  acceptance evidence. Deterministic tests cover the codec bounds and
  capability gating, record validation and splitting, Unicode event chunking,
  Host mapping, Viewer marked/committed text handling, and the English Host
  target during local composition.

## Ownership

`RemoteProtocol` owns the capability, kind, and field codec. `TransportCore`
owns capability admission. `InputCore` owns the record model, splitting, and
the Host Unicode adapter. `Apps/Viewer` owns the text input client and source
following bridge; `Apps/Host` owns capability authorization. No new package or
dependency is introduced.
