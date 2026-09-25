# M9 Security Hardening and Release Readiness

## Status

M9 adds a repeatable release audit, hardened-runtime checks, development-command
gating, negative-test coverage, and this residual-risk record. It adds no V1
product feature. The repository also provides
`scripts/notarize-device-apps.sh` for the operator-run Developer ID and
notarization flow. The packaging flow produces signed app bundles,
role-specific DMGs, and role-specific install/uninstall command files. The
Keychain profile name is configurable through `MACREMOTEAPP_NOTARY_PROFILE`
and defaults to `notarytool-profile`; profile credentials never enter the
repository or validation logs. Deterministic CI packages are isolated under
`.build/` while the run is active and are removed after a successful CI run;
they are never treated as distributable release output. The complete local
release gate is `scripts/release-notarized.sh`: it acquires the release lock and
removes the repository `.build` cache before deterministic validation, then
writes final notarized artifacts to the repository-local
`build/release/` directory by default, then removes the recreated `.build`
cache after success. Local artifacts are organized under
`build/testing/`, `build/beta/`, `build/rc/`, and `build/release/`; the whole
`build/` tree is excluded through the checkout-local `.git/info/exclude`
(configured automatically by the packaging script) and is never a GitHub
artifact. The existing selected channel remains in place while the new release
is staged, signed, and notarized beside it. It is promoted only after final
validation; a failure before promotion leaves the old channel intact, while a
failure during promotion restores it.
When `MACREMOTEAPP_CI_NOTARIZED_RELEASE_ROOT` is supplied, CI directly
validates that existing external notarized release without rebuilding or
replacing it.

## Threat-model review

| Boundary | Required control | Evidence |
| --- | --- | --- |
| Discovery | Treat Bonjour metadata as an untrusted endpoint hint | M2 discovery tests and protocol docs |
| Transport | TLS 1.3+, presented peer identity, trust decision before protected data | M2 mutual-TLS and identity-mismatch tests |
| Pairing | Two-sided local consent, bounded/expiring challenge, explicit revoke | SecurityCore pairing tests |
| Session | Capability and selected-window generation gate every protected message | SessionCoordinator authorization tests |
| Input | Permission, foreground/focus, target identity, rate and shape validation | InputCore/M6 negative tests |
| Clipboard | Opt-in, text-only, bounded UTF-8, ACK ordering, no content in status/logs | M7 coordinator and protocol tests |
| Parser | Version, field, payload, sequence, unknown mandatory message and size checks | RemoteProtocol boundary tests |
| Resilience | Queue exhaustion and reconnect fail closed; no stale input | TransportCore fault tests |
| Release | Hardened runtime, no development commands or test trust in release app | `scripts/audit-release.sh` |

## Release controls

- Host and Viewer debug/physical smoke commands compile only in debug
  configuration. Release binaries do not contain those command markers.
- Release app bundles are signed with the hardened runtime. Developer ID
  signing is selected through `MACREMOTEAPP_SIGNING_IDENTITY`; ad-hoc signing
  is allowed only for `build/testing` and isolated validation output; the
  `build/beta`, `build/rc`, and `build/release` channels reject ad-hoc output.
  Packaging and notarization output is restricted to repository-local build
  channels or controlled staging directories, so a path such as `Downloads`,
  `Documents`, or `/` cannot be recursively replaced. The release script also
  requires `MACREMOTEAPP_RELEASE_ROOT` to match the selected channel and holds
  a kernel-backed `lockf` repository-local file lock across CI, notarization,
  `.build` cleanup, rollback, and promotion. The operating system releases the
  advisory lock when the process ends, so an interrupted run cannot leave a
  PID/reclaim race; unexpected directory or symlink lock paths fail closed.
- `scripts/create-device-dmgs.sh` creates one DMG per role, includes the
  signed app, a signed per-user `Applications` drop target, and minimal role-specific
  install/uninstall command files, and signs the DMG with the same identity. It
  also includes the User Guide, debugging guide, and debug-log collection guide,
  plus a SHA-256 payload manifest. The DMG command files are double-click-only
  user helpers; they do not expose CI, testing, ad-hoc, arbitrary-path, or
  repository-cleanup controls. The repository-only scripts retain those
  development functions. The shell scripts are not standalone code signing
  objects; their copies and guides are covered by the signed DMG and are checked
  against the embedded manifest before release.
- `scripts/install-device-apps.sh` verifies the source and final installed app
  with `codesign` and Gatekeeper before copying a notarized app atomically into
  `~/Applications` by default. It does not require Xcode or Command Line Tools
  on the target Mac; stapled-ticket validation remains in the release audit.
  It refuses to replace an existing app non-interactively unless `--replace`
  is supplied.
  Ad-hoc testing output requires the explicit `--allow-ad-hoc` opt-in and is
  never accepted by the DMG install path. The DMG helper has no equivalent
  option.
