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
    MacRemoteApp-Host)
        expected_bundle_identifier="com.rudinyu.MacRemoteApp.Host"
        opposite_app_name="MacRemoteApp-Viewer"
        opposite_role_name="Viewer"
        opposite_bundle_identifier="com.rudinyu.MacRemoteApp.Viewer"
        ;;
    MacRemoteApp-Viewer)
        expected_bundle_identifier="com.rudinyu.MacRemoteApp.Viewer"
        opposite_app_name="MacRemoteApp-Host"
        opposite_role_name="Host"
        opposite_bundle_identifier="com.rudinyu.MacRemoteApp.Host"
        ;;
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
opposite_app_path="${destination}/${opposite_app_name}.app"
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
    local bundle_path="$1"
    local signature_info

    if ! signature_info="$(codesign --display --verbose=4 "${bundle_path}" 2>&1)"; then
        return 1
    fi
    printf '%s\n' "${signature_info}" | grep -Eq 'Authority=Developer ID Application:' || return 1
    printf '%s\n' "${signature_info}" | grep -Eq "TeamIdentifier=${expected_team_identifier}"
}

validate_bundle() {
    local bundle_path="$1"
    local expected_name="$2"
    local expected_identifier="$3"
    local bundle_info_plist="${bundle_path}/Contents/Info.plist"
    local bundle_binary="${bundle_path}/Contents/MacOS/${expected_name}"
    local bundle_identifier
    local bundle_executable

    if [[ -L "${bundle_path}" ]]; then
        echo "Refusing to remove an app symlink: ${bundle_path}" >&2
        return 1
    fi
    if [[ ! -e "${bundle_path}" ]]; then
        echo "No MacRemoteApp ${expected_name#MacRemoteApp-} installation found."
        return 2
    fi
    if [[ ! -d "${bundle_path}" ||
          -L "${bundle_info_plist}" || ! -f "${bundle_info_plist}" ||
          -L "${bundle_binary}" || ! -x "${bundle_binary}" ]]; then
        echo "Refusing to remove an incomplete ${expected_name#MacRemoteApp-} app bundle." >&2
        return 1
    fi
    bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${bundle_info_plist}" 2>/dev/null || true)"
    bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${bundle_info_plist}" 2>/dev/null || true)"
    if [[ "${bundle_identifier}" != "${expected_identifier}" ||
          "${bundle_executable}" != "${expected_name}" ]]; then
        echo "Refusing to remove a bundle with an unexpected identity." >&2
        return 1
    fi
    if ! codesign --verify --deep --strict \
        --requirements="identifier \"${expected_identifier}\"" \
        "${bundle_path}" >/dev/null 2>&1; then
        echo "Refusing to remove an app that failed code-signature verification." >&2
        return 1
    fi
    if ! spctl --assess --type exec --verbose=4 "${bundle_path}" >/dev/null 2>&1; then
        echo "Refusing to remove an app that Gatekeeper did not accept." >&2
        return 1
    fi
    if ! validate_developer_id_publisher "${bundle_path}"; then
        echo "Refusing to remove an app without the MacRemoteApp Developer ID publisher." >&2
        return 1
    fi
}

validate_app() {
    validate_bundle "${app_path}" "${app_name}" "${expected_bundle_identifier}"
}

validate_opposite_app() {
    validate_bundle \
        "${opposite_app_path}" \
        "${opposite_app_name}" \
        "${opposite_bundle_identifier}"
}

remove_user_data_path() {
    local path="$1"
    local label="$2"

    case "${path}" in
        "${home_dir}/Library/"*)
            ;;
        *)
            echo "Refusing to remove a path outside this user's Library: ${path}" >&2
            return 1
            ;;
    esac
    if [[ -L "${path}" ]]; then
        echo "Refusing to remove a symlink app-data path: ${path}" >&2
        return 1
    fi
    if [[ -d "${path}" ]]; then
        rm -rf -- "${path}"
        echo "Removed ${label}: ${path}"
    elif [[ -e "${path}" ]]; then
        rm -f -- "${path}"
        echo "Removed ${label}: ${path}"
    fi
}

