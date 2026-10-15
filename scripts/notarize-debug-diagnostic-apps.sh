#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
source "${script_dir}/notarization-config.sh"
source "${script_dir}/artifact-naming.sh"

fail() {
    echo "M10 Debug diagnostic notarization failed: $*" >&2
    exit 2
}

if (( $# != 0 )); then
    echo "Usage: bash scripts/notarize-debug-diagnostic-apps.sh" >&2
    exit 2
fi

release_root="${repo_root}/build/debug-diagnostic"
build_root="${repo_root}/.build/m10-debug-diagnostic"
if [[ "${MACREMOTEAPP_RELEASE_ROOT+x}" == "x" &&
      "${MACREMOTEAPP_RELEASE_ROOT}" != "${release_root}" ]]; then
    fail "MACREMOTEAPP_RELEASE_ROOT is fixed to ${release_root}"
fi
if [[ "${MACREMOTEAPP_ARTIFACT_CHANNEL+x}" == "x" &&
      "${MACREMOTEAPP_ARTIFACT_CHANNEL}" != "debug-diagnostic" ]]; then
    fail "MACREMOTEAPP_ARTIFACT_CHANNEL must be debug-diagnostic"
fi
artifact_channel="$(macremoteapp_resolve_artifact_channel \
    "${repo_root}" "${release_root}")" || exit 2
[[ "${artifact_channel}" == "debug-diagnostic" ]] || fail "unexpected channel ${artifact_channel}"

macremoteapp_notary_resolve "${repo_root}"
signing_identity="$(macremoteapp_resolve_signing_identity -)" || fail "unable to resolve the Developer ID identity"
[[ -n "${signing_identity}" && "${signing_identity}" != "-" ]] ||
    fail "a Developer ID Application identity is required"

stage_root="$(env \
    MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}" \
    MACREMOTEAPP_RELEASE_BUILD_ROOT="${build_root}" \
    MACREMOTEAPP_SIGNING_IDENTITY="${signing_identity}" \
    bash "${script_dir}/package-debug-diagnostic-apps.sh" --stage)" ||
    fail "unable to build and audit the staged Debug diagnostic artifacts"

generation_root="${stage_root%/artifacts}"
generation_name="${generation_root##*/}"
generation_parent="${generation_root%/*}"
if [[ "${generation_parent}" != "${build_root}" ||
      "${generation_name}" != generation.* ||
      ! "${generation_name#generation.}" =~ ^[A-Za-z0-9]+$ ||
      -L "${generation_root}" || ! -d "${generation_root}" ]]; then
    fail "the package script returned an unexpected staging generation"
fi

release_identity="$(macremoteapp_release_identity \
    "${stage_root}/MacRemoteApp-Host.app/Contents/Info.plist" \
    "${stage_root}/MacRemoteApp-Viewer.app/Contents/Info.plist")" || exit 2
notarized_zip_dir="$(mktemp -d "${generation_root}/notarized-zips.XXXXXX")"

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    app_path="${stage_root}/${app_name}.app"
    app_zip_name="$(macremoteapp_expected_distribution_name \
        "${artifact_channel}" "${release_identity}" "${app_name}" app-zip)"
    app_zip="${stage_root}/${app_zip_name}"
    test -d "${app_path}"
    test -s "${app_zip}"

    signature_info="$(codesign --display --verbose=4 "${app_path}" 2>&1)"
    printf '%s\n' "${signature_info}" | grep -Eq 'Authority=Developer ID Application:' ||
        fail "${app_name} is not Developer ID signed"
    printf '%s\n' "${signature_info}" | grep -Eq 'flags=.*runtime' ||
        fail "${app_name} does not use the hardened runtime"

    echo "Submitting ${app_zip_name} using the configured notarization authentication."
    macremoteapp_notary_submit "${app_zip}"

    echo "Stapling and verifying ${app_name}.app"
    macremoteapp_notary_staple "${app_path}"
    macremoteapp_notary_verify "${app_path}"

    notarized_zip="${notarized_zip_dir}/${app_zip_name}"
    ditto -c -k --keepParent "${app_path}" "${notarized_zip}"
    mv -f -- "${notarized_zip}" "${app_zip}"
done

env \
    MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}" \
    MACREMOTEAPP_SIGNING_IDENTITY="${signing_identity}" \
    MACREMOTEAPP_REQUIRE_DEVELOPER_ID=1 \
    bash "${script_dir}/create-device-dmgs.sh" "${stage_root}"

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    dmg_name="$(macremoteapp_expected_distribution_name \
        "${artifact_channel}" "${release_identity}" "${app_name}" dmg)"
    dmg_path="${stage_root}/${dmg_name}"
    test -s "${dmg_path}"

    echo "Submitting ${dmg_name} using the configured notarization authentication."
    macremoteapp_notary_submit "${dmg_path}"

    echo "Stapling and verifying ${dmg_name}"
    macremoteapp_notary_staple "${dmg_path}"
    macremoteapp_notary_verify "${dmg_path}"
done

env MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}" \
    bash "${script_dir}/validate-notarized-debug-diagnostic-apps.sh" "${stage_root}"

MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}" \
    bash "${script_dir}/promote-debug-diagnostic-apps.sh" "${stage_root}"

if [[ -d "${generation_root}" && ! -L "${generation_root}" ]]; then
    rm -rf -- "${generation_root}"
fi
echo "M10 Debug diagnostic notarization passed for ${release_identity}: apps and DMGs are signed, stapled, validated, and promoted"
echo "Debug diagnostic artifacts: ${release_root}"
