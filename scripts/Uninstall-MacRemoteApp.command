#!/bin/bash
set -euo pipefail

readonly SYSTEM_APPLICATIONS="/Applications"
readonly TEAM_IDENTIFIER="LYK4LV2859"
readonly HOST_NAME="MacRemoteApp-Host"
readonly HOST_BUNDLE_ID="com.rudinyu.MacRemoteApp.Host"
readonly VIEWER_NAME="MacRemoteApp-Viewer"
readonly VIEWER_BUNDLE_ID="com.rudinyu.MacRemoteApp.Viewer"
readonly CLEANUP_MINIMUM_BUILD=1003

# Use fixed system tools. The focused fixture test rewrites these paths only in
# a temporary copy of this script; production has no path or command overrides.
readonly ID_TOOL="/usr/bin/id"
readonly DSCL_TOOL="/usr/bin/dscl"
readonly PLIST_BUDDY_TOOL="/usr/libexec/PlistBuddy"
readonly CODESIGN_TOOL="/usr/bin/codesign"
readonly SPCTL_TOOL="/usr/sbin/spctl"
readonly PGREP_TOOL="/usr/bin/pgrep"
readonly TCCUTIL_TOOL="/usr/bin/tccutil"
readonly MKDIR_TOOL="/bin/mkdir"
readonly MV_TOOL="/bin/mv"
readonly RM_TOOL="/bin/rm"
readonly GREP_TOOL="/usr/bin/grep"

usage() {
    /bin/cat <<'EOF'
Cleanly remove MacRemoteApp Host and Viewer from this Mac.

Usage:
  Double-click this file to review and confirm cleanup.
  Uninstall-MacRemoteApp.command --dry-run   Preview without changing anything
  Uninstall-MacRemoteApp.command --help      Show this help

The helper checks signed app bundles in ~/Applications and /Applications,
clears role-owned data through signed builds 1003 or newer, removes exact
MacRemoteApp files from your Library, resets TCC only for the two MacRemoteApp
bundle IDs, and moves removable app bundles to your Trash.

It does not reset Local Network privacy. In System Settings > Privacy &
Security > Local Network, switch off any remaining MacRemoteApp entries.
macOS has no supported way for a script to remove the historical Local Network
entry or return that permission to its undetermined state. Older shared
Keychain records are preserved. Older or unreadable app builds are retained.
EOF
}

mode="interactive"
if (( $# > 1 )); then
    echo "This helper accepts only --help or --dry-run." >&2
    exit 2
fi
case "${1:-}" in
    "") ;;
    --help|-h) usage; exit 0 ;;
    --dry-run) mode="dry-run" ;;
    *) echo "Unknown option: ${1}" >&2; usage >&2; exit 2 ;;
esac

if [[ "$("${ID_TOOL}" -u)" == "0" ]]; then
    echo "Run this helper as your normal macOS user, not as root." >&2
    exit 1
fi

for tool in \
    "${ID_TOOL}" "${DSCL_TOOL}" "${PLIST_BUDDY_TOOL}" \
    "${CODESIGN_TOOL}" "${SPCTL_TOOL}" "${PGREP_TOOL}" \
    "${TCCUTIL_TOOL}" "${MKDIR_TOOL}" "${MV_TOOL}" "${RM_TOOL}" \
    "${GREP_TOOL}"
do
    if [[ ! -x "${tool}" ]]; then
        echo "Required macOS tool is unavailable: ${tool}" >&2
        exit 1
    fi
done

