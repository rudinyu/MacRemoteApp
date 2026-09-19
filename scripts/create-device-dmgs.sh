#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"

if (( $# > 1 )); then
    echo "Usage: bash scripts/create-device-dmgs.sh [release-directory]" >&2
    exit 2
fi

release_root="${1:-${repo_root}/.build/device-binaries/release}"
signing_identity="${MACREMOTEAPP_SIGNING_IDENTITY:-}"
if [[ -z "${signing_identity}" ]]; then
    signing_identity="-"
fi

[[ -d "${release_root}" ]] || {
    echo "Release directory not found: ${release_root}" >&2
    exit 1
}

install_script="${script_dir}/install-device-apps.sh"
uninstall_script="${script_dir}/uninstall-device-apps.sh"
test -x "${install_script}"
test -x "${uninstall_script}"

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
    rm -f -- "${dmg_path}"
    mkdir -p -- "${staging_dir}"
    ditto -- "${app_path}" "${staging_dir}/${app_name}.app"
    cp -- "${install_script}" "${staging_dir}/Install-MacRemoteApp-${role_name}.command"
    cp -- "${uninstall_script}" "${staging_dir}/Uninstall-MacRemoteApp-${role_name}.command"
    chmod 755 \
        "${staging_dir}/Install-MacRemoteApp-${role_name}.command" \
        "${staging_dir}/Uninstall-MacRemoteApp-${role_name}.command"

    hdiutil create \
        -volname "${volume_name}" \
        -srcfolder "${staging_dir}" \
        -ov \
        -format UDZO \
        "${dmg_path}" >/dev/null
    sign_dmg "${dmg_path}"
    echo "DMG: ${dmg_path}"
}

create_dmg MacRemoteApp-Host
create_dmg MacRemoteApp-Viewer
