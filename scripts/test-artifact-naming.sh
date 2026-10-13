#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
source "${script_dir}/artifact-naming.sh"

test_root="$(mktemp -d "${TMPDIR:-/private/tmp}/macremoteapp-artifact-naming.XXXXXX")"
trap 'rm -rf -- "${test_root}"' EXIT

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

for channel in testing beta rc release; do
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

for channel in testing beta rc; do
    MACREMOTEAPP_ARTIFACT_CHANNEL="${channel}"
    resolved_channel="$(macremoteapp_resolve_artifact_channel "${test_repo}" "${staging_root}")"
    [[ "${resolved_channel}" == "${channel}" ]] || fail "explicit ${channel} staging channel was not retained"
    expected_dmg="$(macremoteapp_expected_distribution_name "${channel}" 0.2.1009 MacRemoteApp-Host dmg)"
    expected_zip="$(macremoteapp_expected_distribution_name "${channel}" 0.2.1009 MacRemoteApp-Viewer app-zip)"
    [[ "${expected_dmg}" == "MacRemoteApp-Host-0.2.1009.dmg" ]] || fail "${channel} DMG name was not versioned"
    [[ "${expected_zip}" == "MacRemoteApp-Viewer-0.2.1009.app.zip" ]] || fail "${channel} app ZIP name was not versioned"
done

MACREMOTEAPP_ARTIFACT_CHANNEL=release
resolved_channel="$(macremoteapp_resolve_artifact_channel "${test_repo}" "${staging_root}")"
[[ "${resolved_channel}" == release ]] || fail "explicit release channel was not retained through staging"
[[ "$(macremoteapp_expected_distribution_name release 0.2.1009 MacRemoteApp-Host dmg)" == "MacRemoteApp-Host.dmg" ]] || fail "formal release DMG name changed"
[[ "$(macremoteapp_expected_distribution_name release 0.2.1009 MacRemoteApp-Viewer app-zip)" == "MacRemoteApp-Viewer.app.zip" ]] || fail "formal release app ZIP name changed"

assert_script_contains "${script_dir}/release-notarized.sh" 'MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}"'
assert_script_contains "${script_dir}/package-device-apps.sh" 'MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}"'
assert_script_contains "${script_dir}/validate-notarized-release.sh" 'MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}"'
notarize_forward_count="$(grep -Fc 'MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}"' "${script_dir}/notarize-device-apps.sh")"
[[ "${notarize_forward_count}" == 3 ]] || fail "notarization did not forward the explicit channel to package, DMG, and validation steps"
assert_script_contains "${script_dir}/validate.sh" 'MACREMOTEAPP_ARTIFACT_CHANNEL=testing \'
assert_script_contains "${script_dir}/run-m10-acceptance.sh" 'MACREMOTEAPP_ARTIFACT_CHANNEL=testing \'

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
