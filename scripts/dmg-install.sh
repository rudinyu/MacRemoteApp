#!/usr/bin/env bash
set -euo pipefail

script_name="$(basename -- "$0")"
case "${script_name}" in
    *Host*) app_name="MacRemoteApp-Host"; role_name="Host" ;;
    *Viewer*) app_name="MacRemoteApp-Viewer"; role_name="Viewer" ;;
    *)
        echo "Open the role-specific MacRemoteApp installer from the DMG." >&2
        exit 2
        ;;
esac

if (( $# > 0 )); then
    echo "This installer is opened by double-clicking it from the DMG." >&2
    exit 2
fi

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
source_app="${script_dir}/${app_name}.app"
home_dir="$(cd -P -- "${HOME:?}" && pwd -P)"
destination="${home_dir}/Applications"

case "${app_name}" in
    MacRemoteApp-Host) expected_bundle_identifier="com.rudinyu.MacRemoteApp.Host" ;;
    MacRemoteApp-Viewer) expected_bundle_identifier="com.rudinyu.MacRemoteApp.Viewer" ;;
esac
expected_team_identifier="LYK4LV2859"

validate_bundle_identity() {
    local app_path="$1"
    local info_plist="${app_path}/Contents/Info.plist"
    local binary_path="${app_path}/Contents/MacOS/${app_name}"
    local bundle_identifier
    local bundle_executable

    if [[ -L "${app_path}" || ! -d "${app_path}" ||
          -L "${info_plist}" || ! -f "${info_plist}" ||
          -L "${binary_path}" || ! -x "${binary_path}" ]]; then
        return 1
    fi
    bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info_plist}" 2>/dev/null || true)"
    bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${info_plist}" 2>/dev/null || true)"
    [[ "${bundle_identifier}" == "${expected_bundle_identifier}" &&
       "${bundle_executable}" == "${app_name}" ]]
}

validate_developer_id_publisher() {
    local app_path="$1"
    local signature_info

    if ! signature_info="$(codesign --display --verbose=4 "${app_path}" 2>&1)"; then
        return 1
    fi
    printf '%s\n' "${signature_info}" | grep -Eq 'Authority=Developer ID Application:' || return 1
    printf '%s\n' "${signature_info}" | grep -Eq "TeamIdentifier=${expected_team_identifier}"
}

if ! validate_bundle_identity "${source_app}"; then
    echo "The ${role_name} app is missing or incomplete in this DMG." >&2
    exit 1
fi

if ! codesign --verify --deep --strict "${source_app}" ||
   ! spctl --assess --type exec --verbose=4 "${source_app}" >/dev/null 2>&1 ||
   ! validate_developer_id_publisher "${source_app}"; then
    echo "Gatekeeper rejected the ${role_name} app. Use the notarized DMG." >&2
    exit 1
fi

if [[ -L "${destination}" ||
      ( -e "${destination}" && ! -d "${destination}" ) ]]; then
    echo "Refusing to use a symlink or non-directory per-user Applications path: ${destination}" >&2
    exit 1
fi
mkdir -p -- "${destination}"
if [[ -L "${destination}" || ! -d "${destination}" ]]; then
    echo "Refusing an unexpected per-user Applications path: ${destination}" >&2
    exit 1
fi
destination="$(cd -P -- "${destination}" && pwd -P)"
if [[ "${destination}" != "${home_dir}/Applications" ]]; then
    echo "Refusing an Applications path outside the current user's home: ${destination}" >&2
    exit 1
fi
destination_app="${destination}/${app_name}.app"
lifecycle_lock="${destination}/.${app_name}.install.lock"

if [[ -L "${lifecycle_lock}" ||
      ( -e "${lifecycle_lock}" && ! -f "${lifecycle_lock}" ) ]]; then
    echo "Refusing an unexpected DMG lifecycle lock: ${lifecycle_lock}" >&2
    exit 1
fi

lifecycle_locked="${MACREMOTEAPP_DMG_LIFECYCLE_LOCKED:-0}"
if [[ "${lifecycle_locked}" != "1" ]]; then
    command -v lockf >/dev/null 2>&1 || {
        echo "The macOS lockf utility is required for installation." >&2
        exit 1
    }
    lock_status=0
    lockf -t 0 "${lifecycle_lock}" \
        env MACREMOTEAPP_DMG_LIFECYCLE_LOCKED=1 "$0" || lock_status=$?
    # Keep the pathname stable. A later invocation can safely reuse the file;
    # unlinking it would allow a new lock holder to be detached from this path.
    if (( lock_status == 75 )); then
        echo "Another ${role_name} installation or removal is already in progress." >&2
    fi
    exit "${lock_status}"
