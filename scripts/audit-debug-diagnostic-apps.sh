#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
source "${script_dir}/artifact-naming.sh"

fail() {
    echo "M10 Debug diagnostic audit failed: $*" >&2
    exit 1
}

if (( $# > 1 )); then
    echo "Usage: bash scripts/audit-debug-diagnostic-apps.sh [build/debug-diagnostic|.build/m10-debug-diagnostic/generation.ID/artifacts]" >&2
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
[[ "${artifact_channel}" == "debug-diagnostic" ]] ||
    fail "unexpected artifact channel ${artifact_channel}"
release_identity="$(macremoteapp_release_identity \
    "${release_root}/MacRemoteApp-Host.app/Contents/Info.plist" \
    "${release_root}/MacRemoteApp-Viewer.app/Contents/Info.plist")" || exit 2

audit_tmp_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/macremoteapp-debug-audit.XXXXXX")"
mounted_point=""
cleanup() {
    if [[ -n "${mounted_point}" ]]; then
        hdiutil detach "${mounted_point}" >/dev/null 2>&1 || true
    fi
    rm -rf -- "${audit_tmp_dir}"
}
trap cleanup EXIT

expected_bundle_identifier() {
    case "$1" in
        MacRemoteApp-Host) printf '%s\n' com.rudinyu.MacRemoteApp.Host ;;
        MacRemoteApp-Viewer) printf '%s\n' com.rudinyu.MacRemoteApp.Viewer ;;
        *) return 1 ;;
    esac
}

verify_bundle_identity() {
    local app_name="$1"
    local app_path="$2"
    local bundle_identifier
    local bundle_executable

    [[ -d "${app_path}" && ! -L "${app_path}" ]] || fail "missing app bundle ${app_name}"
    [[ -f "${app_path}/Contents/Info.plist" && ! -L "${app_path}/Contents/Info.plist" ]] ||
        fail "missing bundle metadata for ${app_name}"
    bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "${app_path}/Contents/Info.plist" 2>/dev/null)" || fail "unreadable bundle identifier for ${app_name}"
    bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
        "${app_path}/Contents/Info.plist" 2>/dev/null)" || fail "unreadable executable name for ${app_name}"
    [[ "${bundle_identifier}" == "$(expected_bundle_identifier "${app_name}")" &&
       "${bundle_executable}" == "${app_name}" ]] ||
        fail "bundle identity changed for ${app_name}"
    plutil -lint "${app_path}/Contents/Info.plist" >/dev/null || fail "invalid Info.plist for ${app_name}"
}

verify_developer_id_app() {
    local app_name="$1"
    local app_path="$2"
    local binary_path="${app_path}/Contents/MacOS/${app_name}"
    local signature_info
    local entitlements_path="${audit_tmp_dir}/${app_name}.entitlements"
    local architecture_info

    verify_bundle_identity "${app_name}" "${app_path}"
    [[ -x "${binary_path}" && ! -L "${binary_path}" ]] || fail "missing executable for ${app_name}"
    codesign --verify --deep --strict "${app_path}" || fail "invalid code signature for ${app_name}"
    signature_info="$(codesign --display --verbose=4 "${app_path}" 2>&1)" ||
        fail "missing signature metadata for ${app_name}"
    printf '%s\n' "${signature_info}" | grep -Eq 'Authority=Developer ID Application:' ||
        fail "${app_name} is not signed with Developer ID Application"
    printf '%s\n' "${signature_info}" | grep -Eq 'TeamIdentifier=LYK4LV2859' ||
        fail "${app_name} does not use the existing MacRemoteApp team"
    printf '%s\n' "${signature_info}" | grep -Eq 'flags=.*runtime' ||
        fail "${app_name} does not use the hardened runtime"
    codesign --display --entitlements :- "${app_path}" >"${entitlements_path}" 2>&1 || true
    if grep -Eq 'com\.apple\.security\.get-task-allow|allow-dyld-environment-variables' \
        "${entitlements_path}"; then
        fail "development entitlements are forbidden in ${app_name}"
    fi
    if ! strings "${binary_path}" | grep -F 'MACREMOTEAPP_M10_DEBUG_DIAGNOSTICS' >/dev/null; then
        fail "Debug diagnostic marker is missing from ${app_name}"
    fi
    architecture_info="$(lipo -archs "${binary_path}")" || fail "unable to inspect ${app_name} architectures"
    case "${app_name}:${architecture_info}" in
        MacRemoteApp-Host:*arm64*x86_64*|MacRemoteApp-Host:*x86_64*arm64*) ;;
        MacRemoteApp-Viewer:arm64) ;;
        *) fail "unexpected architecture set for ${app_name}: ${architecture_info}" ;;
    esac
}

assert_distribution_name() {
    local app_name="$1"
    local artifact_kind="$2"
    local expected_name
    local alternate_name

    expected_name="$(macremoteapp_expected_distribution_name \
        "${artifact_channel}" "${release_identity}" "${app_name}" "${artifact_kind}")" || exit 2
    [[ -s "${release_root}/${expected_name}" && ! -L "${release_root}/${expected_name}" ]] ||
        fail "missing versioned ${artifact_kind} ${expected_name}"
    if [[ "${artifact_kind}" == "dmg" ]]; then
        alternate_name="${app_name}.dmg"
    else
        alternate_name="${app_name}.app.zip"
    fi
    [[ ! -e "${release_root}/${alternate_name}" && ! -L "${release_root}/${alternate_name}" ]] ||
        fail "unexpected unversioned distribution artifact ${alternate_name}"
}