current_user="$("${ID_TOOL}" -un)"
if [[ -z "${current_user}" || "${current_user}" == */* ]]; then
    echo "Could not identify the current macOS user safely." >&2
    exit 1
fi
home_record="$("${DSCL_TOOL}" . -read "/Users/${current_user}" NFSHomeDirectory 2>/dev/null)" || {
    echo "Could not read the current user's home directory from Directory Services." >&2
    exit 1
}
case "${home_record}" in
    "NFSHomeDirectory: "*) home_dir="${home_record#NFSHomeDirectory: }" ;;
    *) echo "Directory Services returned an unexpected home directory record." >&2; exit 1 ;;
esac

path_is_safe() {
    local path="$1"
    local remainder
    local component
    local current=""

    [[ "${path}" == /* && "${path}" != *$'\n'* ]] || return 1
    remainder="${path#/}"
    while [[ -n "${remainder}" ]]; do
        component="${remainder%%/*}"
        if [[ -z "${component}" ]]; then
            if [[ "${remainder}" == */* ]]; then
                remainder="${remainder#*/}"
                continue
            fi
            break
        fi
        [[ "${component}" != "." && "${component}" != ".." ]] || return 1
        current="${current}/${component}"
        [[ ! -L "${current}" ]] || return 1
        if [[ "${remainder}" == */* ]]; then
            remainder="${remainder#*/}"
        else
            break
        fi
    done
    return 0
}

if [[ -z "${home_dir}" || "${home_dir}" == "/" ]] ||
   ! path_is_safe "${home_dir}" || [[ ! -d "${home_dir}" ]]; then
    echo "Refusing an invalid, symlinked, or unavailable home directory." >&2
    exit 1
fi

readonly USER_APPLICATIONS="${home_dir}/Applications"
readonly TRASH_DIR="${home_dir}/.Trash"
readonly ROLE_NAMES=("Host" "Viewer")
readonly APP_NAMES=("${HOST_NAME}" "${VIEWER_NAME}")
readonly BUNDLE_IDS=("${HOST_BUNDLE_ID}" "${VIEWER_BUNDLE_ID}")
APP_PATHS=("")
APP_ROLE_INDICES=(-1)
APP_CLEANUP_SUPPORTED=("")
HELPER_BUNDLES=("" "")
HELPER_BINARIES=("" "")
DATA_PATHS=()
INCOMPLETE=0
ROLE_KEYCHAIN_OK=(0 0)
UNSUPPORTED_APP_COUNT=0

add_role_data_paths() {
    local bundle_id="$1"
    local app_name="$2"
    local role_name="$3"

    DATA_PATHS+=(
        "${home_dir}/Library/Preferences/${bundle_id}.plist"
        "${home_dir}/Library/Preferences/${bundle_id}.plist.lockfile"
        "${home_dir}/Library/Application Support/${bundle_id}"
        "${home_dir}/Library/Application Support/${app_name}"
        "${home_dir}/Library/Caches/${bundle_id}"
        "${home_dir}/Library/Logs/${bundle_id}"
        "${home_dir}/Library/Logs/MacRemoteApp-${role_name}"
        "${home_dir}/Library/Saved Application State/${bundle_id}.savedState"
        "${home_dir}/Library/Containers/${bundle_id}"
        "${home_dir}/Library/Group Containers/${bundle_id}"
        "${home_dir}/Library/HTTPStorages/${bundle_id}"
        "${home_dir}/Library/WebKit/${bundle_id}"
    )
}

