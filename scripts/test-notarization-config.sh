#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
source "${script_dir}/notarization-config.sh"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/macremoteapp-notary-adapter.XXXXXX")"
trap 'rm -rf -- "${fixture_root}"' EXIT
fixture_repo="${fixture_root}/project"
fixture_bin="${fixture_root}/bin"
fixture_helper="${fixture_root}/macos_notarization.py"
arguments_log="${fixture_root}/helper-arguments.log"
mkdir -p "${fixture_repo}" "${fixture_bin}"

cat >"${fixture_helper}" <<'MOCK_HELPER'
import os
import sys

args = sys.argv[1:]
command = args[0] if args else ""
with open(os.environ["MACREMOTEAPP_TEST_HELPER_LOG"], "a", encoding="utf-8") as log:
    log.write(command + "\n")
    log.write("\n".join(args) + "\n")
    log.write("--end-call--\n")

def option(name):
    try:
        return args[args.index(name) + 1]
    except (ValueError, IndexError):
        return None

if command == "resolve-auth":
    if os.environ.get("MACREMOTEAPP_TEST_AUTH_KIND") == "error":
        print("synthetic configuration failure", file=sys.stderr)
        raise SystemExit(1)
    requested = option("--auth") or "auto"
    if requested == "keychain-profile":
        selected = "keychain-profile"
    elif requested == "api-key":
        selected = "api-key"
    elif os.environ.get("MACOS_NOTARY_PROFILE") or all(
        os.environ.get(name)
        for name in ("MACOS_NOTARY_KEY_PATH", "MACOS_NOTARY_KEY_ID", "MACOS_NOTARY_ISSUER")
    ):
        selected = "api-key" if os.environ.get("MACOS_NOTARY_KEY_PATH") else "keychain-profile"
    else:
        selected = os.environ.get("MACREMOTEAPP_TEST_AUTH_KIND", "keychain-profile")
    capture = os.environ.get("MACREMOTEAPP_TEST_AUTH_CAPTURE")
    if capture:
        with open(capture, "a", encoding="utf-8") as log:
            log.write(selected + "\n")
    print(selected)
elif command == "resolve-signing-identity":
    print(option("--identity") or os.environ.get("MACREMOTEAPP_TEST_GLOBAL_IDENTITY", "-"))
elif command == "submit":
    print("Apple submission status: Accepted")
    print("Apple submission ID: 12345678-1234-1234-1234-123456789abc")
    if os.environ.get("MACREMOTEAPP_TEST_SUBMIT_FAIL") == "1":
        raise SystemExit(1)
elif command in ("sign", "staple", "verify"):
    pass
else:
    print("unexpected mock command", file=sys.stderr)
    raise SystemExit(2)
MOCK_HELPER

cat >"${fixture_bin}/codesign" <<'MOCK_CODESIGN'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${MACREMOTEAPP_TEST_CODESIGN_LOG}"
MOCK_CODESIGN
chmod 700 "${fixture_bin}/codesign"
cat >"${fixture_bin}/lockf" <<'MOCK_LOCKF'
#!/bin/sh
if [ "$1" != "-t" ]; then
    exit 2
fi
shift 3
exec "$@"
MOCK_LOCKF
cat >"${fixture_bin}/bash" <<'MOCK_BASH'
#!/bin/sh
case "${1:-}" in
    */scripts/validate.sh)
        exit 0
        ;;
    */scripts/notarize-device-apps.sh)
        scripts_dir=$(dirname -- "$1")
        project_root=$(cd -- "${scripts_dir}/.." && pwd -P)
        exec /bin/bash -c \
            'source "$1/notarization-config.sh"; macremoteapp_notary_resolve "$2"' \
            _ "${scripts_dir}" "${project_root}"
        ;;
    *)
        exec /bin/bash "$@"
        ;;
esac
MOCK_BASH
chmod 700 "${fixture_bin}/codesign" "${fixture_bin}/lockf" "${fixture_bin}/bash"
export MACREMOTEAPP_NOTARIZATION_HELPER="${fixture_helper}"
export MACREMOTEAPP_TEST_HELPER_LOG="${arguments_log}"
export MACREMOTEAPP_TEST_CODESIGN_LOG="${fixture_root}/codesign-arguments.log"
export PATH="${fixture_bin}:${PATH}"
: >"${arguments_log}"