verify_app_archive() {
    local app_name="$1"
    local archive_name
    local archive_path
    local extraction_root="${audit_tmp_dir}/${app_name}-zip"
    local extracted_app="${extraction_root}/${app_name}.app"
    local extra_entry

    archive_name="$(macremoteapp_expected_distribution_name \
        "${artifact_channel}" "${release_identity}" "${app_name}" app-zip)"
    archive_path="${release_root}/${archive_name}"
    mkdir -p -- "${extraction_root}"
    ditto -x -k "${archive_path}" "${extraction_root}" || fail "unable to extract ${archive_name}"
    verify_developer_id_app "${app_name}" "${extracted_app}"
    extra_entry="$(find "${extraction_root}" -mindepth 1 -maxdepth 1 \
        ! -name "${app_name}.app" -print -quit)"
    [[ -z "${extra_entry}" ]] || fail "unexpected content in ${archive_name}"
    diff -qr "${release_root}/${app_name}.app" "${extracted_app}" >/dev/null ||
        fail "${archive_name} differs from its app bundle"
}

verify_dmg() {
    local app_name="$1"
    local role_name="${app_name#MacRemoteApp-}"
    local dmg_name
    local dmg_path
    local mount_point="${audit_tmp_dir}/${app_name}-dmg"
    local manifest_name="MacRemoteApp-${role_name}-payload.sha256"
    local expected_manifest="${audit_tmp_dir}/${app_name}.expected.sha256"
    local payload_name
    local extra_entry
    local signature_info

    dmg_name="$(macremoteapp_expected_distribution_name \
        "${artifact_channel}" "${release_identity}" "${app_name}" dmg)"
    dmg_path="${release_root}/${dmg_name}"
    codesign --verify --verbose=2 "${dmg_path}" || fail "invalid DMG signature for ${dmg_name}"
    signature_info="$(codesign --display --verbose=4 "${dmg_path}" 2>&1)" ||
        fail "missing DMG signature metadata for ${dmg_name}"
    printf '%s\n' "${signature_info}" | grep -Eq 'Authority=Developer ID Application:' ||
        fail "${dmg_name} is not Developer ID signed"
    printf '%s\n' "${signature_info}" | grep -Eq 'TeamIdentifier=LYK4LV2859' ||
        fail "${dmg_name} does not use the existing MacRemoteApp team"

    mkdir -p -- "${mount_point}"
    hdiutil attach -readonly -nobrowse -mountpoint "${mount_point}" "${dmg_path}" >/dev/null ||
        fail "unable to mount ${dmg_name} read-only"
    mounted_point="${mount_point}"
    extra_entry="$(find "${mount_point}" -mindepth 1 -maxdepth 1 \
        ! -name "${app_name}.app" \
        ! -name "Install-MacRemoteApp-${role_name}.command" \
        ! -name "Uninstall-MacRemoteApp-${role_name}.command" \
        ! -name Uninstall-MacRemoteApp.command \
        ! -name MacRemoteApp-User-Guide.txt \
        ! -name MacRemoteApp-How-to-Debug.txt \
        ! -name MacRemoteApp-How-to-Collect-Debug-Logs.txt \
        ! -name Applications.app \
        ! -name "${manifest_name}" -print -quit)"
    [[ -z "${extra_entry}" ]] || fail "unexpected payload in ${dmg_name}"

    verify_developer_id_app "${app_name}" "${mount_point}/${app_name}.app"
    diff -qr "${release_root}/${app_name}.app" "${mount_point}/${app_name}.app" >/dev/null ||
        fail "app payload differs inside ${dmg_name}"
    [[ -d "${mount_point}/Applications.app" ]] || fail "missing Applications drop target in ${dmg_name}"
    codesign --verify --deep --strict "${mount_point}/Applications.app" ||
        fail "invalid Applications drop target signature in ${dmg_name}"

    : >"${expected_manifest}"
    for payload_name in \
        "Install-MacRemoteApp-${role_name}.command" \
        "Uninstall-MacRemoteApp-${role_name}.command" \
        Uninstall-MacRemoteApp.command \
        MacRemoteApp-User-Guide.txt \
        MacRemoteApp-How-to-Debug.txt \
        MacRemoteApp-How-to-Collect-Debug-Logs.txt
    do
        [[ -s "${mount_point}/${payload_name}" ]] || fail "missing ${payload_name} in ${dmg_name}"
        printf '%s  %s\n' \
            "$(shasum -a 256 -- "${mount_point}/${payload_name}" | awk '{print $1}')" \
            "${payload_name}" >>"${expected_manifest}"
    done
    for payload_name in \
        "Install-MacRemoteApp-${role_name}.command" \
        "Uninstall-MacRemoteApp-${role_name}.command" \
        Uninstall-MacRemoteApp.command
    do
        [[ -x "${mount_point}/${payload_name}" ]] || fail "non-executable installer helper in ${dmg_name}"
    done
    cmp -s "${expected_manifest}" "${mount_point}/${manifest_name}" ||
        fail "payload manifest mismatch in ${dmg_name}"

    hdiutil detach "${mount_point}" >/dev/null || fail "unable to detach ${dmg_name}"
    mounted_point=""
}

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    assert_distribution_name "${app_name}" app-zip
    assert_distribution_name "${app_name}" dmg
    verify_developer_id_app "${app_name}" "${release_root}/${app_name}.app"
    verify_app_archive "${app_name}"
    verify_dmg "${app_name}"
done

echo "M10 Debug diagnostic audit passed for ${release_identity}: signed hardened Host and Viewer apps, versioned ZIPs, and DMGs"
