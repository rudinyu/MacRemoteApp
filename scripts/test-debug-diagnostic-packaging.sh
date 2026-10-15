#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
test_root="$(mktemp -d "${TMPDIR:-/private/tmp}/macremoteapp-debug-package-test.XXXXXX")"
trap 'rm -rf -- "${test_root}"' EXIT
source "${script_dir}/artifact-naming.sh"

fail() {
    echo "M10 Debug diagnostic packaging test failed: $*" >&2
    exit 1
}

assert_script_contains() {
    local script_path="$1"
    local expected="$2"
    if ! grep -Fq -- "${expected}" "${script_path}"; then
        fail "expected packaging contract is missing from $(basename -- "${script_path}")"
    fi
}

assert_script_contains "${script_dir}/create-device-dmgs.sh" \
    'select_diagnostic_guide_sources "${artifact_channel}"'
guide_source_function="${test_root}/select-diagnostic-guide-sources.sh"
if ! awk '
    /^select_diagnostic_guide_sources\(\) \{/ { inside=1 }
    inside { print }
    inside && /^}/ { found=1; exit }
    END { if (!found) exit 1 }
' "${script_dir}/create-device-dmgs.sh" >"${guide_source_function}"; then
    fail "DMG script has no testable diagnostic-guide source selector"
fi
source "${guide_source_function}"
select_diagnostic_guide_sources debug-diagnostic || fail "Debug diagnostic guide selection failed"
[[ "${debug_guide}" == "${repo_root}/docs/DEBUGGING.md" ]] ||
    fail "Debug diagnostic DMGs do not select the in-house Debug guide"
[[ "${log_guide}" == "${repo_root}/docs/DEBUG_LOG_COLLECTION.md" ]] ||
    fail "Debug diagnostic DMGs do not select the in-house log collection guide"
for release_channel in testing beta rc release; do
    select_diagnostic_guide_sources "${release_channel}" ||
        fail "${release_channel} guide selection failed"
    [[ "${debug_guide}" == "${repo_root}/docs/RELEASE_DEBUGGING.md" ]] ||
        fail "${release_channel} DMGs do not select the release Debug guide"
    [[ "${log_guide}" == "${repo_root}/docs/RELEASE_DEBUG_LOG_COLLECTION.md" ]] ||
        fail "${release_channel} DMGs do not select the release log collection guide"
    test -s "${debug_guide}" || fail "release Debug guide is missing"
    test -s "${log_guide}" || fail "release log collection guide is missing"
done
if select_diagnostic_guide_sources unknown >/dev/null 2>&1; then
    fail "unknown channels were accepted by diagnostic-guide selection"
fi

test_repo="${test_root}/repo"
resolved_channel="$(macremoteapp_resolve_artifact_channel \
    "${test_repo}" "${test_repo}/build/debug-diagnostic")"
[[ "${resolved_channel}" == "debug-diagnostic" ]] || fail "debug output path did not resolve to its isolated channel"
debug_stage="${test_repo}/.build/m10-debug-diagnostic/generation.fixture123/artifacts"
if macremoteapp_resolve_artifact_channel "${test_repo}" "${debug_stage}" >/dev/null 2>&1; then
    fail "Debug staging was accepted without an explicit channel"
fi
resolved_channel="$(MACREMOTEAPP_ARTIFACT_CHANNEL=debug-diagnostic \
    macremoteapp_resolve_artifact_channel "${test_repo}" "${debug_stage}")"
[[ "${resolved_channel}" == "debug-diagnostic" ]] || fail "Debug staging did not resolve with its explicit channel"
if MACREMOTEAPP_ARTIFACT_CHANNEL=release \
   macremoteapp_resolve_artifact_channel "${test_repo}" "${debug_stage}" >/dev/null 2>&1; then
    fail "formal release channel was accepted for M10 Debug staging"
fi
[[ "$(macremoteapp_expected_distribution_name debug-diagnostic 0.2.1013 MacRemoteApp-Host dmg)" == \
   "MacRemoteApp-Host-debug-diagnostic-0.2.1013.dmg" ]] || fail "debug DMG name omitted its channel or version"
[[ "$(macremoteapp_expected_distribution_name debug-diagnostic 0.2.1013 MacRemoteApp-Viewer app-zip)" == \
   "MacRemoteApp-Viewer-debug-diagnostic-0.2.1013.app.zip" ]] || fail "debug app ZIP name omitted its channel or version"

for channel in testing beta rc; do
    [[ "$(macremoteapp_expected_distribution_name "${channel}" 0.2.1013 MacRemoteApp-Host dmg)" == \
       "MacRemoteApp-Host-0.2.1013.dmg" ]] || fail "existing ${channel} DMG naming changed"
done
[[ "$(macremoteapp_expected_distribution_name release 0.2.1013 MacRemoteApp-Host dmg)" == \
   "MacRemoteApp-Host.dmg" ]] || fail "formal release DMG naming changed"
if macremoteapp_require_release_channel debug-diagnostic >/dev/null 2>&1; then
    fail "debug-diagnostic was accepted by the M9 release-channel policy"
