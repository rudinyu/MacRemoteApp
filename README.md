# MacRemoteApp

MacRemoteApp is a LAN-first macOS application remote-view and control tool.
An Intel Mac acts as the Host and an Apple Silicon Mac acts as the Viewer. The
Viewer sees and interacts with one selected macOS application window on the
Host; this is deliberately not a full remote-desktop product.

## Current status

The M0 Repository Foundation is now present. The repository contains the
planning documents plus a Swift Package Manager skeleton with separate Host and
Viewer executable targets, six local shared packages, and deterministic local
build/test validation. It still contains no product capability implementation.

The repository root is:

```text
MacRemoteApp/
├── AGENTS.md
├── README.md
├── Package.swift
├── Apps/
│   ├── Host/
│   └── Viewer/
├── Packages/
│   ├── RemoteProtocol/
│   ├── CaptureCore/
│   ├── CodecCore/
│   ├── TransportCore/
│   ├── InputCore/
│   └── SecurityCore/
├── Tests/
├── .codex/
│   └── ci.sh
└── docs/
    ├── ARCHITECTURE.md
    ├── DEVELOPMENT_PLAN.md
    ├── M0_FOUNDATION.md
    ├── PRODUCT_SPEC.md
    ├── PROTOCOL.md
    └── SECURITY.md
```

The implementation repository is expected to grow toward this shape, while
keeping the package boundaries described in `docs/ARCHITECTURE.md`:

```text
MacRemoteApp/
├── Package.swift
├── Apps/
│   ├── Host/
│   └── Viewer/
├── Packages/
│   ├── RemoteProtocol/
│   ├── CaptureCore/
│   ├── CodecCore/
│   ├── TransportCore/
│   ├── InputCore/
│   └── SecurityCore/
└── Tests/
```

The exact M0 toolchain and architecture matrix are recorded in
`docs/M0_FOUNDATION.md`. Run `bash .codex/ci.sh` from the repository root for
the repeatable foundation validation.

## V1 in one paragraph

The Host discovers shareable applications/windows, lets the local user select
one window, captures it with ScreenCaptureKit, encodes H.264 with VideoToolbox,
and streams it over an authenticated LAN session. The Viewer discovers and
connects to the Host, renders the stream with Metal, and sends mouse and
keyboard events back to the selected foreground app. Both sides may exchange
text clipboard content according to the consent and privacy rules. The initial
target is 1080p at up to 60 fps with low measured latency.

## Technology baseline

- Swift 6 with strict concurrency checks.
- ScreenCaptureKit for Host-side window capture.
- VideoToolbox for H.264 encode/decode.
- Metal for Viewer-side frame presentation.
- Network.framework for LAN discovery and transport.
- CoreGraphics and Accessibility APIs for authorized input handling.
- Keychain-backed trust records through `SecurityCore`.

V1 does not include Internet NAT traversal, WebRTC, audio, file transfer, iPad
support, simultaneous multi-window control, background control, or
locked-screen control.

## Documents and authority

Read the documents in this order before implementation:

1. `AGENTS.md` — agent workflow and repository constraints.
2. `docs/PRODUCT_SPEC.md` — user-visible behavior and acceptance targets.
3. `docs/ARCHITECTURE.md` — components, boundaries, and dependencies.
4. `docs/PROTOCOL.md` — session, framing, media, input, and clipboard design.
5. `docs/SECURITY.md` — threats, pairing, permissions, and privacy controls.
6. `docs/DEVELOPMENT_PLAN.md` — M0-M10 scope and verification gates.

The user's current request and later explicit corrections take precedence over
stale assumptions. Any resulting design change should be recorded in the
appropriate document before implementation.

## Roadmap

| Milestone | Outcome |
| --- | --- |
| M0 | Repository Foundation and build/test skeleton |
| M1 | RemoteProtocol types, framing, codec tests, and versioning |
| M2 | Secure LAN discovery, pairing, and session lifecycle |
| M3 | Host window discovery and ScreenCaptureKit capture |
| M4 | H.264 encode/decode and Metal presentation |
| M5 | Viewer mouse/keyboard capture and event transport |
| M6 | Host-side focus-aware input mapping and injection |
| M7 | Text clipboard synchronization and session UX |
| M8 | Latency, frame-rate, backpressure, reconnect, and resilience work |
| M9 | Security hardening, permission/error review, and release readiness |
| M10 | Intel-to-Apple-Silicon V1 integration pilot and acceptance |

Each milestone is independently scoped in `docs/DEVELOPMENT_PLAN.md`. Do not
skip a gate because a later feature appears easy to prototype.

## M0 implementation prompt (reference)

M0 is complete. The original implementation prompt is retained below as a
scope record; the next authorized implementation milestone is M1.

Copy the following prompt into Codex after opening this directory as the
repository root:

```text
你現在在 MacRemoteApp repository 執行唯一的 M0 Repository Foundation。

先完整閱讀：
1. AGENTS.md
2. docs/PRODUCT_SPEC.md
3. docs/ARCHITECTURE.md
4. docs/PROTOCOL.md
5. docs/SECURITY.md
6. docs/DEVELOPMENT_PLAN.md

本次只做 M0，不要實作任何產品功能。請建立最小、可建置、可測試的
Swift 6 repository skeleton，包含：

- Apps/Host 與 Apps/Viewer 的最小 target 或 placeholder structure；
- Packages/RemoteProtocol、CaptureCore、CodecCore、TransportCore、
  InputCore、SecurityCore 的最小 package/module structure；
- 可重複執行的 build/test validation（若適合，建立 .codex/ci.sh）；
- 清楚記錄已確認的 Swift、Xcode、macOS deployment target 與 Intel/Apple
  Silicon build matrix；
- 最小 smoke tests，確認 targets/modules 可以被建置與測試。

嚴格禁止本次加入：

- ScreenCaptureKit capture logic；
- VideoToolbox encode/decode logic；
- Metal renderer；
- Network.framework discovery/transport；
- CoreGraphics 或 Accessibility input injection；
- clipboard synchronization；
- pairing/authentication implementation；
- WebRTC、audio、file transfer、NAT traversal、iPad、multi-window、
  background control 或 locked-screen control。

遵守模組邊界，不新增未經文件化理由的第三方 dependency。先檢查工作樹，
保留既有使用者變更。完成後執行 .codex/ci.sh（若存在）或等價的 deterministic
build/test，並回報：

1. M0 scope 與實際變更檔案；
2. 每個 validation command 與結果；
3. Intel Host 與 Apple Silicon Viewer 的已驗證/待驗證項目；
4. 任何未決設計或環境限制；
5. 確認沒有加入產品功能或後續 milestone 工作。

不要 commit、push 或修改全域 Codex 設定，除非我另外明確要求。
```
