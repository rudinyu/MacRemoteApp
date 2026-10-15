#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
source "${script_dir}/artifact-naming.sh"

test_root="$(mktemp -d "${TMPDIR:-/private/tmp}/macremoteapp-artifact-naming.XXXXXX")"
repo_build_root="${repo_root}/build"
created_repo_build_root=0
cleanup_fixture() {
    rm -rf -- "${test_root}"
    if (( created_repo_build_root )) && [[ -d "${repo_build_root}" && ! -L "${repo_build_root}" ]]; then
        rmdir -- "${repo_build_root}" 2>/dev/null || true
    fi
}
trap cleanup_fixture EXIT

fail() {
    echo "Artifact naming test failed: $*" >&2
    exit 1
}

make_plist() {
    local path="$1"
    local short_version="$2"
    local build_version="$3"
    /usr/bin/plutil -create xml1 "${path}"
    /usr/bin/plutil -insert CFBundleShortVersionString -string "${short_version}" "${path}"
    /usr/bin/plutil -insert CFBundleVersion -string "${build_version}" "${path}"
}

assert_identity() {
    local expected="$1"
    local actual
    actual="$(macremoteapp_release_identity "$2" "$3")" || fail "valid matching metadata was rejected"
    [[ "${actual}" == "${expected}" ]] || fail "expected identity ${expected}, got ${actual}"
}

assert_invalid_identity() {
    if macremoteapp_release_identity "$1" "$2" >/dev/null 2>&1; then
        fail "invalid or mismatched bundle metadata was accepted"
    fi
}

assert_script_contains() {
    local script_path="$1"
    local expected_text="$2"
    if ! grep -Fq -- "${expected_text}" "${script_path}"; then
        fail "artifact channel forwarding is missing from $(basename -- "${script_path}")"
    fi
}

host_plist="${test_root}/Host-Info.plist"
viewer_plist="${test_root}/Viewer-Info.plist"
make_plist "${host_plist}" 0.2 1009
make_plist "${viewer_plist}" 0.2 1009
assert_identity 0.2.1009 "${host_plist}" "${viewer_plist}"
fallback_identity="$(TMPDIR="${test_root}/missing-tmp" macremoteapp_release_identity "${host_plist}" "${viewer_plist}")" || fail "release metadata could not be read with an unusable TMPDIR"
[[ "${fallback_identity}" == "0.2.1009" ]] || fail "unusable TMPDIR changed the release identity"

unset MACREMOTEAPP_ARTIFACT_CHANNEL
test_repo="${test_root}/repo"
staging_root="${test_repo}/build/MacRemoteApp-release.staging.test"
if macremoteapp_resolve_artifact_channel "${test_repo}" "${staging_root}" >/dev/null 2>&1; then
    fail "staging without an explicit channel was accepted"
fi
resolved_channel="$(macremoteapp_resolve_artifact_channel "${test_repo}" "${test_repo}/.build/public-validation/release")"
[[ "${resolved_channel}" == testing ]] || fail ".build/release incorrectly implied the formal release channel"

for channel in testing debug-diagnostic beta rc release; do
    unset MACREMOTEAPP_ARTIFACT_CHANNEL
    resolved_channel="$(macremoteapp_resolve_artifact_channel "${test_repo}" "${test_repo}/build/${channel}")"
    [[ "${resolved_channel}" == "${channel}" ]] || fail "canonical build/${channel} root did not resolve to its channel"
done

MACREMOTEAPP_ARTIFACT_CHANNEL=release
if macremoteapp_resolve_artifact_channel "${test_repo}" "${test_repo}/build/rc" >/dev/null 2>&1; then
    fail "explicit release channel bypassed the canonical build/rc root policy"
fi
if macremoteapp_resolve_artifact_channel "${test_repo}" "${test_repo}/.build/public-validation/release" >/dev/null 2>&1; then
    fail "inherited release channel changed a public .build output"
fi
MACREMOTEAPP_ARTIFACT_CHANNEL=testing
if macremoteapp_resolve_artifact_channel "${test_repo}" "${test_repo}/build/rc" >/dev/null 2>&1; then
    fail "explicit testing channel conflicted with canonical build/rc without rejection"
fi

for channel in testing debug-diagnostic beta rc; do
    MACREMOTEAPP_ARTIFACT_CHANNEL="${channel}"
    resolved_channel="$(macremoteapp_resolve_artifact_channel "${test_repo}" "${staging_root}")"
    [[ "${resolved_channel}" == "${channel}" ]] || fail "explicit ${channel} staging channel was not retained"
    expected_dmg="$(macremoteapp_expected_distribution_name "${channel}" 0.2.1009 MacRemoteApp-Host dmg)"
    expected_zip="$(macremoteapp_expected_distribution_name "${channel}" 0.2.1009 MacRemoteApp-Viewer app-zip)"
    if [[ "${channel}" == "debug-diagnostic" ]]; then
        [[ "${expected_dmg}" == "MacRemoteApp-Host-debug-diagnostic-0.2.1009.dmg" ]] ||
            fail "Debug diagnostic DMG name did not retain its channel and version"
        [[ "${expected_zip}" == "MacRemoteApp-Viewer-debug-diagnostic-0.2.1009.app.zip" ]] ||
            fail "Debug diagnostic app ZIP name did not retain its channel and version"
    else
        [[ "${expected_dmg}" == "MacRemoteApp-Host-0.2.1009.dmg" ]] || fail "${channel} DMG name was not versioned"
        [[ "${expected_zip}" == "MacRemoteApp-Viewer-0.2.1009.app.zip" ]] || fail "${channel} app ZIP name was not versioned"
    fi
