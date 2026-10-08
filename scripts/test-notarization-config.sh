#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
source "${script_dir}/notarization-config.sh"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/macremoteapp-notary-config.XXXXXX")"
trap 'rm -rf -- "${fixture_root}"' EXIT
chmod 700 "${fixture_root}"
fixture_repo="${fixture_root}/project"
fixture_external="${fixture_root}/external keys"
fixture_bin="${fixture_root}/bin"
mkdir -p "${fixture_repo}" "${fixture_external}" "${fixture_bin}"
chmod 700 "${fixture_repo}" "${fixture_external}" "${fixture_bin}"
fixture_key="${fixture_external}/AuthKey_fixture.p8"
printf 'synthetic fixture only\n' >"${fixture_key}"
chmod 600 "${fixture_key}"

write_config() {
    local path="$1"
    shift
    printf '%s\n' "$@" >"${path}"
    chmod 600 "${path}"
}

expect_resolve_failure() {
    local root="$1"
    local config="$2"
    local label="$3"
    local stdout_path="${fixture_root}/stdout"
    local stderr_path="${fixture_root}/stderr"

    if macremoteapp_notary_resolve "$root" "$config" >"${stdout_path}" 2>"${stderr_path}"; then
        echo "Notarization fixture unexpectedly accepted ${label}" >&2
        exit 1
    fi
    if grep -Eq 'SYNTHETIC_PRIVATE_SENTINEL|synthetic fixture only|AuthKey_fixture|fixture-key-id|fixture-issuer|touch ' \
        "${stdout_path}" "${stderr_path}"; then
        echo "Notarization fixture leaked a value while rejecting ${label}" >&2
        exit 1
    fi
}

unset MACREMOTEAPP_NOTARY_PROFILE
macremoteapp_notary_resolve "${fixture_repo}" "${fixture_root}/missing.env"
[[ "${MACREMOTEAPP_RESOLVED_NOTARY_MODE}" == profile &&
   "${MACREMOTEAPP_RESOLVED_NOTARY_PROFILE}" == notarytool-profile ]]

default_home="${fixture_root}/default-home"
mkdir -p "${default_home}/.config/codex"
chmod 700 "${default_home}" "${default_home}/.config" "${default_home}/.config/codex"
write_config "${default_home}/.config/codex/notarization.env" \
    "MACOS_NOTARY_KEY_PATH=\"${fixture_key}\"" \
    'MACOS_NOTARY_KEY_ID="fixture-key-id"' \
    'MACOS_NOTARY_ISSUER="fixture-issuer"'
(
    unset MACREMOTEAPP_NOTARY_PROFILE
    HOME="${default_home}"
    export HOME
    macremoteapp_notary_resolve "${fixture_repo}"
    [[ "${MACREMOTEAPP_RESOLVED_NOTARY_MODE}" == api-key &&
       "${MACREMOTEAPP_RESOLVED_NOTARY_KEY_PATH}" == "${fixture_key}" ]]
)

write_config "${fixture_root}/profile.env" 'MACOS_NOTARY_PROFILE="shared-profile-fixture"'
macremoteapp_notary_resolve "${fixture_repo}" "${fixture_root}/profile.env"
[[ "${MACREMOTEAPP_RESOLVED_NOTARY_MODE}" == profile &&
   "${MACREMOTEAPP_RESOLVED_NOTARY_PROFILE}" == shared-profile-fixture ]]

# The explicit project Keychain profile wins without opening an unsafe shared
# file, matching the existing MACREMOTEAPP_NOTARY_PROFILE contract.
ln -s "${fixture_root}/missing.env" "${fixture_root}/unsafe-link.env"
(
    export MACREMOTEAPP_NOTARY_PROFILE=project-profile-fixture
    macremoteapp_notary_resolve "${fixture_repo}" "${fixture_root}/unsafe-link.env"
    [[ "${MACREMOTEAPP_RESOLVED_NOTARY_MODE}" == profile &&
       "${MACREMOTEAPP_RESOLVED_NOTARY_PROFILE}" == project-profile-fixture &&
       "${MACREMOTEAPP_NOTARY_PROFILE}" == project-profile-fixture ]]
)

write_config "${fixture_root}/api.env" \
    "MACOS_NOTARY_KEY_PATH=\"${fixture_key}\"" \
    'MACOS_NOTARY_KEY_ID="fixture-key-id"' \
    'MACOS_NOTARY_ISSUER="fixture-issuer"'
