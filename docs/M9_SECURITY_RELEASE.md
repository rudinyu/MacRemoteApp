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
release gate is `scripts/release-notarized.sh`: it runs the repository
validation first, writes final notarized artifacts to the repository-adjacent
`../MacRemoteApp-Release/`
directory by default, then removes the recreated `.build` cache after success.
It stages and validates the new release before replacing an existing release
directory.
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
  is allowed only for local validation and is not a distribution claim.
- `scripts/create-device-dmgs.sh` creates one DMG per role, includes the
  signed app and role-specific install/uninstall command files, and signs the
  DMG with the same identity. The shell scripts are not standalone code
  signing objects; their copies are covered by the signed DMG and are
  syntax-checked before release.
- `scripts/install-device-apps.sh` verifies the app signature before copying
  an app atomically into `~/Applications` by default. It refuses to replace
  an existing app non-interactively unless `--replace` is supplied.
- `scripts/uninstall-device-apps.sh` removes only the exact selected app
  bundle paths and requires confirmation for non-interactive removal; it does
  not delete Keychain trust records or macOS permissions.
- `scripts/notarize-device-apps.sh` requires a Developer ID identity, submits
  both app archives and both DMGs with `xcrun notarytool --keychain-profile`,
  staples the tickets, validates them, and refreshes the distributable
  archives. It does not create, print, or store Keychain credentials.
- `scripts/validate-notarized-release.sh` validates an existing release's
  Developer ID signatures, stapled tickets, and Gatekeeper assessment without
  submitting, signing, or replacing any artifact. Set
  `MACREMOTEAPP_CI_NOTARIZED_RELEASE_ROOT` to use this direct validation path
  from `.codex/ci.sh`.
- `get-task-allow` and dynamic-loader development entitlements are rejected by
  the release audit.
- Private identity files are generated outside the repository and are rejected
  if found inside a release artifact.
- Clipboard text, raw input values, private keys, pairing secrets, pixels, and
  arbitrary underlying error strings are not release diagnostics.
- Trust records remain in Keychain-backed `SecurityCore`; no file-based secret
  store is added.

## Residual risks and owners

| Risk | Severity | Owner / mitigation | State |
| --- | --- | --- | --- |
| Physical Intel-to-Apple-Silicon acceptance not run in this workspace | P1 release gate | Operator; run `docs/M10_ACCEPTANCE.md` on both Macs | Open |
| Developer ID notarization profile is host-specific | P2 release process | Release operator; run `scripts/notarize-device-apps.sh` and inspect logs | Open |
| Real macOS Accessibility event posting needs a disposable foreground app | P1 acceptance gate | Operator; run M6 safe-app test with permission evidence | Open |
| Interactive pairing UI and Keychain trust reuse are newly composed in M10 but still need physical Intel/Apple-Silicon evidence | P1 product acceptance | Run the first-pairing, repeat-connection, revoke, and identity-mismatch checks in `docs/M10_ACCEPTANCE.md` | Open — physical validation |
| V1 does not defend a compromised local administrator or approved rogue peer | Known non-goal | Documented in `docs/SECURITY.md` | Accepted non-goal |

M9 is not considered a license to weaken any permission, trust, or focus gate
to make a physical test pass.