fail() {
    echo "Notarization adapter fixture failed: $*" >&2
    exit 1
}

contains() {
    local needle="$1"
    local file="$2"
    grep -Fq -- "$needle" "$file" || fail "expected to find $needle"
}

unset MACREMOTEAPP_NOTARY_PROFILE
export MACREMOTEAPP_TEST_AUTH_KIND=api-key
macremoteapp_notary_resolve "${fixture_repo}"
[[ "${MACREMOTEAPP_RESOLVED_NOTARY_MODE}" == "api-key" ]] ||
    fail "legacy API-key auth mode was not selected from helper metadata"
contains "resolve-auth" "${arguments_log}"
contains "auto" "${arguments_log}"
contains "notarytool-profile" "${arguments_log}"
contains "--project-root" "${arguments_log}"
contains "${fixture_repo}" "${arguments_log}"

submit_output="${fixture_root}/submit-output.txt"
macremoteapp_notary_submit "${fixture_root}/Host app.zip" >"${submit_output}"
contains "Apple submission status: Accepted" "${submit_output}"
contains "Apple submission ID: 12345678-1234-1234-1234-123456789abc" "${submit_output}"
contains "api-key" "${arguments_log}"
contains "--authorized" "${arguments_log}"
contains "--wait" "${arguments_log}"
contains "--project-root" "${arguments_log}"
contains "${fixture_repo}" "${arguments_log}"
if grep -Eq 'SYNTHETIC_PRIVATE_SENTINEL|fixture-key-id|fixture-issuer|AuthKey_fixture' \
    "${arguments_log}" "${submit_output}"; then
    fail "notarization credential data appeared in helper arguments or output"
fi

before_submit_count="$(grep -xc 'submit' "${arguments_log}" || true)"
if MACREMOTEAPP_TEST_SUBMIT_FAIL=1 \
    macremoteapp_notary_submit "${fixture_root}/Host app.zip" >/dev/null 2>&1; then
    fail "mock submission failure was accepted"
fi
after_submit_count="$(grep -xc 'submit' "${arguments_log}" || true)"
[[ "$after_submit_count" -eq $((before_submit_count + 2)) ]] ||
    fail "submission failure triggered a retry"

export MACREMOTEAPP_NOTARY_PROFILE=project-profile-fixture
export MACREMOTEAPP_TEST_AUTH_KIND=keychain-profile
macremoteapp_notary_resolve "${fixture_repo}"
[[ "${MACREMOTEAPP_RESOLVED_NOTARY_MODE}" == "profile" &&
   "${MACREMOTEAPP_RESOLVED_NOTARY_PROFILE}" == "project-profile-fixture" ]] ||
    fail "project Keychain-profile override was not preserved"
macremoteapp_notary_submit "${fixture_root}/Viewer.dmg" >/dev/null
contains "project-profile-fixture" "${arguments_log}"
contains "keychain-profile" "${arguments_log}"

MACREMOTEAPP_NOTARY_PROFILE="" macremoteapp_notary_resolve "${fixture_repo}"
[[ "${MACREMOTEAPP_RESOLVED_NOTARY_PROFILE}" == "notarytool-profile" ]] ||
    fail "empty project profile did not preserve the notarytool-profile fallback"
unset MACREMOTEAPP_NOTARY_PROFILE

export MACREMOTEAPP_TEST_GLOBAL_IDENTITY='Developer ID Application: Fixture (TEAMID)'
signing_identity="$(macremoteapp_resolve_signing_identity -)"
[[ "$signing_identity" == 'Developer ID Application: Fixture (TEAMID)' ]] ||
    fail "shared signing identity was not resolved"
contains "resolve-signing-identity" "${arguments_log}"
contains "--default-identity" "${arguments_log}"
contains "-" "${arguments_log}"

export MACREMOTEAPP_SIGNING_IDENTITY='Developer ID Application: Project (TEAMID)'
signing_identity="$(macremoteapp_resolve_signing_identity -)"
[[ "$signing_identity" == 'Developer ID Application: Project (TEAMID)' ]] ||
    fail "project signing identity override was not preserved"
contains 'Developer ID Application: Project (TEAMID)' "${arguments_log}"