macremoteapp_notary_resolve "${fixture_repo}" "${fixture_root}/api.env"
[[ "${MACREMOTEAPP_RESOLVED_NOTARY_MODE}" == api-key &&
   "${MACREMOTEAPP_RESOLVED_NOTARY_KEY_PATH}" == "${fixture_key}" &&
   "${MACREMOTEAPP_RESOLVED_NOTARY_KEY_ID}" == fixture-key-id &&
   "${MACREMOTEAPP_RESOLVED_NOTARY_ISSUER}" == fixture-issuer ]]

(
    unset MACREMOTEAPP_NOTARY_PROFILE
    set -a
    macremoteapp_notary_resolve "${fixture_repo}" "${fixture_root}/api.env"
    case "$-" in
        *a*) echo "Notarization resolver left allexport enabled" >&2; exit 1 ;;
    esac
    [[ "${MACREMOTEAPP_RESOLVED_NOTARY_MODE}" == api-key ]]
)

cat >"${fixture_bin}/xcrun" <<'FAKE_XCRUN'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${MACREMOTEAPP_TEST_NOTARY_ARGUMENT_LOG}"
if [[ "${MACOS_NOTARY_KEY_PATH+x}" == x ||
      "${MACOS_NOTARY_KEY_ID+x}" == x ||
      "${MACOS_NOTARY_ISSUER+x}" == x ||
      "${MACREMOTEAPP_RESOLVED_NOTARY_KEY_ID+x}" == x ]]; then
    echo "notary credential environment leaked to xcrun" >&2
    exit 1
fi
FAKE_XCRUN
chmod 700 "${fixture_bin}/xcrun"
arguments_log="${fixture_root}/xcrun-arguments"
PATH="${fixture_bin}:${PATH}" MACREMOTEAPP_TEST_NOTARY_ARGUMENT_LOG="${arguments_log}" \
    macremoteapp_notary_submit "${fixture_root}/Host app.zip" --wait
grep -Fqx -- "${fixture_key}" "${arguments_log}"
grep -Fqx -- fixture-key-id "${arguments_log}"
grep -Fqx -- fixture-issuer "${arguments_log}"
grep -Fqx -- --wait "${arguments_log}"
grep -Fqx -- submit "${arguments_log}"
if grep -Fq -- --keychain-profile "${arguments_log}"; then
    echo "API-key notarization fixture used the Keychain-profile option" >&2
    exit 1
fi

MACREMOTEAPP_NOTARY_PROFILE=explicit-profile-fixture \
    macremoteapp_notary_resolve "${fixture_repo}" "${fixture_root}/api.env"
[[ "${MACREMOTEAPP_RESOLVED_NOTARY_MODE}" == profile &&
   "${MACREMOTEAPP_RESOLVED_NOTARY_PROFILE}" == explicit-profile-fixture ]]
PATH="${fixture_bin}:${PATH}" MACREMOTEAPP_TEST_NOTARY_ARGUMENT_LOG="${arguments_log}" \
    macremoteapp_notary_submit "${fixture_root}/Viewer.dmg" --wait
grep -Fqx -- --keychain-profile "${arguments_log}"
grep -Fqx -- explicit-profile-fixture "${arguments_log}"
if grep -Fqx -- --key "${arguments_log}"; then
    echo "Explicit Keychain profile fixture also selected API-key authentication" >&2
    exit 1
fi
unset MACREMOTEAPP_NOTARY_PROFILE

write_config "${fixture_root}/partial.env" \
    'MACOS_NOTARY_KEY_ID="fixture-key-id"' \
    'MACOS_NOTARY_ISSUER="fixture-issuer"'
expect_resolve_failure "${fixture_repo}" "${fixture_root}/partial.env" "partial API-key configuration"

cp "${fixture_root}/api.env" "${fixture_root}/insecure.env"
chmod 644 "${fixture_root}/insecure.env"
expect_resolve_failure "${fixture_repo}" "${fixture_root}/insecure.env" "insecure shared-file permissions"

ln -s "${fixture_root}/api.env" "${fixture_root}/config-link.env"
expect_resolve_failure "${fixture_repo}" "${fixture_root}/config-link.env" "symlinked shared configuration"

inside_key="${fixture_repo}/AuthKey_fixture.p8"
cp "${fixture_key}" "${inside_key}"
chmod 600 "${inside_key}"
write_config "${fixture_root}/inside-key.env" \
    "MACOS_NOTARY_KEY_PATH=\"${inside_key}\"" \
    'MACOS_NOTARY_KEY_ID="fixture-key-id"' \
    'MACOS_NOTARY_ISSUER="fixture-issuer"'
expect_resolve_failure "${fixture_repo}" "${fixture_root}/inside-key.env" "a private key inside the repository"

chmod 644 "${fixture_key}"
expect_resolve_failure "${fixture_repo}" "${fixture_root}/api.env" "non-private API key permissions"
chmod 600 "${fixture_key}"

