# M1 RemoteProtocol Wire Contract

M1 fixes the first interoperable, deterministic wire representation for
`Packages/RemoteProtocol`. The implementation is Foundation-only. It defines
types, serialization, deserialization, bounded parsing, and test vectors; it
does not open sockets or perform discovery, authentication, capture, codec,
input, or clipboard side effects.

## Envelope

All integer fields use network byte order (big-endian). The envelope header is
exactly 31 bytes followed by `payloadLength` bytes:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic: ASCII `MRP1` (`4D 52 50 31`) |
| 4 | 1 | Protocol major version |
| 5 | 1 | Protocol minor version |
| 6 | 1 | Channel |
| 7 | 2 | Message type |
| 9 | 2 | Flags |
| 11 | 4 | Payload length |
| 15 | 8 | Per-channel sequence |
| 23 | 8 | Sender monotonic timestamp |
| 31 | N | Payload |

The current version is `2.0`. Version `2.0` makes the M10 commit/reveal pairing
flow and window-catalog generations explicit. A peer accepts the same major
version with a minor version less than or equal to its supported minor version.
The legacy `1.x` wire contract is intentionally incompatible and is rejected
before payload parsing.

Channels are fixed as:

| Value | Channel | Default message families |
| ---: | --- | --- |
| `0x00` | Control | Handshake, authorization, window, input, clipboard, liveness, state, errors, close |
| `0x01` | Media | `VideoConfig`, `VideoFrame` |

Defined envelope flags are:

| Bit | Value | Meaning |
| ---: | ---: | --- |
| 0 | `0x0001` | Keyframe |
| 1 | `0x0002` | Acknowledgement |
| 2 | `0x0004` | End of stream |
| 3 | `0x0008` | Must understand |

Unknown flag bits are rejected. An unknown message type is skippable only when
the `mustUnderstand` flag is absent; an unknown mandatory message type is a
protocol error.

The default limits are:

| Limit | Default |
| --- | ---: |
| Maximum envelope payload | 1 MiB |
| Maximum control payload, including `ClipboardText` | 64 KiB |
| Maximum clipboard UTF-8 bytes | 65,515 bytes |
| Maximum field value | 1 MiB |
| Maximum identifier bytes | 256 |
| Maximum window entries | 256 |
| Maximum capabilities | 128 |

`FrameParser` accepts arbitrary partial reads. It does not allocate based on a
length that exceeds the configured limits. `ClipboardText` is a control-channel
message, so its encoded payload must fit the same 64 KiB control-envelope cap.
The default logical UTF-8 limit is 65,515 bytes: the canonical `ClipboardText`
payload has 21 bytes of schema/field overhead, leaving the complete encoded
payload at or below 65,536 bytes. A peer may advertise a lower limit; the
effective control limit and clipboard limit are both the minimum of the local
and remote values, with encoding overhead still applied.

The first sequence on each channel may be any value. Control sequences must be
strictly contiguous and control/media sequences are independent. Media
sequences must be strictly increasing; a bounded queue may discard delta video
frames under the keyframe-aware policy in `docs/PROTOCOL.md`, so the receiver
may observe a forward gap in the media sequence. It must never drop `VideoConfig` or a required
recovery keyframe locally, and a non-increasing media sequence is still a
replay/protocol error.

The envelope golden vector in the unit tests is:

```text
MRP1 01 00 00 0001 0002 00000002 0000000000000001 0000000000000002 DE AD
4D525031010000000100020000000200000000000000010000000000000002DEAD
```

## Payload encoding

Every known message payload uses schema version `0x01` as its first byte. It
then contains zero or more strictly increasing fields:

```text
schemaVersion: u8
field:
  fieldID: u8          // non-zero, ascending
  fieldFlags: u8       // bit 0 = mandatory; all other bits are reserved
  fieldLength: u32
  value: fieldLength bytes
```

Unknown optional fields are ignored. Unknown mandatory fields, duplicate field
IDs, out-of-order field IDs, reserved field flags, invalid UTF-8, and malformed
fixed-width values fail closed. Fixed-width numbers are big-endian. Strings
are bounded UTF-8. Binary values are bounded `Data` fields and are not
interpreted by this milestone.