clear_user_data() {
    local bundle_binary
    local data_app_name
    local data_bundle_identifier
    local data_role_name
    local path

    # Each signed app clears only its own role-specific Keychain namespace.
    # When the other role is installed, let that role's signed executable
    # clear its own trust and private identity as well.
    bundle_binary="${app_path}/Contents/MacOS/${app_name}"
    if ! "${bundle_binary}" --remove-all-data; then
        echo "MacRemoteApp ${role_name} Keychain cleanup failed; app files were retained." >&2
        return 1
    fi
    if [[ -e "${opposite_app_path}" ]]; then
        bundle_binary="${opposite_app_path}/Contents/MacOS/${opposite_app_name}"
        if ! "${bundle_binary}" --remove-all-data; then
            echo "MacRemoteApp ${opposite_role_name} Keychain cleanup failed; app files were retained. Some role data may already have been cleared." >&2
            return 1
        fi
    fi

    # Remove only exact per-user state locations for both roles. These paths
    # cover current and future AppKit/Foundation state without touching other
    # applications or the user's whole Library.
    for data_app_name in "${app_name}" "${opposite_app_name}"; do
        if [[ "${data_app_name}" == "${app_name}" ]]; then
            data_bundle_identifier="${expected_bundle_identifier}"
            data_role_name="${role_name}"
        else
            data_bundle_identifier="${opposite_bundle_identifier}"
            data_role_name="${opposite_role_name}"
        fi
        for path in \
            "${home_dir}/Library/Preferences/${data_bundle_identifier}.plist" \
            "${home_dir}/Library/Preferences/${data_bundle_identifier}.plist.lockfile" \
            "${home_dir}/Library/Application Support/${data_bundle_identifier}" \
            "${home_dir}/Library/Application Support/${data_app_name}" \
            "${home_dir}/Library/Caches/${data_bundle_identifier}" \
            "${home_dir}/Library/Logs/${data_bundle_identifier}" \
            "${home_dir}/Library/Logs/MacRemoteApp-${data_role_name}" \
            "${home_dir}/Library/Saved Application State/${data_bundle_identifier}.savedState" \
            "${home_dir}/Library/Containers/${data_bundle_identifier}" \
            "${home_dir}/Library/Group Containers/${data_bundle_identifier}" \
            "${home_dir}/Library/HTTPStorages/${data_bundle_identifier}" \
            "${home_dir}/Library/WebKit/${data_bundle_identifier}"
        do
            remove_user_data_path "${path}" "MacRemoteApp ${data_role_name} app data" || return 1
        done
    done
}

validation_status=0
validate_app || validation_status=$?
if (( validation_status != 0 )); then
    if (( validation_status == 2 )); then
        exit 0
    fi
    exit "${validation_status}"
fi

if [[ -e "${opposite_app_path}" || -L "${opposite_app_path}" ]]; then
    if ! validate_opposite_app; then
        echo "Refusing to clear both roles because the installed ${opposite_role_name} app is not a verified MacRemoteApp bundle." >&2
        exit 1
    fi
fi

read -r -p "Clear MacRemoteApp Host and Viewer data, then move ${app_path} to the Trash? [y/N] " answer
[[ "${answer}" =~ ^[Yy]$ ]] || { echo "Nothing removed."; exit 0; }

quit_role_if_running() {
    local process_name="$1"
    local bundle_identifier="$2"
    local label="$3"

    if ! pgrep -x "${process_name}" >/dev/null 2>&1; then
        return 0
    fi
    echo "Requesting ${label} to quit before cleanup..."
    osascript -e "tell application id \"${bundle_identifier}\" to quit" >/dev/null 2>&1 || true
    for attempt in {1..50}; do
        if ! pgrep -x "${process_name}" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
    if pgrep -x "${process_name}" >/dev/null 2>&1; then
        echo "${label} is still running; quit it and rerun the uninstaller." >&2
        exit 1
    fi
}

quit_role_if_running "${app_name}" "${expected_bundle_identifier}" "${role_name}"
if [[ -e "${opposite_app_path}" ]]; then
    quit_role_if_running "${opposite_app_name}" "${opposite_bundle_identifier}" "${opposite_role_name}"
fi

if ! validate_app; then
    echo "Refusing to remove a replaced or modified app bundle." >&2
    exit 1
fi
if [[ -e "${opposite_app_path}" ]] && ! validate_opposite_app; then
    echo "Refusing to clear data after the installed ${opposite_role_name} app changed." >&2
    exit 1
fi

clear_user_data

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