done

for channel in testing beta rc release; do
    macremoteapp_require_release_channel "${channel}" ||
        fail "formal M9 channel ${channel} was rejected"
done
if macremoteapp_require_release_channel debug-diagnostic >/dev/null 2>&1; then
    fail "M10 Debug diagnostic channel was accepted by M9 release validation"
fi

MACREMOTEAPP_ARTIFACT_CHANNEL=release
resolved_channel="$(macremoteapp_resolve_artifact_channel "${test_repo}" "${staging_root}")"
[[ "${resolved_channel}" == release ]] || fail "explicit release channel was not retained through staging"
[[ "$(macremoteapp_expected_distribution_name release 0.2.1009 MacRemoteApp-Host dmg)" == "MacRemoteApp-Host.dmg" ]] || fail "formal release DMG name changed"
[[ "$(macremoteapp_expected_distribution_name release 0.2.1009 MacRemoteApp-Viewer app-zip)" == "MacRemoteApp-Viewer.app.zip" ]] || fail "formal release app ZIP name changed"

assert_script_contains "${script_dir}/release-notarized.sh" 'MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}"'
assert_script_contains "${script_dir}/package-device-apps.sh" 'MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}"'
assert_script_contains "${script_dir}/validate-notarized-release.sh" 'MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}"'
assert_script_contains "${script_dir}/package-device-apps.sh" 'macremoteapp_require_release_channel "${artifact_channel}"'
assert_script_contains "${script_dir}/notarize-device-apps.sh" 'macremoteapp_require_release_channel "${artifact_channel}"'
assert_script_contains "${script_dir}/audit-release.sh" 'macremoteapp_require_release_channel "${artifact_channel}"'
assert_script_contains "${script_dir}/validate-notarized-release.sh" 'macremoteapp_require_release_channel "${artifact_channel}"'
notarize_forward_count="$(grep -Fc 'MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}"' "${script_dir}/notarize-device-apps.sh")"
[[ "${notarize_forward_count}" == 3 ]] || fail "notarization did not forward the explicit channel to package, DMG, and validation steps"
assert_script_contains "${script_dir}/validate.sh" 'MACREMOTEAPP_ARTIFACT_CHANNEL=testing \'
assert_script_contains "${script_dir}/run-m10-acceptance.sh" 'MACREMOTEAPP_ARTIFACT_CHANNEL=testing \'

if bash "${script_dir}/release-notarized.sh" debug-diagnostic >/dev/null 2>&1; then
    fail "formal release promotion accepted the M10 Debug diagnostic channel"
fi
if [[ -L "${repo_build_root}" || ( -e "${repo_build_root}" && ! -d "${repo_build_root}" ) ]]; then
    fail "the repository build path is not a regular directory for the controlled policy fixture"
fi
if [[ ! -d "${repo_build_root}" ]]; then
    mkdir -p -- "${repo_build_root}"
    created_repo_build_root=1
fi
notarize_policy_fixture="${repo_build_root}/MacRemoteApp-debug.staging.fixture"
if [[ -e "${notarize_policy_fixture}" || -L "${notarize_policy_fixture}" ]]; then
    fail "the controlled notarization policy fixture path already exists"
fi
notarize_policy_output="${test_root}/notarize-debug-channel.txt"
if MACREMOTEAPP_ARTIFACT_CHANNEL=debug-diagnostic \
   MACREMOTEAPP_RELEASE_ROOT="${notarize_policy_fixture}" \
   bash "${script_dir}/notarize-device-apps.sh" >"${notarize_policy_output}" 2>&1; then
    fail "formal M9 notarization accepted the M10 Debug diagnostic channel"
fi
if ! grep -Fq -- 'The M10 Debug diagnostic channel is not eligible for M9 release validation or promotion' \
    "${notarize_policy_output}"; then
    fail "formal M9 notarization did not reject the Debug channel at its channel policy gate"
fi
mkdir -p -- "${test_root}/release-audit"
if MACREMOTEAPP_ARTIFACT_CHANNEL=debug-diagnostic \
   bash "${script_dir}/audit-release.sh" "${test_root}/release-audit" >/dev/null 2>&1; then
    fail "formal M9 release audit accepted the M10 Debug diagnostic channel"
fi
if MACREMOTEAPP_ARTIFACT_CHANNEL=debug-diagnostic \
   bash "${script_dir}/validate-notarized-release.sh" "${test_root}/release-audit" >/dev/null 2>&1; then
    fail "formal M9 notarized validation accepted the M10 Debug diagnostic channel"
fi

MACREMOTEAPP_ARTIFACT_CHANNEL=$'rc\n'
if macremoteapp_resolve_artifact_channel "${test_repo}" "${staging_root}" >/dev/null 2>&1; then
    fail "malformed artifact channel was accepted"
fi
unset MACREMOTEAPP_ARTIFACT_CHANNEL

make_plist "${host_plist}" $'0.2\n' 1009
assert_invalid_identity "${host_plist}" "${viewer_plist}"
make_plist "${host_plist}" 0.2 $'1009\n'
assert_invalid_identity "${host_plist}" "${viewer_plist}"
make_plist "${host_plist}" 0.2x 1009
assert_invalid_identity "${host_plist}" "${viewer_plist}"
make_plist "${host_plist}" 0.2 1009x
assert_invalid_identity "${host_plist}" "${viewer_plist}"
make_plist "${host_plist}" 0.2/../other 1009
assert_invalid_identity "${host_plist}" "${viewer_plist}"
make_plist "${host_plist}" 0.2 1008
assert_invalid_identity "${host_plist}" "${viewer_plist}"

echo "Artifact naming fixtures passed"