Capability lists are encoded as `count: u16` followed by ascending `u16`
entries. The low 15 bits are the capability identifier; bit 15 marks a
mandatory capability. Unknown optional identifiers are retained as
`.unknown(id)`. Unknown mandatory identifiers fail with
`unknownMandatoryCapability`. Duplicate, zero, or out-of-order identifiers
are rejected.

## Identifiers

### Message types

| Value | Message |
| ---: | --- |
| `0x0001` | Hello |
| `0x0002` | Capabilities |
| `0x0003` | PairingChallenge |
| `0x0004` | PairingConfirmation |
| `0x0005` | SessionAuthorize |
| `0x0006` | WindowList |
| `0x0007` | WindowSelection |
| `0x0008` | StreamConfig |
| `0x0009` | VideoConfig |
| `0x000A` | VideoFrame |
| `0x000B` | InputEvent |
| `0x000C` | ClipboardOffer |
| `0x000D` | ClipboardText |
| `0x0013` | ClipboardAcknowledgement |
| `0x000E` | Ping |
| `0x000F` | Pong |
| `0x0010` | SessionState |
| `0x0011` | Error |
| `0x0012` | Close |
| `0x0017` | KeyframeRequest (M8, optional capability) |

### Capabilities

| Value | Capability |
| ---: | --- |
| `0x0001` | H.264 video |
| `0x0002` | Window selection |
| `0x0003` | Mouse input |
| `0x0004` | Keyboard input |
| `0x0005` | Text clipboard |
| `0x0006` | Ping/pong |
| `0x0007` | Keyframe request (M8, optional) |

`0x8000` is a wire-only mandatory marker and is not part of the identifier
value. `CodecIdentifier.h264` is `0x0001`.

## Stable message schemas

The notation below uses `u8`, `u16`, `u32`, `u64`, and `i32` for fixed-width
values; `utf8` for bounded UTF-8; `bytes` for bounded binary data; `bool` for
the canonical one-byte values `0x00` and `0x01`; and `capabilities` for the
capability list above.

| Message | Fields in ascending field ID |
| --- | --- |
| `Hello` | 1 `version` (2 bytes), 2 `role` (u8), 3 `implementationIdentifier` (utf8), 4 `maxPayloadLength` (u32), 5 `maxControlPayloadLength` (u32), 6 `maxClipboardTextBytes` (u32), 7 `deviceName` (utf8, optional, max 63 bytes; display-only) |
| `Capabilities` | 1 `capabilities`, 2 `maxVideoWidth` (u32, optional), 3 `maxVideoHeight` (u32, optional), 4 `maxFrameRate` (u16, optional) |
| `PairingChallenge` | 1 `challengeID` (u64), 2 `confirmationCode` (utf8, legacy optional), 3 `commitment` (32-byte bytes, production required) |
| `PairingConfirmation` | 1 `challengeID` (u64), 2 `accepted` (bool), 3 `confirmationCode` (utf8, optional) |
| `PairingResponse` | 1 `challengeID` (u64), 2 `commitment` (32-byte bytes) |
| `PairingVerification` | 1 `challengeID` (u64), 2 `contribution` (32-byte bytes) |
| `PairingReveal` | 1 `challengeID` (u64), 2 `contribution` (32-byte bytes) |
| `SessionAuthorize` | 1 `authorized` (bool), 2 `windowGeneration` (u64, optional), 3 `capabilities` |
| `WindowList` | 1 `windows`: count u16 followed by length-prefixed nested window records, 2 `catalogGeneration` (u64) |
| `WindowSelection` | 1 `windowIdentifier` (u64), 2 `windowGeneration` (u64), 3 `catalogGeneration` (u64) |
| `StreamConfig` | 1 `width` (u32), 2 `height` (u32), 3 `frameRate` (u16), 4 `codec` (u16), 5 `generation` (u64) |
| `VideoConfig` | 1 `generation` (u64), 2 `decoderConfiguration` (bytes) |
| `VideoFrame` | 1 `generation` (u64), 2 `captureTimestamp` (u64), 3 `presentationTimestamp` (u64), 4 `width` (u32), 5 `height` (u32), 6 `keyframe` (bool), 7 `accessUnit` (bytes) |
| `InputEvent` | 1 `kind` (u8), 2 `windowGeneration` (u64), 3 `x` (u16, optional), 4 `y` (u16, optional), 5 `button` (u8, optional), 6 `pressed` (bool, optional), 7 `deltaX` (i32, optional), 8 `deltaY` (i32, optional), 9 `keyCode` (u16, optional), 10 `modifiers` (u32, optional) |
| `ClipboardOffer` | 1 `generation` (u64), 2 `origin` (u8), 3 `textByteCount` (u32), 4 `enabled` (bool), 5 `hasText` (bool, optional; defaults to true) |
| `ClipboardText` | 1 `generation` (u64), 2 `text` (bounded UTF-8 bytes) |
| `ClipboardAcknowledgement` | 1 `generation` (u64), 2 `origin` (u8), 3 `accepted` (bool), 4 `reason` (u8) |
| `Ping` / `Pong` | 1 `nonce` (u64) |
| `SessionState` | 1 `state` (u8), 2 `permission` (u8), 3 `focusEligible` (bool), 4 `windowGeneration` (u64, optional) |
| `Error` | 1 `code` (u16), 2 `retryable` (bool), 3 `detailCode` (utf8, optional) |
| `Close` | 1 `reason` (u16), 2 `detailCode` (utf8, optional) |
| `KeyframeRequest` | 1 `generation` (u64), 2 `reason` (u8: 1 media gap, 2 decode failure) |

