#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
source "${script_dir}/notarization-config.sh"
source "${script_dir}/artifact-naming.sh"

fail() {
    echo "M10 Debug diagnostic notarization validation failed: $*" >&2
    exit 2
}

if (( $# > 1 )); then
    echo "Usage: bash scripts/validate-notarized-debug-diagnostic-apps.sh [build/debug-diagnostic|.build/m10-debug-diagnostic/generation.ID/artifacts]" >&2
    exit 2
fi

release_root="${1:-${repo_root}/build/debug-diagnostic}"
if [[ "${release_root}" != /* ]]; then
    release_root="${repo_root}/${release_root}"
fi
if [[ -L "${release_root}" || ! -d "${release_root}" ]]; then
    fail "the debug artifact directory must exist and must not be a symlink"
fi
release_root="$(cd -P -- "${release_root}" && pwd -P)"
expected_root="${repo_root}/build/debug-diagnostic"
staging_parent="${release_root%/artifacts}"
staging_name="${staging_parent##*/}"
staging_container="${staging_parent%/*}"
expected_staging_container="${repo_root}/.build/m10-debug-diagnostic"
if [[ "${release_root}" == "${expected_root}" ]]; then
    :
elif [[ "${release_root}" == */artifacts &&
        "${staging_container}" == "${expected_staging_container}" &&
        "${staging_name}" == generation.* &&
        "${staging_name#generation.}" =~ ^[A-Za-z0-9]+$ ]]; then
    :
else
    fail "only build/debug-diagnostic or an exact M10 Debug generation staging directory is eligible"
fi

artifact_channel="$(macremoteapp_resolve_artifact_channel "${repo_root}" "${release_root}")" || exit 2
[[ "${artifact_channel}" == "debug-diagnostic" ]] || fail "unexpected artifact channel ${artifact_channel}"
macremoteapp_notarization_helper_path >/dev/null || exit 2
macremoteapp_notary_resolve "${repo_root}"

MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}" \
    bash "${script_dir}/audit-debug-diagnostic-apps.sh" "${release_root}"
release_identity="$(macremoteapp_release_identity \
    "${release_root}/MacRemoteApp-Host.app/Contents/Info.plist" \
    "${release_root}/MacRemoteApp-Viewer.app/Contents/Info.plist")" || exit 2

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    dmg_name="$(macremoteapp_expected_distribution_name \
        "${artifact_channel}" "${release_identity}" "${app_name}" dmg)"
    echo "Validating stapled ticket for ${app_name}.app"
    macremoteapp_notary_verify "${release_root}/${app_name}.app"
    echo "Validating stapled ticket for ${dmg_name}"
    macremoteapp_notary_verify "${release_root}/${dmg_name}"
done

echo "M10 Debug diagnostic notarization validation passed for ${release_identity}: ${release_root}"