- The DMG uninstall helper uses the same per-role lifecycle lock as the
  installer, verifies the exact bundle identity, cryptographic signature,
  pinned MacRemoteApp Developer ID publisher, and Gatekeeper acceptance before
  clearing both roles' exact app data, shared MacRemoteApp trust/generated
  identity, and moving the selected per-user app to `~/.Trash`. It rejects
  symlinked Applications or Trash paths, does not touch unrelated Keychain
  records, and leaves macOS TCC grants for System Settings or the
  repository-only development cleanup script.
- `scripts/uninstall-device-apps.sh` removes only the exact selected app
  bundle paths and requires confirmation for non-interactive removal. Its
  explicit `--clean-testing --yes` mode also removes `build/testing/`, `.build`,
  the Host Screen Recording/PostEvent and Host/Viewer Local Network TCC
  grants, MacRemoteApp trust/device-identity Keychain items, and
  only the imported M2 identities whose fingerprints match generated identity
  material present in an explicitly named M2 identity directory; beta, RC, and
  release artifacts are preserved. On a device that retains only its local
  `.p12` and the opposite `.cer`, `MACREMOTEAPP_P12_PASSWORD` is required to
  fingerprint the local certificate without printing the password. If the
  check fails, the identity directory is retained for retry. Without
  `--identities`, imported M2 Keychain identities remain.
- `scripts/notarize-device-apps.sh` requires a Developer ID identity, submits
  both app archives and both DMGs with `xcrun notarytool --keychain-profile`,
  staples the tickets, validates them, and refreshes the distributable
  archives. It refuses direct writes to `build/beta`, `build/rc`, or
  `build/release`; those channels can only be promoted through the
  lock-protected `scripts/release-notarized.sh` flow. It does not create,
  print, or store Keychain credentials.
- `scripts/check-notary-profile.sh` is an optional history-based Keychain
  diagnostic. It is not a release gate: the actual `notarytool submit`
  operation used by the release flow is the authoritative profile check, and
  a Codex runner may reject the separate `history` operation even when the
  submit path can read the profile. A profile that works in a normal Terminal
  session may still have different visibility for other Keychain operations;
  that is an execution-context limitation, not evidence that an already
  accepted DMG is invalid.
- `scripts/validate-notarized-release.sh` validates an existing release's
  Developer ID signatures, stapled tickets, and Gatekeeper assessment without
  submitting, signing, or replacing any artifact. It also extracts and
  compares each `.app.zip` with its validated app bundle, rejects extra archive
  payloads, then validates the extracted stapled app. DMG payload checks use the
  manifest embedded in each DMG rather than mutable checkout files. The release
  audit also asserts a universal `arm64+x86_64` Host and an `arm64` Viewer. Set
  `MACREMOTEAPP_CI_NOTARIZED_RELEASE_ROOT` to use this direct validation path
  from `.codex/ci.sh`.
- `get-task-allow` and dynamic-loader development entitlements are rejected by
  the release audit.
- Private identity files are generated outside the repository and are rejected
  if found inside a release artifact. The audit covers `.p12`, `.p8`, `.key`,
  and `.pem` files plus PEM/credential markers in tracked and untracked release
  inputs.
- App installation stages and verifies the replacement before moving it into
  place, retaining a same-directory backup until the new app is installed
  successfully and restoring it if the final move fails. A per-destination
  kernel-backed `lockf` installer lock prevents concurrent recovery/cleanup; an
  interrupted process releases the advisory lock automatically, and a later
  installer run deterministically recovers an exact interrupted-install backup
  before accepting another replacement. Unexpected directory or symlink lock
  paths fail closed.
- Clipboard text, raw input values, private keys, pairing secrets, pixels, and
  arbitrary underlying error strings are not release diagnostics.
- Trust records and locally generated TLS identity material remain in
  Keychain-backed `SecurityCore`; no file-based secret store is added. The
  repository cleanup path removes the default generated local identity along
  with testing trust records. In-app pairing reset preserves the local
  identity; the DMG uninstall is the explicit full MacRemoteApp data reset.

## Residual risks and owners

| Risk | Severity | Owner / mitigation | State |
| --- | --- | --- | --- |
| Physical Intel-to-Apple-Silicon acceptance not run in this workspace | P1 release gate | Operator; run `docs/M10_ACCEPTANCE.md` on both Macs | Open |
| Developer ID notarization profile is host-specific | P2 release process | Release operator; run `scripts/notarize-device-apps.sh` and inspect logs | Open |
| Real macOS PostEvent injection needs a disposable foreground app | P1 acceptance gate | Operator; run M6 safe-app test with permission evidence | Open |
| Interactive pairing UI and Keychain trust reuse are newly composed in M10 but still need physical Intel/Apple-Silicon evidence | P1 product acceptance | Run the first-pairing, repeat-connection, revoke, and identity-mismatch checks in `docs/M10_ACCEPTANCE.md` | Open — physical validation |
| V1 does not defend a compromised local administrator or approved rogue peer | Known non-goal | Documented in `docs/SECURITY.md` | Accepted non-goal |

M9 is not considered a license to weaken any permission, trust, or focus gate
to make a physical test pass.