fi

staging_dir=""
cleanup() {
    if [[ -n "${staging_dir}" && -d "${staging_dir}" ]]; then
        rm -rf -- "${staging_dir}"
    fi
}
trap cleanup EXIT

recover_interrupted_install() {
    local backup_dir=""
    local backup_app
    local candidate
    local backup_count=0

    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        backup_dir="${candidate}"
        (( backup_count += 1 ))
    done < <(find "${destination}" -mindepth 1 -maxdepth 1 -type d \
        -name ".${app_name}.backup.*" -print)

    if (( backup_count > 1 )); then
        echo "Multiple interrupted ${role_name} installations need manual recovery." >&2
        return 1
    fi
    if (( backup_count == 1 )); then
        backup_app="${backup_dir}/${app_name}.app"
        if ! validate_bundle_identity "${backup_app}"; then
            echo "Refusing to recover an invalid ${role_name} backup: ${backup_app}" >&2
            return 1
        fi
        if [[ -e "${destination_app}" || -L "${destination_app}" ]]; then
            if [[ -L "${destination_app}" ]] || ! validate_bundle_identity "${destination_app}"; then
                echo "Refusing to discard a backup beside an unexpected destination: ${destination_app}" >&2
                return 1
            fi
            rm -rf -- "${backup_dir}"
        else
            mv -- "${backup_app}" "${destination_app}"
            rmdir -- "${backup_dir}"
            echo "Recovered the previous ${role_name} installation after an interrupted replacement."
        fi
    fi

    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        rm -rf -- "${candidate}"
    done < <(find "${destination}" -mindepth 1 -maxdepth 1 -type d \
        -name ".${app_name}.install.*" -print)
}

recover_interrupted_install

if [[ -L "${destination_app}" ||
      ( -e "${destination_app}" && ! -d "${destination_app}" ) ]]; then
    echo "Refusing to replace an invalid destination: ${destination_app}" >&2
    exit 1
fi
if [[ -d "${destination_app}" ]]; then
    if ! validate_bundle_identity "${destination_app}"; then
        echo "Refusing to replace a bundle with an unexpected identity: ${destination_app}" >&2
        exit 1
    fi
    read -r -p "Replace ${destination_app}? [y/N] " answer
    [[ "${answer}" =~ ^[Yy]$ ]] || { echo "Nothing installed."; exit 0; }
fi

staging_dir="$(mktemp -d "${destination}/.${app_name}.install.XXXXXX")"
backup_dir=""
ditto -- "${source_app}" "${staging_dir}/${app_name}.app"
if [[ -d "${destination_app}" ]]; then
    backup_dir="$(mktemp -d "${destination}/.${app_name}.backup.XXXXXX")"
    mv -- "${destination_app}" "${backup_dir}/${app_name}.app"
fi

if ! mv -- "${staging_dir}/${app_name}.app" "${destination_app}"; then
    if [[ -n "${backup_dir}" && -d "${backup_dir}/${app_name}.app" ]]; then
        mv -- "${backup_dir}/${app_name}.app" "${destination_app}" || true
    fi
    echo "Unable to install the ${role_name} app." >&2
    exit 1
fi

if ! codesign --verify --deep --strict "${destination_app}" ||
   ! spctl --assess --type exec --verbose=4 "${destination_app}" >/dev/null 2>&1 ||
   ! validate_developer_id_publisher "${destination_app}" ||
   ! validate_bundle_identity "${destination_app}"; then
    rm -rf -- "${destination_app}"
    if [[ -n "${backup_dir}" && -d "${backup_dir}/${app_name}.app" ]]; then
        mv -- "${backup_dir}/${app_name}.app" "${destination_app}" || true
    fi
    echo "The installed ${role_name} app failed verification." >&2
    exit 1
fi

if [[ -n "${backup_dir}" ]]; then
    rm -rf -- "${backup_dir}"
fi
echo "Installed ${destination_app}"
