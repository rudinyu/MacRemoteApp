# M0 Repository Foundation

This document records the original M0 skeleton and its historical evidence.
The current M10 composition additionally includes the app-layer `AppSupport`
package for menus, settings content, and release metadata; see the current
[architecture](ARCHITECTURE.md). The six-package and placeholder descriptions
below describe M0, not the current production executables.

## Project format

M0 uses Swift Package Manager as a small monorepo. The root `Package.swift`
defines the two application targets and depends on six local Swift packages.
Each directory under `Packages/` has its own `Package.swift`, library target,
and smoke test target. This keeps the shared-package boundaries independently
buildable without adding a third-party dependency or an Xcode project before
there is product UI to model.

The root targets are intentionally placeholder executables:

- `Apps/Host` — `Host` executable target.
- `Apps/Viewer` — `Viewer` executable target.

The Host imports the Host-relevant shared modules, while the Viewer imports the
Viewer-relevant modules and does not depend on Host-only `CaptureCore`. Both
print only a foundation marker. No target uses a product framework or
implements a product capability.

## Deployment and toolchain baseline

The package manifests declare macOS 13.0 as the minimum deployment target and
Swift tools version 6.0 with Swift 6 language mode. This is a foundation
baseline; API availability and the final supported macOS range remain subject
to the milestone that introduces each platform API.

The following environment was verified for the M0 skeleton:

| Item | Verified value |
| --- | --- |
| Current architecture | Apple Silicon `arm64` |
| Current OS | macOS 27.0, build `26A428` |
| Xcode | `27.0`, build `27A266a` |
| Swift compiler | Apple Swift `6.4.0.34.1` |
| Package deployment baseline | macOS 13.0 |
| External dependencies | None |

## Architecture matrix

| Role | Intended architecture | M0 foundation status |
| --- | --- | --- |
| Host (V1 integration) | Intel `x86_64` | Verified: `Host` cross-build completed for `x86_64`; runtime/tests on physical Intel hardware remain pending |
| Host (build portability) | Apple Silicon `arm64` | Verified: `Host` build completed for `arm64`; this does not claim a separate Apple Silicon Host product target |
| Viewer | Apple Silicon `arm64` | Verified: root targets, local packages, and smoke tests run natively |

The Host arm64 build, native Viewer arm64 result, and Host x86_64 cross-build
verify only the repository foundation. They do not verify ScreenCaptureKit,
VideoToolbox, Metal, Network.framework, input injection, physical Intel
runtime behavior, or cross-machine interoperability; those belong to later
milestones.

## Repeatable validation

The read-only environment preflight and public validation entry point are:

```sh
bash scripts/check-environment.sh
./scripts/validate.sh
```

The environment check reports the selected full Xcode, Swift compiler and
versions, current architecture, Python 3.9 minimum for full validation, and
Git revision/worktree state. It honors `DEVELOPER_DIR`, otherwise preferring
`/Applications/Xcode.app` and then the full Xcode selected by `xcode-select`.
The no-argument validator remains the full suite: it builds Host arm64/x86_64
and Viewer arm64, runs root and all seven local package tests (including
AppSupport), and checks the deterministic M8/M9/M10 gates. It reuses its
`.build/public-validation/` cache and does not uninstall test apps or clear
their settings. `--quick` reuses a separate cache for package graph checks,
focused validation-tool fixtures, native Host/Viewer debug builds, and root
smoke tests; it does not run full CI. `--clean` removes only the public
validation cache before the selected run. The local `.codex/ci.sh` helper
forwards these options when present, and each run writes a compact environment
and mode report to `.build/public-validation/last-validation-report.txt`. An interrupted
validation may leave `.build/.public-validation.lock`; it is never reclaimed
automatically and must be inspected before manual removal. For the original
M0-only foundation probe, run:

```sh
swift package describe
swift build --configuration debug --arch arm64 --target Host
swift build --configuration debug --arch x86_64 --target Host
swift build --configuration debug --arch arm64 --target Viewer
swift test --configuration debug
```

These commands validate the package graph, build `Host` and `Viewer`, and run
the root smoke test using only local SwiftPM tools and the checked-in source
tree. Each shared package can be validated independently with
`swift test --package-path Packages/<PackageName>`.

The additional Intel-target compile probe used for this handoff was:

```sh
swift build --configuration debug --arch x86_64 --target Host
```

It completed successfully on the current arm64 Mac; it is not a substitute for
running the Host and its tests on physical Intel hardware.

## Deferred decisions and gaps

- Intel `x86_64` runtime behavior requires an Intel Mac or an explicitly
  supported translation environment and is not claimed by this run.
- The final macOS support range, Xcode support range, app bundle/signing
  configuration, and platform API availability checks remain open for the
  milestones that add those concerns.
- The M0 package markers are test scaffolding only and must be replaced by
  milestone-owned contracts; they are not protocol, capture, codec,
  transport, input, security, or clipboard implementations.