key_link="${fixture_external}/AuthKey_fixture-link.p8"
ln -s "${fixture_key}" "${key_link}"
write_config "${fixture_root}/key-link.env" \
    "MACOS_NOTARY_KEY_PATH=\"${key_link}\"" \
    'MACOS_NOTARY_KEY_ID="fixture-key-id"' \
    'MACOS_NOTARY_ISSUER="fixture-issuer"'
expect_resolve_failure "${fixture_repo}" "${fixture_root}/key-link.env" "a symlinked API key"

write_config "${fixture_root}/unsupported.env" \
    "MACOS_NOTARY_KEY_PATH=\"${fixture_key}\"" \
    'MACOS_NOTARY_KEY_ID="fixture-key-id"' \
    'MACOS_NOTARY_ISSUER="fixture-issuer"' \
    'UNKNOWN_FIXTURE="SYNTHETIC_PRIVATE_SENTINEL"'
expect_resolve_failure "${fixture_repo}" "${fixture_root}/unsupported.env" "an unknown active variable"

marker_path="${fixture_root}/must-not-exist"
write_config "${fixture_root}/shell-code.env" \
    "MACOS_NOTARY_KEY_PATH=\"${fixture_key}\"" \
    'MACOS_NOTARY_KEY_ID="fixture-key-id"' \
    'MACOS_NOTARY_ISSUER="fixture-issuer"' \
    "\$(touch '${marker_path}')"
expect_resolve_failure "${fixture_repo}" "${fixture_root}/shell-code.env" "active shell syntax"
test ! -e "${marker_path}"

# Both release entry points resolve auth before they run CI/build work; only
# the lower-level notarizer invokes the shared submit adapter.
grep -Fq 'macremoteapp_notary_resolve' "${script_dir}/notarize-device-apps.sh"
grep -Fq 'macremoteapp_notary_resolve' "${script_dir}/release-notarized.sh"
grep -Fq 'macremoteapp_notary_submit' "${script_dir}/notarize-device-apps.sh"
grep -Fq 'scripts/notarization-config.sh' "${script_dir}/validate.sh"
if grep -Eq '^[[:space:]]*MACREMOTEAPP_NOTARY_PROFILE=' "${script_dir}/release-notarized.sh"; then
    echo "Release wrapper overwrites an inherited project Keychain profile" >&2
    exit 1
fi
release_preflight_line="$(grep -n 'macremoteapp_notary_resolve' "${script_dir}/release-notarized.sh" | head -1 | cut -d: -f1)"
release_artifact_line="$(grep -n 'mkdir -p -- "${artifact_root}"' "${script_dir}/release-notarized.sh" | head -1 | cut -d: -f1)"
if [[ -z "${release_preflight_line}" || -z "${release_artifact_line}" ||
      "${release_preflight_line}" -ge "${release_artifact_line}" ]]; then
    echo "Release wrapper must resolve notarization configuration before creating release output" >&2
    exit 1
fi

# Exercise the real release wrapper's preflight with a fixture HOME. It must
# reject an insecure config before entering CI or touching release channels.
release_home="${fixture_root}/release-home"
mkdir -p "${release_home}/.config/codex"
chmod 700 "${release_home}" "${release_home}/.config" "${release_home}/.config/codex"
cp "${fixture_root}/api.env" "${release_home}/.config/codex/notarization.env"
chmod 644 "${release_home}/.config/codex/notarization.env"
release_output="${fixture_root}/release-preflight-output"
if (
    unset MACREMOTEAPP_NOTARY_PROFILE
    HOME="${release_home}"
    export HOME
    bash "${script_dir}/release-notarized.sh" rc
) >"${release_output}" 2>&1; then
    echo "Release wrapper accepted an insecure shared config" >&2
    exit 1
fi
grep -Fq 'owner-only mode 600' "${release_output}"
if grep -Fq 'Running deterministic CI before notarization' "${release_output}"; then
    echo "Release wrapper entered CI before rejecting the shared config" >&2
    exit 1
fi

# Exercise the owner gate when the test process can create a file belonging to
# another uid. This is skipped on ordinary unprivileged developer accounts.
wrong_owner_config="${fixture_root}/wrong-owner.env"
cp "${fixture_root}/profile.env" "${wrong_owner_config}"
chmod 600 "${wrong_owner_config}"
current_uid="$(id -u)"
other_uid=0
if [[ "${current_uid}" == 0 ]]; then
    other_uid=501
fi
if chown "${other_uid}" "${wrong_owner_config}" 2>/dev/null && [[ ! -O "${wrong_owner_config}" ]]; then
    expect_resolve_failure "${fixture_repo}" "${wrong_owner_config}" "a config owned by another user"
fi

echo "Notarization configuration fixtures passed"