fixture_app="${fixture_root}/MacRemoteApp-Host.app"
fixture_dmg="${fixture_root}/MacRemoteApp-Host.dmg"
mkdir -p "${fixture_app}"
: >"${fixture_dmg}"
macremoteapp_sign_app "${fixture_app}" "$signing_identity"
contains "sign" "${arguments_log}"
contains "--authorized" "${arguments_log}"
macremoteapp_notary_staple "${fixture_app}"
macremoteapp_notary_verify "${fixture_app}"
macremoteapp_notary_verify "${fixture_dmg}"
contains "staple" "${arguments_log}"
contains "verify" "${arguments_log}"

before_sign_count="$(grep -xc 'resolve-signing-identity' "${arguments_log}" || true)"
MACREMOTEAPP_SIGNING_IDENTITY=- macremoteapp_resolve_signing_identity - >/dev/null
after_sign_count="$(grep -xc 'resolve-signing-identity' "${arguments_log}" || true)"
[[ "$after_sign_count" == "$before_sign_count" ]] ||
    fail "explicit ad-hoc identity unexpectedly read shared signing configuration"
MACREMOTEAPP_SIGNING_IDENTITY=- macremoteapp_sign_app "${fixture_app}" -
contains "--timestamp=none" "${MACREMOTEAPP_TEST_CODESIGN_LOG}"

for release_script in notarize-device-apps.sh validate-notarized-release.sh; do
    script_path="${script_dir}/${release_script}"
    grep -Fq 'macremoteapp_notary_verify "${dmg_path}"' "$script_path" ||
        fail "${release_script} does not verify DMGs through the shared helper"
    if grep -Fq -- '--type install' "$script_path"; then
        fail "${release_script} still uses the incorrect DMG Gatekeeper assessment type"
    fi
done

for local_packaging_script in package-device-apps.sh create-device-dmgs.sh; do
    script_path="${script_dir}/${local_packaging_script}"
    if grep -Fq 'macremoteapp_resolve_signing_identity' "$script_path"; then
        fail "${local_packaging_script} unexpectedly resolves a global signing identity for local packaging"
    fi
    grep -Fq 'signing_identity="${MACREMOTEAPP_SIGNING_IDENTITY:-}"' "$script_path" ||
        fail "${local_packaging_script} does not preserve project-only local signing selection"
done

export MACREMOTEAPP_TEST_AUTH_KIND=error
release_output="${fixture_root}/release-preflight.txt"
if bash "${script_dir}/release-notarized.sh" rc >"${release_output}" 2>&1; then
    fail "release wrapper accepted helper configuration failure"
fi
if grep -Fq 'Running deterministic CI before notarization' "${release_output}"; then
    fail "release wrapper entered CI before resolving helper authentication"
fi

# Run the release wrapper in an isolated Git fixture. The mock low-level
# notarizer sources the same adapter and resolves auth in its child process;
# generic shared API settings must survive that delegation unchanged.
wrapper_root="${fixture_root}/release-wrapper-project"
wrapper_scripts="${wrapper_root}/scripts"
mkdir -p "${wrapper_scripts}"
git -C "${wrapper_root}" init -q
cp "${script_dir}/release-notarized.sh" \
   "${script_dir}/notarize-device-apps.sh" \
   "${script_dir}/notarization-config.sh" \
   "${script_dir}/artifact-naming.sh" \
   "${script_dir}/ensure-local-build-exclude.sh" \
   "${wrapper_scripts}/"
auth_capture="${fixture_root}/delegated-auth-modes.txt"
: >"${auth_capture}"
unset MACREMOTEAPP_TEST_AUTH_KIND MACREMOTEAPP_NOTARY_PROFILE
export MACREMOTEAPP_TEST_AUTH_CAPTURE="${auth_capture}"
export MACOS_NOTARY_KEY_PATH="${fixture_root}/synthetic-key.p8"
export MACOS_NOTARY_KEY_ID="fixture-key-id"
export MACOS_NOTARY_ISSUER="fixture-issuer"
MACREMOTEAPP_NOTARIZATION_HELPER="${fixture_helper}" \
    bash "${wrapper_scripts}/release-notarized.sh" rc \
    >"${fixture_root}/release-wrapper-output.txt" 2>&1 ||
    fail "mock release wrapper did not complete its isolated delegation"
if [[ ! -s "${auth_capture}" ]] || grep -Evx 'api-key' "${auth_capture}" >/dev/null; then
    fail "release wrapper and low-level notarizer did not resolve the same API-key mode"
fi

echo "Shared notarization helper adapter fixtures passed"
