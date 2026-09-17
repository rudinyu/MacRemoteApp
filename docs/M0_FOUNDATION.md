# M0 Repository Foundation

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
| Host | Intel `x86_64` | Verified: `Host` cross-build completed for `x86_64`; runtime/tests on physical Intel hardware remain pending |
| Viewer | Apple Silicon `arm64` | Verified: root targets, local packages, and smoke tests run natively |

The native arm64 result and the x86_64 cross-build verify only the repository
foundation. They do not verify ScreenCaptureKit, VideoToolbox, Metal,
Network.framework, input injection, physical Intel runtime behavior, or
cross-machine interoperability; those belong to later milestones.

## Repeatable validation

From the repository root, run:

```sh
bash .codex/ci.sh
```

The script validates the package graph, rejects forbidden M0 product API
references in Swift source, builds `Host` and `Viewer`, runs the root smoke
test, and runs each shared package's tests. It uses only local SwiftPM tools,
the checked-in source tree, and workspace-local build/cache directories.

The additional Intel-target compile probe used for this handoff was:

```sh
swift build --configuration debug --arch x86_64 --target Host
```

It completed successfully on the current arm64 Mac; it is not a substitute for
running the Host and its tests on physical Intel hardware.

## Deferred decisions and gaps

- Intel `x86_64` compilation and runtime behavior require an Intel Mac or an
  explicitly supported cross-compilation environment and are not claimed by
  this run.
- The final macOS support range, Xcode support range, app bundle/signing
  configuration, and platform API availability checks remain open for the
  milestones that add those concerns.
- The M0 package markers are test scaffolding only and must be replaced by
  milestone-owned contracts; they are not protocol, capture, codec,
  transport, input, security, or clipboard implementations.
