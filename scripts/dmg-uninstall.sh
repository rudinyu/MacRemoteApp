#!/usr/bin/env bash
set -euo pipefail

script_name="$(basename -- "$0")"
case "${script_name}" in
    *Host*) app_name="MacRemoteApp-Host"; role_name="Host" ;;
    *Viewer*) app_name="MacRemoteApp-Viewer"; role_name="Viewer" ;;
    *)
        echo "Open the role-specific MacRemoteApp uninstaller from the DMG." >&2
        exit 2
        ;;
esac

if (( $# > 0 )); then
    echo "This uninstaller is opened by double-clicking it from the DMG." >&2
    exit 2
fi

case "${app_name}" in
    MacRemoteApp-Host) expected_bundle_identifier="com.rudinyu.MacRemoteApp.Host" ;;
    MacRemoteApp-Viewer) expected_bundle_identifier="com.rudinyu.MacRemoteApp.Viewer" ;;
esac
expected_team_identifier="LYK4LV2859"

home_dir="$(cd -P -- "${HOME:?}" && pwd -P)"
destination="${home_dir}/Applications"
if [[ -L "${destination}" ||
      ( -e "${destination}" && ! -d "${destination}" ) ]]; then
    echo "Refusing to use a symlink or non-directory per-user Applications path: ${destination}" >&2
    exit 1
fi
if [[ ! -d "${destination}" ]]; then
    echo "No MacRemoteApp ${role_name} installation found."
    exit 0
fi
destination="$(cd -P -- "${destination}" && pwd -P)"
if [[ "${destination}" != "${home_dir}/Applications" ]]; then
    echo "Refusing an Applications path outside the current user's home: ${destination}" >&2
    exit 1
fi
app_path="${destination}/${app_name}.app"
lifecycle_lock="${destination}/.${app_name}.install.lock"

if [[ -L "${lifecycle_lock}" ||
      ( -e "${lifecycle_lock}" && ! -f "${lifecycle_lock}" ) ]]; then
    echo "Refusing an unexpected DMG lifecycle lock: ${lifecycle_lock}" >&2
    exit 1
fi

lifecycle_locked="${MACREMOTEAPP_DMG_LIFECYCLE_LOCKED:-0}"
if [[ "${lifecycle_locked}" != "1" ]]; then
    command -v lockf >/dev/null 2>&1 || {
        echo "The macOS lockf utility is required for removal." >&2
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

validate_developer_id_publisher() {
    local signature_info

    if ! signature_info="$(codesign --display --verbose=4 "${app_path}" 2>&1)"; then
        return 1
    fi
    printf '%s\n' "${signature_info}" | grep -Eq 'Authority=Developer ID Application:' || return 1
    printf '%s\n' "${signature_info}" | grep -Eq "TeamIdentifier=${expected_team_identifier}"
}

validate_app() {
    local bundle_info_plist="${app_path}/Contents/Info.plist"
    local bundle_binary="${app_path}/Contents/MacOS/${app_name}"
    local bundle_identifier
    local bundle_executable

    if [[ -L "${app_path}" ]]; then
        echo "Refusing to remove an app symlink: ${app_path}" >&2
        return 1
    fi
    if [[ ! -e "${app_path}" ]]; then
        echo "No MacRemoteApp ${role_name} installation found."
        return 2
    fi
    if [[ ! -d "${app_path}" ||
          -L "${bundle_info_plist}" || ! -f "${bundle_info_plist}" ||
          -L "${bundle_binary}" || ! -x "${bundle_binary}" ]]; then
        echo "Refusing to remove an incomplete ${role_name} app bundle." >&2
        return 1
    fi
    bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${bundle_info_plist}" 2>/dev/null || true)"
    bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${bundle_info_plist}" 2>/dev/null || true)"
    if [[ "${bundle_identifier}" != "${expected_bundle_identifier}" ||
          "${bundle_executable}" != "${app_name}" ]]; then
        echo "Refusing to remove a bundle with an unexpected identity." >&2
        return 1
    fi
    if ! codesign --verify --deep --strict \
        --requirements="identifier \"${expected_bundle_identifier}\"" \
        "${app_path}" >/dev/null 2>&1; then
        echo "Refusing to remove an app that failed code-signature verification." >&2
        return 1
    fi
    if ! spctl --assess --type exec --verbose=4 "${app_path}" >/dev/null 2>&1; then
        echo "Refusing to remove an app that Gatekeeper did not accept." >&2
        return 1
    fi
    if ! validate_developer_id_publisher; then
        echo "Refusing to remove an app without the MacRemoteApp Developer ID publisher." >&2
        return 1
    fi
}

validation_status=0
validate_app || validation_status=$?
if (( validation_status != 0 )); then
    if (( validation_status == 2 )); then
        exit 0
    fi
    exit "${validation_status}"
fi

read -r -p "Move ${app_path} to the Trash? [y/N] " answer
[[ "${answer}" =~ ^[Yy]$ ]] || { echo "Nothing removed."; exit 0; }

if pgrep -x "${app_name}" >/dev/null 2>&1; then
    echo "Requesting ${role_name} to quit before removal..."
    osascript -e "tell application id \"${expected_bundle_identifier}\" to quit" >/dev/null 2>&1 || true
    for attempt in {1..50}; do
        if ! pgrep -x "${app_name}" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
    if pgrep -x "${app_name}" >/dev/null 2>&1; then
        echo "${role_name} is still running; quit it and rerun the uninstaller." >&2
        exit 1
    fi
fi

if ! validate_app; then
    echo "Refusing to remove a replaced or modified app bundle." >&2
    exit 1
fi

trash_dir="${home_dir}/.Trash"
if [[ -L "${trash_dir}" ||
      ( -e "${trash_dir}" && ! -d "${trash_dir}" ) ]]; then
    echo "Refusing to use a symlink or non-directory Trash path: ${trash_dir}" >&2
    exit 1
fi
mkdir -p -- "${trash_dir}"
if [[ -L "${trash_dir}" || ! -d "${trash_dir}" ]]; then
    echo "Refusing an unexpected Trash path: ${trash_dir}" >&2
    exit 1
fi
trash_dir="$(cd -P -- "${trash_dir}" && pwd -P)"
if [[ "${trash_dir}" != "${home_dir}/.Trash" ]]; then
    echo "Refusing a Trash path outside the current user's home: ${trash_dir}" >&2
    exit 1
fi
trash_path="${trash_dir}/${app_name}.app"
suffix=0
while [[ -e "${trash_path}" || -L "${trash_path}" ]]; do
    (( suffix += 1 ))
    trash_path="${trash_dir}/${app_name}-$(/bin/date +%s)-${suffix}.app"
done
mv -- "${app_path}" "${trash_path}"
echo "Moved ${app_path} to the Trash."
