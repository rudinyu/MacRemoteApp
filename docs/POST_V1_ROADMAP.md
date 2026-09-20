# Post-V1 Roadmap

## Status and boundary

This is a planning document only. None of the capabilities listed here is
implemented or implied by the M10 V1 release candidate. V1 remains a LAN-only
session between one Host and one Viewer for one foreground-eligible window,
with H.264 video, mouse/keyboard input, and opt-in text clipboard.

Every roadmap item needs its own protocol, threat-model, consent, performance,
and physical acceptance gate. A future item must not be enabled as a hidden
fallback in the V1 runtime.

## Proposed sequence

| Stage | Capability | Reason for order | Required decision gate |
| --- | --- | --- | --- |
| P0 | V1 stabilization | Complete the physical Intel Host to Apple Silicon Viewer acceptance and collect real latency/resource evidence before expanding scope. | M10 acceptance report, release rollback plan, and security residuals are closed or explicitly accepted. |
| P1 | Multi-window | Extends the existing window-list/selection model before adding more media or network complexity. | New session/window generations, focus rules, UI affordances, and authorization tests prove that input cannot cross windows. |
| P2 | Audio | Adds a second real-time media stream while remaining LAN-first. | Explicit capture/playback consent, mute state, bounded jitter/backpressure behavior, privacy review, and synchronized A/V measurements. |
| P3 | WebRTC transport evaluation | Introduces a transport option only after the measured TCP baseline and media/control separation are understood. | Codec/security/ICE policy, certificate identity binding, permission model, fallback behavior, and a documented reason TCP is insufficient. |
| P4 | Internet relay and NAT traversal | Depends on a reviewed transport abstraction and a service threat model; this is a new trust and availability boundary. | Relay authentication, end-to-end identity continuity, abuse/rate controls, metadata minimization, billing/operations ownership, and opt-in network policy. |
| P5 | Secure file transfer | Adds durable user data movement and therefore a larger privacy and malware surface. | Explicit per-transfer approval, path sandboxing, size/type/rate limits, cancellation, integrity, audit redaction, and no implicit clipboard/file sharing. |
| P6 | Background control | Changes the V1 foreground/focus safety invariant and must not be treated as an input mapping tweak. | Product re-approval, OS authorization study, target-selection UX, visible active-target indicator, per-session consent, and fail-closed focus loss tests. |
| P7 | Locked-screen control research | This is not a committed feature. It may be infeasible or unsafe under macOS login-window and secure-input rules. | Separate security review and user decision; no implementation milestone is authorized unless an explicit threat model, OS support matrix, recovery path, and consent design are approved. |

## Cross-stage dependencies

```text
M10 physical acceptance
        |
        v
 multi-window -----> audio --------------------+
        |                                       |
        +-----> transport evaluation (WebRTC) --+--> Internet relay
                                                        |
                                                   file transfer

 foreground authorization review ---> background control
                                    \
                                     ---> locked-screen research gate
```

WebRTC and Internet relay are separate decisions: WebRTC may be useful on a
LAN, but adopting it does not authorize an Internet service. A relay must not
terminate or silently replace the device-identity trust model. Likewise,
background or locked-screen control must not inherit the existing foreground
authorization just because a session is already paired.

## Non-negotiable security rules for later work

- Preserve Keychain-backed device identity and explicit peer trust. Never make
  discovery, a relay account, or a short pairing code the sole authorization.
- Keep Host authorization separate from transport authentication. Pairing never
  grants window, audio, file, background, or locked-screen authority by itself.
- Add explicit user consent for every new data class: audio, files, and any
  target outside the foreground selected-window policy.
- Keep bounded queues, cancellation, freshness, and redacted diagnostics for
  every new channel. Do not log media, file names when sensitive, tokens, or
  raw input.
- Maintain a documented downgrade path to the V1 LAN/TCP mode only when the
  downgrade is safe and visible; never silently weaken authentication.

## Planning outputs for each future milestone

Before implementation, update the product, architecture, protocol, security,
and development-plan documents with one named milestone. That milestone must
define the wire changes, ownership package, migration/versioning story,
permission UX, deterministic tests, physical test matrix, performance target,
rollback behavior, and release evidence. Until then, these capabilities remain
roadmap items and are intentionally absent from the M10 code path.