validate_bundle() {
    local bundle_path="$1"
    local expected_name="$2"
    local expected_bundle_id="$3"
    local info_plist="${bundle_path}/Contents/Info.plist"
    local bundle_binary="${bundle_path}/Contents/MacOS/${expected_name}"
    local actual_bundle_id
    local actual_executable
    local signature_info

    if ! path_is_safe "${bundle_path}" || [[ ! -d "${bundle_path}" ]]; then
        echo "Refusing an unsafe or incomplete app bundle: ${bundle_path}" >&2
        return 1
    fi
    if ! path_is_safe "${info_plist}" || [[ ! -f "${info_plist}" ]] ||
       ! path_is_safe "${bundle_binary}" || [[ ! -x "${bundle_binary}" ]]; then
        echo "Refusing an incomplete ${expected_name} app bundle." >&2
        return 1
    fi

    actual_bundle_id="$("${PLIST_BUDDY_TOOL}" -c 'Print :CFBundleIdentifier' "${info_plist}" 2>/dev/null)" || {
        echo "Refusing an app with unreadable bundle identity: ${bundle_path}" >&2
        return 1
    }
    actual_executable="$("${PLIST_BUDDY_TOOL}" -c 'Print :CFBundleExecutable' "${info_plist}" 2>/dev/null)" || {
        echo "Refusing an app with unreadable executable identity: ${bundle_path}" >&2
        return 1
    }
    if [[ "${actual_bundle_id}" != "${expected_bundle_id}" ||
          "${actual_executable}" != "${expected_name}" ]]; then
        echo "Refusing a bundle with an unexpected identity: ${bundle_path}" >&2
        return 1
    fi
    if ! "${CODESIGN_TOOL}" --verify --deep --strict \
        --requirements="identifier \"${expected_bundle_id}\"" \
        "${bundle_path}" >/dev/null 2>&1; then
        echo "Refusing an app that failed code-signature verification: ${bundle_path}" >&2
        return 1
    fi
    if ! signature_info="$("${CODESIGN_TOOL}" --display --verbose=4 "${bundle_path}" 2>&1)"; then
        echo "Refusing an app with unreadable signing details: ${bundle_path}" >&2
        return 1
    fi
    if ! printf '%s\n' "${signature_info}" | "${GREP_TOOL}" -Eq '^Authority=Developer ID Application:' ||
       ! printf '%s\n' "${signature_info}" | "${GREP_TOOL}" -Fxq "TeamIdentifier=${TEAM_IDENTIFIER}"; then
        echo "Refusing an app without the MacRemoteApp Developer ID publisher: ${bundle_path}" >&2
        return 1
    fi
    if ! "${SPCTL_TOOL}" --assess --type exec --verbose=4 "${bundle_path}" >/dev/null 2>&1; then
        echo "Refusing an app that Gatekeeper did not accept: ${bundle_path}" >&2
        return 1
    fi
}

