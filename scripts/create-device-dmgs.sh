#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"

if (( $# > 1 )); then
    echo "Usage: bash scripts/create-device-dmgs.sh [release-directory]" >&2
    exit 2
fi

release_root="${1:-${repo_root}/build/testing}"
signing_identity="${MACREMOTEAPP_SIGNING_IDENTITY:-}"
if [[ -z "${signing_identity}" ]]; then
    signing_identity="-"
fi

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
    "${repo_root}/build/testing"|"${repo_root}/build/MacRemoteApp-"*.staging.*|"${repo_root}/.build/"*)
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

install_script="${script_dir}/dmg-install.sh"
uninstall_script="${script_dir}/dmg-uninstall.sh"
user_guide="${repo_root}/docs/USER_GUIDE.md"
debug_guide="${repo_root}/docs/DEBUGGING.md"
log_guide="${repo_root}/docs/DEBUG_LOG_COLLECTION.md"
test -x "${install_script}"
test -x "${uninstall_script}"
test -s "${user_guide}"
test -s "${debug_guide}"
test -s "${log_guide}"

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

create_dmg() {
    local app_name="$1"
    local role_name="${app_name#MacRemoteApp-}"
    local volume_name="MacRemoteApp ${role_name}"
    local app_path="${release_root}/${app_name}.app"
    local staging_dir="${staging_root}/${role_name}"
    local dmg_path="${release_root}/${app_name}.dmg"

    test -d "${app_path}"
    codesign --verify --deep --strict "${app_path}"
    if (( require_developer_id )); then
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
    ln -s /Applications "${staging_dir}/Applications"
    cp -- "${install_script}" "${staging_dir}/Install-MacRemoteApp-${role_name}.command"
    cp -- "${uninstall_script}" "${staging_dir}/Uninstall-MacRemoteApp-${role_name}.command"
    cp -- "${user_guide}" "${staging_dir}/MacRemoteApp-User-Guide.txt"
    cp -- "${debug_guide}" "${staging_dir}/MacRemoteApp-How-to-Debug.txt"
    cp -- "${log_guide}" "${staging_dir}/MacRemoteApp-How-to-Collect-Debug-Logs.txt"
    chmod 755 \
        "${staging_dir}/Install-MacRemoteApp-${role_name}.command" \
        "${staging_dir}/Uninstall-MacRemoteApp-${role_name}.command"
    write_payload_manifest \
        "${staging_dir}/MacRemoteApp-${role_name}-payload.sha256" \
        "${staging_dir}/Install-MacRemoteApp-${role_name}.command" \
        "${staging_dir}/Uninstall-MacRemoteApp-${role_name}.command" \
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
    echo "DMG: ${dmg_path}"
}

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    create_dmg "${app_name}"
done
