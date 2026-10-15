#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
source "${script_dir}/notarization-config.sh"
source "${script_dir}/artifact-naming.sh"

if (( $# > 1 )); then
    echo "Usage: bash scripts/create-device-dmgs.sh [release-directory]" >&2
    exit 2
fi

release_root="${1:-${repo_root}/build/testing}"

if [[ "${release_root}" != /* ]]; then
    release_root="${repo_root}/${release_root}"
fi
if [[ -L "${release_root}" || ( -e "${release_root}" && ! -d "${release_root}" ) ]]; then
    echo "Release directory must be a regular directory: ${release_root}" >&2
    exit 2
fi
if [[ -d "${release_root}" ]]; then
    release_root="$(cd -- "${release_root}" && pwd -P)"
fi
case "${release_root}" in
    "${repo_root}/build/testing"|"${repo_root}/build/debug-diagnostic"|"${repo_root}/build/MacRemoteApp-"*.staging.*|"${repo_root}/.build/"*)
        ;;
    "${repo_root}/build/beta"|"${repo_root}/build/rc"|"${repo_root}/build/release")
        echo "Refusing to write a formal channel directly; use scripts/release-notarized.sh for replacement-safe notarized promotion: ${release_root}" >&2
        exit 2
        ;;
    *)
        echo "Release directory must be a repository-local build channel or controlled staging directory: ${release_root}" >&2
        exit 2
        ;;
esac
signing_identity="${MACREMOTEAPP_SIGNING_IDENTITY:-}"
if [[ -z "${signing_identity}" ]]; then
    signing_identity="-"
fi
require_developer_id=0
if [[ "${MACREMOTEAPP_REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
    require_developer_id=1
    if [[ "${signing_identity}" == "-" ]]; then
        echo "This DMG path requires a Developer ID Application identity; ad-hoc signing is not allowed." >&2
        exit 2
    fi
fi

[[ -d "${release_root}" ]] || {
    echo "Release directory not found: ${release_root}" >&2
    exit 1
}
artifact_channel="$(macremoteapp_resolve_artifact_channel "${repo_root}" "${release_root}")" || exit 2

select_diagnostic_guide_sources() {
    case "$1" in
        debug-diagnostic)
            debug_guide="${repo_root}/docs/DEBUGGING.md"
            log_guide="${repo_root}/docs/DEBUG_LOG_COLLECTION.md"
            ;;
        testing|beta|rc|release)
            debug_guide="${repo_root}/docs/RELEASE_DEBUGGING.md"
            log_guide="${repo_root}/docs/RELEASE_DEBUG_LOG_COLLECTION.md"
            ;;
        *)
            echo "No diagnostic guides are configured for this artifact channel" >&2
            return 2
            ;;
    esac
}

select_diagnostic_guide_sources "${artifact_channel}" || exit 2
release_identity="$(macremoteapp_release_identity \
    "${release_root}/MacRemoteApp-Host.app/Contents/Info.plist" \
    "${release_root}/MacRemoteApp-Viewer.app/Contents/Info.plist")" || exit 2
echo "Product version: ${release_identity}; artifact channel: ${artifact_channel}"

install_script="${script_dir}/dmg-install.sh"
uninstall_script="${script_dir}/dmg-uninstall.sh"
standalone_uninstall_script="${script_dir}/Uninstall-MacRemoteApp.command"
user_guide="${repo_root}/docs/USER_GUIDE.md"
test -x "${install_script}"
test -x "${uninstall_script}"
test -x "${standalone_uninstall_script}"
test -s "${user_guide}"
test -s "${debug_guide}"
test -s "${log_guide}"
command -v osacompile >/dev/null 2>&1 || {
    echo "The macOS osacompile utility is required to create the per-user Applications drop target." >&2
    exit 1
}

staging_root="$(mktemp -d "${TMPDIR:-/private/tmp}/macremoteapp-dmg-staging.XXXXXX")"
trap 'rm -rf -- "${staging_root}"' EXIT

sign_dmg() {
    local dmg_path="$1"
    if [[ "${signing_identity}" == "-" ]]; then
        codesign --force --sign - --timestamp=none "${dmg_path}"
    else
        codesign --force --sign "${signing_identity}" --timestamp "${dmg_path}"
    fi
    codesign --verify --verbose=2 "${dmg_path}"
    if (( require_developer_id )); then
        local signature_info
        signature_info="$(codesign --display --verbose=4 "${dmg_path}" 2>&1)"
        if ! printf '%s\n' "${signature_info}" | grep -Eq 'Authority=Developer ID Application:'; then
            echo "Formal DMG packaging requires a Developer ID Application signature: ${dmg_path}" >&2
            return 1
        fi
    fi
}

write_payload_manifest() {
    local manifest_path="$1"
    shift
    local payload_path
    local payload_name
    local payload_hash

    : > "${manifest_path}"
    for payload_path in "$@"; do
        payload_name="$(basename -- "${payload_path}")"
        payload_hash="$(shasum -a 256 -- "${payload_path}" | awk '{print $1}')"
        printf '%s  %s\n' "${payload_hash}" "${payload_name}" >> "${manifest_path}"
    done
}

create_applications_drop_target() {
    local output_path="$1"
    local helper_executable
    local helper_binary
    local helper_arches
    local helper_usage_description="MacRemoteApp uses Finder to copy the selected app into your user Applications folder."
    osacompile \
        -o "${output_path}" \
        "${script_dir}/dmg-applications-helper.applescript" >/dev/null

    helper_executable="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleExecutable' \
        "${output_path}/Contents/Info.plist")"
    helper_binary="${output_path}/Contents/MacOS/${helper_executable}"
    test -x "${helper_binary}"
    helper_arches="$(lipo -archs "${helper_binary}")"
    if ! printf '%s\n' "${helper_arches}" | grep -Eq '(^|[[:space:]])arm64([[:space:]]|$)' ||
       ! printf '%s\n' "${helper_arches}" | grep -Eq '(^|[[:space:]])x86_64([[:space:]]|$)'; then
        echo "Applications drop target must contain both arm64 and x86_64 slices; found: ${helper_arches}" >&2
        return 1
    fi

    /usr/libexec/PlistBuddy \
        -c "Set :NSAppleEventsUsageDescription ${helper_usage_description}" \
        "${output_path}/Contents/Info.plist" 2>/dev/null ||
        /usr/libexec/PlistBuddy \
            -c "Add :NSAppleEventsUsageDescription string ${helper_usage_description}" \
            "${output_path}/Contents/Info.plist"

    macremoteapp_sign_app \
        "${output_path}" \
        "${signing_identity}" \
        "${script_dir}/dmg-applications-helper.entitlements"
    codesign --verify --deep --strict "${output_path}"
    local signature_info
    signature_info="$(codesign --display --verbose=4 "${output_path}" 2>&1)"
    if ! printf '%s\n' "${signature_info}" | grep -Eq 'flags=.*runtime'; then
        echo "Applications drop target must use the hardened runtime: ${output_path}" >&2
        return 1
    fi
    local entitlement_info
    entitlement_info="$(codesign --display --entitlements :- "${output_path}" 2>&1)"
    if ! printf '%s\n' "${entitlement_info}" | grep -Eq 'com\.apple\.security\.automation\.apple-events'; then
        echo "Applications drop target must allow Finder Apple Events: ${output_path}" >&2
        return 1
    fi
}

create_dmg() {
    local app_name="$1"
    local role_name="${app_name#MacRemoteApp-}"
    local volume_name="MacRemoteApp ${role_name}"
    local app_path="${release_root}/${app_name}.app"
    local staging_dir="${staging_root}/${role_name}"
    local dmg_name
    local alternate_dmg_name
    local dmg_path

    dmg_name="$(macremoteapp_expected_distribution_name \
        "${artifact_channel}" "${release_identity}" "${app_name}" dmg)"
    if [[ "${artifact_channel}" == "release" ]]; then
        alternate_dmg_name="$(macremoteapp_expected_distribution_name \
            testing "${release_identity}" "${app_name}" dmg)"
    else
        alternate_dmg_name="${app_name}.dmg"
    fi
    dmg_path="${release_root}/${dmg_name}"

    if [[ -e "${release_root}/${alternate_dmg_name}" || -L "${release_root}/${alternate_dmg_name}" ]]; then
        echo "Refusing ambiguous distribution output; unexpected alternate name exists: ${alternate_dmg_name}" >&2
        return 1
    fi

    test -d "${app_path}"
    codesign --verify --deep --strict "${app_path}"
    if (( require_developer_id )); then
        local app_signature_info
        app_signature_info="$(codesign --display --verbose=4 "${app_path}" 2>&1)"
        if ! printf '%s\n' "${app_signature_info}" | grep -Eq 'Authority=Developer ID Application:'; then
            echo "Formal DMG packaging requires a Developer ID Application-signed app payload: ${app_path}" >&2
            return 1
        fi
        if ! printf '%s\n' "${app_signature_info}" | grep -Eq 'flags=.*runtime'; then
            echo "Formal DMG packaging requires a hardened-runtime app payload: ${app_path}" >&2
            return 1
        fi
    fi
    rm -f -- "${dmg_path}"
    mkdir -p -- "${staging_dir}"
    ditto -- "${app_path}" "${staging_dir}/${app_name}.app"
    create_applications_drop_target "${staging_dir}/Applications.app"
    cp -- "${install_script}" "${staging_dir}/Install-MacRemoteApp-${role_name}.command"
    cp -- "${uninstall_script}" "${staging_dir}/Uninstall-MacRemoteApp-${role_name}.command"
    cp -- "${standalone_uninstall_script}" "${staging_dir}/Uninstall-MacRemoteApp.command"
    cp -- "${user_guide}" "${staging_dir}/MacRemoteApp-User-Guide.txt"
    cp -- "${debug_guide}" "${staging_dir}/MacRemoteApp-How-to-Debug.txt"
    cp -- "${log_guide}" "${staging_dir}/MacRemoteApp-How-to-Collect-Debug-Logs.txt"
    chmod 755 \
        "${staging_dir}/Install-MacRemoteApp-${role_name}.command" \
        "${staging_dir}/Uninstall-MacRemoteApp-${role_name}.command" \
        "${staging_dir}/Uninstall-MacRemoteApp.command"
    write_payload_manifest \
        "${staging_dir}/MacRemoteApp-${role_name}-payload.sha256" \
        "${staging_dir}/Install-MacRemoteApp-${role_name}.command" \
        "${staging_dir}/Uninstall-MacRemoteApp-${role_name}.command" \
        "${staging_dir}/Uninstall-MacRemoteApp.command" \
        "${staging_dir}/MacRemoteApp-User-Guide.txt" \
        "${staging_dir}/MacRemoteApp-How-to-Debug.txt" \
        "${staging_dir}/MacRemoteApp-How-to-Collect-Debug-Logs.txt"

    hdiutil create \
        -volname "${volume_name}" \
        -srcfolder "${staging_dir}" \
        -ov \
        -format UDZO \
        "${dmg_path}" >/dev/null
    sign_dmg "${dmg_path}"
    echo "DMG: ${dmg_name}"
}

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    create_dmg "${app_name}"
done