bundle_supports_cleanup_cli() {
    local bundle_path="$1"
    local info_plist="${bundle_path}/Contents/Info.plist"
    local build

    if ! build="$("${PLIST_BUDDY_TOOL}" -c 'Print :CFBundleVersion' "${info_plist}" 2>/dev/null)" ||
       [[ -z "${build}" || "${build}" == *[!0-9]* || ${#build} -gt 9 ]]; then
        echo "Unsupported app build at ${bundle_path}; cannot verify the cleanup CLI, so this app will be retained." >&2
        return 1
    fi
    if (( 10#${build} < CLEANUP_MINIMUM_BUILD )); then
        echo "Unsupported app build ${build} at ${bundle_path}; cleanup CLI requires build ${CLEANUP_MINIMUM_BUILD} or newer, so this app will be retained." >&2
        return 1
    fi
    CLEANUP_SUPPORTED_BUILD="${build}"
    return 0
}

find_running_roles() {
    local role_index
    local running=""
    local pgrep_status
    for role_index in 0 1; do
        if "${PGREP_TOOL}" -x "${APP_NAMES[role_index]}" >/dev/null 2>&1; then
            [[ -z "${running}" ]] || running+=", "
            running+="${ROLE_NAMES[role_index]}"
        else
            pgrep_status=$?
            if (( pgrep_status != 1 )); then
                echo "Could not determine whether MacRemoteApp ${ROLE_NAMES[role_index]} is running (pgrep exit ${pgrep_status})." >&2
                return 2
            fi
        fi
    done
    printf '%s' "${running}"
    return 0
}

require_apps_quit() {
    local phase="$1"
    local running
    if running="$(find_running_roles)"; then
        :
    else
        echo "Could not verify MacRemoteApp process status before ${phase}; cleanup stopped." >&2
        return 1
    fi
    if [[ -n "${running}" ]]; then
        printf 'MacRemoteApp %s is running; cleanup stopped before %s. Quit both roles and retry.\n' \
            "${running}" "${phase}" >&2
        return 1
    fi
    return 0
}

for applications_root in "${USER_APPLICATIONS}" "${SYSTEM_APPLICATIONS}"; do
    if ! path_is_safe "${applications_root}"; then
        echo "Refusing a symlinked or unsafe Applications path: ${applications_root}" >&2
        exit 1
    fi
    if [[ -e "${applications_root}" && ! -d "${applications_root}" ]]; then
        echo "Refusing a non-directory Applications path: ${applications_root}" >&2
        exit 1
    fi
    [[ -d "${applications_root}" ]] || continue

    for role_index in 0 1; do
        app_path="${applications_root}/${APP_NAMES[role_index]}.app"
        if [[ -e "${app_path}" || -L "${app_path}" ]]; then
            validate_bundle "${app_path}" "${APP_NAMES[role_index]}" "${BUNDLE_IDS[role_index]}" || exit 1
            cleanup_supported=0
            if bundle_supports_cleanup_cli "${app_path}"; then
                cleanup_supported=1
            else
                UNSUPPORTED_APP_COUNT=$((UNSUPPORTED_APP_COUNT + 1))
            fi
            APP_PATHS+=("${app_path}")
            APP_ROLE_INDICES+=("${role_index}")
            APP_CLEANUP_SUPPORTED+=("${cleanup_supported}")
            if (( cleanup_supported )) && [[ -z "${HELPER_BINARIES[role_index]}" ]]; then
                HELPER_BUNDLES[role_index]="${app_path}"
                HELPER_BINARIES[role_index]="${app_path}/Contents/MacOS/${APP_NAMES[role_index]}"
            fi
            echo "Verified ${ROLE_NAMES[role_index]} app: ${app_path}"
        fi
    done
done

add_role_data_paths "${HOST_BUNDLE_ID}" "${HOST_NAME}" "Host"
add_role_data_paths "${VIEWER_BUNDLE_ID}" "${VIEWER_NAME}" "Viewer"
for data_path in "${DATA_PATHS[@]}"; do
    if ! path_is_safe "${data_path}"; then
        echo "Refusing an unsafe or symlinked app-data path: ${data_path}" >&2
        exit 1
    fi
done

if ! path_is_safe "${TRASH_DIR}" ||
   { [[ -e "${TRASH_DIR}" ]] && { [[ ! -d "${TRASH_DIR}" ]] || [[ ! -O "${TRASH_DIR}" ]]; }; }; then
    echo "Refusing an unsafe, non-directory, or non-user-owned Trash path: ${TRASH_DIR}" >&2
    exit 1
fi

if running_roles="$(find_running_roles)"; then
    :
else
    echo "Could not verify whether MacRemoteApp is running; no cleanup was started." >&2
    exit 1
fi

if [[ "${mode}" == "dry-run" ]]; then
    echo "Dry run only: no app, Keychain, user data, Trash, or privacy setting was changed."
    for role_index in 0 1; do
        if [[ -n "${HELPER_BINARIES[role_index]}" ]]; then
            echo "Would ask the verified ${ROLE_NAMES[role_index]} app to clear its role-owned Keychain data."
        else
            echo "Keychain state for ${ROLE_NAMES[role_index]} cannot be verified: no signed app helper is installed."
        fi
    done
    for app_path in "${APP_PATHS[@]}"; do
        [[ -n "${app_path}" ]] || continue
        echo "Would move to your Trash if writable: ${app_path}"
    done
    for data_path in "${DATA_PATHS[@]}"; do
        if [[ -e "${data_path}" ]]; then
            echo "Would remove app data: ${data_path}"
        fi
    done
    echo "Would run tccutil reset All for ${HOST_BUNDLE_ID} and ${VIEWER_BUNDLE_ID}."
    if [[ -n "${running_roles}" ]]; then
        printf 'Quit these apps before cleanup: %s\n' "${running_roles}"
    fi
    echo "Local Network entries require manual review in System Settings; older shared Keychain records are preserved."
    exit 0
fi

if [[ -n "${running_roles}" ]]; then
    printf 'Quit MacRemoteApp %s and run this helper again. It will not stop or force-quit apps.\n' \
        "${running_roles}" >&2
    exit 1
fi

/bin/cat <<EOF

This will clear current-user MacRemoteApp settings and role-owned Keychain data,
reset TCC only for the Host and Viewer bundle IDs, and move verified apps to
your Trash where permitted. You may need to grant permissions again later.

Local Network entries require manual review in System Settings. Older shared
Keychain records are preserved. An unavailable signed app helper means that
role's Keychain cleanup cannot be verified and the final result will be partial.
EOF
read -r -p 'Type UNINSTALL to continue: ' confirmation || confirmation=""
if [[ "${confirmation}" != "UNINSTALL" ]]; then
    echo "Cancelled. Nothing was removed."
    exit 0
fi

if ! require_apps_quit "starting cleanup after confirmation"; then
    echo "MacRemoteApp cleanup was not started." >&2
    exit 1
fi

if (( UNSUPPORTED_APP_COUNT > 0 )); then
    INCOMPLETE=1
fi

MUTATIONS_ABORTED=0
for role_index in 0 1; do
    if ! require_apps_quit "clearing ${ROLE_NAMES[role_index]} Keychain data"; then
        INCOMPLETE=1
        MUTATIONS_ABORTED=1
        break
    fi
    if [[ -z "${HELPER_BINARIES[role_index]}" ]]; then
        echo "Keychain cleanup for ${ROLE_NAMES[role_index]} is unverified: no signed build ${CLEANUP_MINIMUM_BUILD}+ helper is installed." >&2
        INCOMPLETE=1
        continue
    fi
    if ! validate_bundle "${HELPER_BUNDLES[role_index]}" "${APP_NAMES[role_index]}" "${BUNDLE_IDS[role_index]}"; then
        echo "Keychain cleanup for ${ROLE_NAMES[role_index]} was not attempted; the app changed after preflight." >&2
        INCOMPLETE=1
        continue
    fi
    if ! bundle_supports_cleanup_cli "${HELPER_BUNDLES[role_index]}"; then
        echo "Keychain cleanup for ${ROLE_NAMES[role_index]} was not attempted; the app build is unsupported." >&2
        INCOMPLETE=1
        continue
    fi
    if "${HELPER_BINARIES[role_index]}" --remove-all-data; then
        ROLE_KEYCHAIN_OK[role_index]=1
        echo "Signed ${ROLE_NAMES[role_index]} helper reported role-owned Keychain cleanup complete."
    else
        echo "${ROLE_NAMES[role_index]} Keychain cleanup failed; its app bundle will be retained." >&2
        INCOMPLETE=1
    fi
done

if (( !MUTATIONS_ABORTED )); then
    for data_path in "${DATA_PATHS[@]}"; do
        if [[ -e "${data_path}" || -L "${data_path}" ]]; then
            if ! path_is_safe "${data_path}"; then
                echo "Refusing an app-data path that changed or became a symlink: ${data_path}" >&2
                INCOMPLETE=1
            elif ! require_apps_quit "removing current-user app data"; then
                INCOMPLETE=1
                MUTATIONS_ABORTED=1
                break
            elif [[ -d "${data_path}" ]]; then
                if "${RM_TOOL}" -rf -- "${data_path}"; then
                    echo "Removed app data: ${data_path}"
                else
                    echo "Could not remove app data: ${data_path}" >&2
                    INCOMPLETE=1
                fi
            elif "${RM_TOOL}" -f -- "${data_path}"; then
                echo "Removed app data: ${data_path}"
            else
                echo "Could not remove app data: ${data_path}" >&2
                INCOMPLETE=1
            fi
        fi
    done
fi

if (( !MUTATIONS_ABORTED )); then
    for bundle_id in "${HOST_BUNDLE_ID}" "${VIEWER_BUNDLE_ID}"; do
        if ! require_apps_quit "resetting scoped TCC for ${bundle_id}"; then
            INCOMPLETE=1
            MUTATIONS_ABORTED=1
            break
        fi
        if "${TCCUTIL_TOOL}" reset All "${bundle_id}"; then
            echo "Reset TCC decisions for ${bundle_id}."
        else
            echo "TCC reset failed for ${bundle_id}." >&2
            INCOMPLETE=1
        fi
    done
fi

need_trash=0
for path_index in "${!APP_PATHS[@]}"; do
    [[ -n "${APP_PATHS[path_index]}" ]] || continue
    (( APP_CLEANUP_SUPPORTED[path_index] )) || continue
    role_index="${APP_ROLE_INDICES[path_index]}"
    if (( ROLE_KEYCHAIN_OK[role_index] )); then
        need_trash=1
    fi
done
trash_ready=0
if (( need_trash && !MUTATIONS_ABORTED )); then
    if ! require_apps_quit "preparing your Trash for app removal"; then
        INCOMPLETE=1
        MUTATIONS_ABORTED=1
    fi
    trash_ready=1
    if (( !MUTATIONS_ABORTED )) && [[ ! -d "${TRASH_DIR}" ]]; then
        if ! path_is_safe "${TRASH_DIR}" || ! "${MKDIR_TOOL}" -m 700 -- "${TRASH_DIR}"; then
            echo "Could not prepare your Trash; app bundles will be retained." >&2
            trash_ready=0
            INCOMPLETE=1
        fi
    fi
    if (( trash_ready )) &&
       { ! path_is_safe "${TRASH_DIR}" || [[ ! -d "${TRASH_DIR}" ]] || [[ ! -O "${TRASH_DIR}" ]]; }; then
        echo "Your Trash became unsafe or is not owned by this user; app bundles will be retained." >&2
        trash_ready=0
        INCOMPLETE=1
    fi
fi

if (( trash_ready && !MUTATIONS_ABORTED )); then
    for path_index in "${!APP_PATHS[@]}"; do
        app_path="${APP_PATHS[path_index]}"
        [[ -n "${app_path}" ]] || continue
        role_index="${APP_ROLE_INDICES[path_index]}"
        if (( !APP_CLEANUP_SUPPORTED[path_index] )); then
            echo "Retained ${app_path}; its signed build is below the supported cleanup CLI minimum ${CLEANUP_MINIMUM_BUILD}." >&2
            INCOMPLETE=1
            continue
        fi
        if (( ! ROLE_KEYCHAIN_OK[role_index] )); then
            echo "Retained ${app_path} because ${ROLE_NAMES[role_index]} Keychain cleanup did not succeed." >&2
            continue
        fi
        if ! validate_bundle "${app_path}" "${APP_NAMES[role_index]}" "${BUNDLE_IDS[role_index]}"; then
            echo "Retained an app that changed during cleanup: ${app_path}" >&2
            INCOMPLETE=1
            continue
        fi
        if ! bundle_supports_cleanup_cli "${app_path}"; then
            echo "Retained ${app_path}; the cleanup CLI build is unsupported." >&2
            INCOMPLETE=1
            continue
        fi
        if [[ "${app_path}" == "${SYSTEM_APPLICATIONS}/"* && ! -w "${SYSTEM_APPLICATIONS}" ]]; then
            echo "Retained ${app_path}; remove this /Applications copy manually in Finder." >&2
            INCOMPLETE=1
            continue
        fi

        trash_path="${TRASH_DIR}/${APP_NAMES[role_index]}.app"
        suffix=1
        while [[ -e "${trash_path}" || -L "${trash_path}" ]]; do
            trash_path="${TRASH_DIR}/${APP_NAMES[role_index]}-${suffix}.app"
            ((suffix += 1))
        done
        if ! require_apps_quit "moving ${ROLE_NAMES[role_index]} to your Trash"; then
            INCOMPLETE=1
            MUTATIONS_ABORTED=1
            break
        fi
        if ! path_is_safe "${trash_path}" || ! path_is_safe "${app_path}" ||
           ! "${MV_TOOL}" -- "${app_path}" "${trash_path}"; then
            echo "Could not move ${app_path} to your Trash; remove it manually in Finder." >&2
            INCOMPLETE=1
        else
            echo "Moved ${app_path} to your Trash."
        fi
    done
fi

/bin/cat <<'EOF'

Local Network cleanup is manual: open System Settings > Privacy & Security >
Local Network and switch off any remaining MacRemoteApp entries. macOS provides
no supported script operation to remove a historical entry or return this
permission to its undetermined state. Older shared Keychain records were left
untouched.
EOF

if (( INCOMPLETE )); then
    echo "MacRemoteApp cleanup is PARTIAL. Review the messages above and finish the listed steps manually." >&2
    exit 1
fi
echo "MacRemoteApp cleanup completed for the verified apps, current-user data, and scoped TCC decisions."