`WindowList` nested window records use the same TLV format with fields:
1 `identifier` (u64), 2 `applicationIdentifier` (utf8), 3 `title` (utf8,
optional), 4 `width` (u32), 5 `height` (u32), and 6 `eligible` (bool).

`Hello.deviceName` is an optional M10-compatible extension. Older peers may
omit it; implementations that do not recognize optional fields ignore it. It
is bounded and validated for display, but is untrusted metadata: it is never a
peer identity, authorization input, or pairing secret. Host discovery may use
an independently configured Bonjour display name; the Host defaults that name
to its macOS short hostname. A Viewer sends its own macOS short hostname.

## Golden vectors

The following vectors are the canonical payload bytes for the fixed samples in
`RemoteProtocolTests`. They intentionally contain no captured media, secrets,
or clipboard data beyond the literal test string `hello`.

```text
Hello               0101010000000202000201000000010103010000000F4D616352656D6F74654170702D4D3104010000000400100000050100000004000100000601000000040000FFEB
Capabilities        010101000000060002000100060200000000040000078003000000000400000438040000000002003C
PairingChallenge    010101000000080102030405060708020100000006313233343536
PairingConfirmation 01010100000008010203040506070802010000000101030000000006313233343536
SessionAuthorize   01010100000001010200000000080000000000000009030100000006000200010002
WindowList          0101010000005600010000005001010100000008000000000000002A020100000012636F6D2E6578616D706C652E456469746F72030000000008446F63756D656E7404010000000400000500050100000004000002D0060100000001010201000000080000000000000001
WindowSelection     01010100000008000000000000002A02010000000800000000000000090301000000080000000000000001
StreamConfig        010101000000040000078002010000000400000438030100000002003C04010000000200010501000000080000000000000009
VideoConfig         010101000000080000000000000009020100000003010203
VideoFrame          010101000000080000000000000009020100000008000000000000006403010000000800000000000000650401000000040000078005010000000400000438060100000001010701000000050000000165
InputEvent          01010100000001030201000000080000000000000009030000000002014004000000000200B4070000000004FFFFFFFE08000000000400000004
ClipboardOffer      01010100000008000000000000000C020100000001020301000000040000000504010000000101
ClipboardText       01010100000008000000000000000C02010000000568656C6C6F
ClipboardAcknowledgement 01010100000008000000000000000C020100000001020301000000010104010000000101
Ping                010101000000080102030405060708
Pong                010101000000080102030405060708
SessionState        010101000000010802010000000102030100000001010400000000080000000000000009
Error               0101010000000200050201000000010103000000001073637265656E2D7265636F7264696E67
Close               010101000000020001020000000004646F6E65
KeyframeRequest     01010100000008000000000000000902010000000101
```

The test suite asserts the exact bytes above, then decodes and re-encodes every
stable message family to verify deterministic round trips.

## M1 boundary

This contract does not create a transport, Bonjour service, TLS session,
pairing or Keychain record, capture pipeline, VideoToolbox codec, Metal view,
CoreGraphics/Accessibility injection path, or clipboard synchronization. Those
remain owned by later milestones and must consume these types through their
documented package boundaries.