fi

assert_script_contains "${script_dir}/package-debug-diagnostic-apps.sh" '--configuration debug'
assert_script_contains "${script_dir}/package-debug-diagnostic-apps.sh" 'empty_entitlements_path="${generation_root}/debug-empty-entitlements.plist"'
assert_script_contains "${script_dir}/package-debug-diagnostic-apps.sh" 'macremoteapp_sign_app "${app_dir}" "${signing_identity}" "${empty_entitlements_path}"'
assert_script_contains "${script_dir}/package-debug-diagnostic-apps.sh" 'build/debug-diagnostic'
assert_script_contains "${script_dir}/package-debug-diagnostic-apps.sh" 'generation.XXXXXX'
assert_script_contains "${script_dir}/package-debug-diagnostic-apps.sh" 'promote-debug-diagnostic-apps.sh'
assert_script_contains "${script_dir}/promote-debug-diagnostic-apps.sh" 'Restored the previous Debug diagnostic artifacts'
assert_script_contains "${script_dir}/promote-debug-diagnostic-apps.sh" 'promotion_was_promoted=0'
assert_script_contains "${script_dir}/promote-debug-diagnostic-apps.sh" 'Validated Debug diagnostic artifacts remain promoted; previous artifacts need manual cleanup at'
assert_script_contains "${script_dir}/notarize-debug-diagnostic-apps.sh" 'promote-debug-diagnostic-apps.sh'
assert_script_contains "${script_dir}/notarize-debug-diagnostic-apps.sh" 'validate-notarized-debug-diagnostic-apps.sh'
assert_script_contains "${script_dir}/package-device-apps.sh" '--configuration release'
assert_script_contains "${script_dir}/release-notarized.sh" 'beta|rc|release'
assert_script_contains "${script_dir}/notarize-device-apps.sh" 'macremoteapp_require_release_channel "${artifact_channel}"'
assert_script_contains "${script_dir}/audit-release.sh" 'macremoteapp_require_release_channel "${artifact_channel}"'
assert_script_contains "${script_dir}/validate-notarized-release.sh" 'macremoteapp_require_release_channel "${artifact_channel}"'

artifact_root="${repo_root}/build/debug-diagnostic"
debug_build_root="${repo_root}/.build/m10-debug-diagnostic"
artifact_root_existed=0
debug_build_root_existed=0
if [[ -e "${artifact_root}" || -L "${artifact_root}" ]]; then
    artifact_root_existed=1
fi
if [[ -e "${debug_build_root}" || -L "${debug_build_root}" ]]; then
    debug_build_root_existed=1
fi
check_output="$(env \
    -u MACREMOTEAPP_ARTIFACT_CHANNEL \
    -u MACREMOTEAPP_RELEASE_ROOT \
    -u MACREMOTEAPP_RELEASE_BUILD_ROOT \
    bash "${script_dir}/package-debug-diagnostic-apps.sh" --check)" ||
    fail "the dry package-path check failed"
for expected in \
    'SwiftPM configuration: debug' \
    'Artifact channel: debug-diagnostic' \
    "App bundles, versioned ZIPs, and DMGs: ${repo_root}/build/debug-diagnostic" \
    'Promotion: audited staging with rollback' \
    'Host architectures: arm64, x86_64; Viewer architecture: arm64'
do
    grep -Fq -- "${expected}" <<<"${check_output}" || fail "dry check omitted: ${expected}"
done
if (( ! artifact_root_existed )) && [[ -e "${artifact_root}" || -L "${artifact_root}" ]]; then
    fail "the dry package-path check created its artifact directory"
fi
if (( ! debug_build_root_existed )) && [[ -e "${debug_build_root}" || -L "${debug_build_root}" ]]; then
    fail "the dry package-path check created its SwiftPM scratch directory"
fi

if grep -Fq -- 'rm -rf -- "${release_root}"' "${script_dir}/package-debug-diagnostic-apps.sh"; then
    fail "the Debug package script may not erase the prior output channel"
fi
assert_script_contains "${script_dir}/promote-debug-diagnostic-apps.sh" 'atomic promotion'

debug_entitlements_fixture="${test_root}/debug-empty-entitlements.plist"
if ! awk '
    /<<.*ENTITLEMENTS/ { inside=1; next }
    inside && /^ENTITLEMENTS$/ { found=1; exit }
    inside { print }
    END { if (!found) exit 1 }
' "${script_dir}/package-debug-diagnostic-apps.sh" >"${debug_entitlements_fixture}"; then
    fail "Debug package script has no explicit empty-entitlements plist"
fi
plutil -lint "${debug_entitlements_fixture}" >/dev/null ||
    fail "Debug signing entitlements are not a valid plist"
debug_entitlements_json="$(plutil -convert json -o - "${debug_entitlements_fixture}" | tr -d '[:space:]')" ||
    fail "unable to inspect the Debug signing entitlements"
[[ "${debug_entitlements_json}" == "{}" ]] ||
    fail "Debug signing entitlements must remain empty to strip SwiftPM development entitlements"

echo "M10 Debug diagnostic packaging fixtures passed"
