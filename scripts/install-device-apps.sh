#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
package_release_root="${repo_root}/build/testing"
notarized_release_root="${repo_root}/build/release"

usage() {
    cat <<'EOF'
Usage: bash scripts/install-device-apps.sh [options]

Install the signed Host and/or Viewer app bundle into ~/Applications by
default. When this script is copied into a role-specific DMG command file,
the role and source directory are inferred from that file's location.

Options:
  --role host|viewer|both       Install one role or both (default: inferred/both)
  --source DIRECTORY            Directory containing MacRemoteApp-*.app bundles
  --destination DIRECTORY       Destination application directory
  --replace                     Replace an existing exact app bundle path
  --require-developer-id        Require Developer ID and Gatekeeper approval (default)
  --allow-ad-hoc                Allow ad-hoc local testing artifacts explicitly
  --help                        Show this help
EOF
}

infer_role() {
    case "$(basename -- "$0")" in
        *Host*) printf '%s\n' host ;;
        *Viewer*) printf '%s\n' viewer ;;
        *) printf '%s\n' both ;;
    esac
}

parse_args() {
    role="$(infer_role)"
    source_root="${MACREMOTEAPP_RELEASE_ROOT:-}"
    destination="${MACREMOTEAPP_INSTALL_DIR:-${HOME:?}/Applications}"
    replace_existing=0
    require_developer_id=1

    while (( $# > 0 )); do
        case "$1" in
            --role)
                [[ $# -ge 2 ]] || { echo "--role requires host, viewer, or both" >&2; exit 2; }
                role="$2"
                shift 2
                ;;
            --source)
                [[ $# -ge 2 ]] || { echo "--source requires a directory" >&2; exit 2; }
                source_root="$2"
                shift 2
                ;;
            --destination)
                [[ $# -ge 2 ]] || { echo "--destination requires a directory" >&2; exit 2; }
                destination="$2"
                shift 2
                ;;
            --replace)
                replace_existing=1
                shift
                ;;
            --require-developer-id)
                require_developer_id=1
                shift
                ;;
            --allow-ad-hoc)
                require_developer_id=0
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 2
                ;;
        esac
    done
}

normalize_destination() {
    [[ -n "${destination}" && "${destination}" != "/" ]] || {
        echo "Refusing to install into an empty or root destination." >&2
        exit 2
    }
    mkdir -p -- "${destination}"
    destination="$(cd -P -- "${destination}" && pwd)"
}

main() {
parse_args "$@"

case "${role}" in
    host)
        app_names=(MacRemoteApp-Host)
        ;;
    viewer)
        app_names=(MacRemoteApp-Viewer)
        ;;
    both)
        app_names=(MacRemoteApp-Host MacRemoteApp-Viewer)
        ;;
    *)
        echo "Invalid role: ${role}" >&2
        exit 2
        ;;
esac

has_selected_apps() {
    local root="$1"
    local app_name
    for app_name in "${app_names[@]}"; do
        [[ -d "${root}/${app_name}.app" && ! -L "${root}/${app_name}.app" ]] || return 1
    done
}

if [[ -z "${source_root}" ]]; then
    if has_selected_apps "${script_dir}"; then
        source_root="${script_dir}"
    elif has_selected_apps "${notarized_release_root}"; then
        # Prefer the notarized channel whenever it has the requested role. An
        # empty or stale testing directory must not shadow a completed release.
        source_root="${notarized_release_root}"
    elif has_selected_apps "${package_release_root}"; then
        source_root="${package_release_root}"
    else
        # Keep the error below useful when neither channel has a complete
        # bundle; it will name the normal package output location.
        if [[ -d "${package_release_root}" ]]; then
            source_root="${package_release_root}"
        else
            source_root="${notarized_release_root}"
        fi
    fi
fi

[[ -d "${source_root}" ]] || {
    echo "Release source directory not found: ${source_root}" >&2
    echo "Run scripts/package-device-apps.sh first or pass --source." >&2
    exit 1
}
source_root="$(cd -P -- "${source_root}" && pwd)"
normalize_destination
if [[ "${source_root}" == "${destination}" ]]; then
    echo "Source and destination must be different directories." >&2
    exit 2
fi

verify_app() {
    local app_name="$1"
    local app_path="$2"
    local binary_path="${app_path}/Contents/MacOS/${app_name}"
    local expected_bundle_identifier
    local bundle_identifier
    local bundle_executable

    [[ -d "${app_path}" && ! -L "${app_path}" ]] || {
        echo "App bundle not found: ${app_path}" >&2
        return 1
    }
    case "${app_name}" in
        MacRemoteApp-Host)
            expected_bundle_identifier="com.rudinyu.MacRemoteApp.Host"
            ;;
        MacRemoteApp-Viewer)
            expected_bundle_identifier="com.rudinyu.MacRemoteApp.Viewer"
            ;;
        *)
            echo "Unsupported MacRemoteApp role: ${app_name}" >&2
            return 2
            ;;
    esac
    if ! bundle_identifier="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' \
        "${app_path}/Contents/Info.plist" 2>/dev/null)"; then
        echo "App bundle metadata is unreadable: ${app_path}" >&2
        return 1
    fi
    if [[ "${bundle_identifier}" != "${expected_bundle_identifier}" ]]; then
        echo "Unexpected bundle identifier for ${app_name}: ${bundle_identifier}" >&2
        return 1
    fi
    if ! bundle_executable="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleExecutable' \
        "${app_path}/Contents/Info.plist" 2>/dev/null)"; then
        echo "App executable metadata is unreadable: ${app_path}" >&2
        return 1
    fi
    if [[ "${bundle_executable}" != "${app_name}" ]]; then
        echo "Unexpected bundle executable for ${app_name}: ${bundle_executable}" >&2
        return 1
    fi
    [[ -x "${binary_path}" ]] || {
        echo "App executable not found: ${binary_path}" >&2
        return 1
    }
    codesign --verify --deep --strict "${app_path}"
    if (( require_developer_id )); then
        local signature_info
        signature_info="$(codesign --display --verbose=4 "${app_path}" 2>&1)"
        if ! printf '%s\n' "${signature_info}" | grep -Eq 'Authority=Developer ID Application:'; then
            echo "A Developer ID Application signature is required: ${app_path}" >&2
            return 1
        fi
        if ! printf '%s\n' "${signature_info}" | grep -Eq 'flags=.*runtime'; then
            echo "A hardened-runtime Developer ID signature is required: ${app_path}" >&2
            return 1
        fi
        if ! spctl --assess --type exec --verbose=4 "${app_path}" >/dev/null 2>&1; then
            echo "Gatekeeper rejected the app bundle: ${app_path}" >&2
            return 1
        fi
    fi
}

recover_interrupted_install() {
    local app_name="$1"
    local destination_app="$2"
    local backup_candidates=()
    local staging_candidate
    local candidate

    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] && backup_candidates+=("${candidate}")
    done < <(find "${destination}" -mindepth 1 -maxdepth 1 -type d \
        -name ".${app_name}.backup.*" -print)

    if (( ${#backup_candidates[@]} > 1 )); then
        echo "Multiple interrupted backups need manual recovery for ${app_name}:" >&2
        printf '  %s\n' "${backup_candidates[@]}" >&2
        return 1
    fi
    if (( ${#backup_candidates[@]} == 1 )); then
        local backup_app="${backup_candidates[0]}/${app_name}.app"
        if [[ ! -d "${backup_app}" || -L "${backup_app}" ]]; then
            echo "Refusing to recover an invalid interrupted-install backup: ${backup_app}" >&2
            return 1
        fi
        if [[ -L "${destination_app}" ]]; then
            echo "Refusing to recover over symlink: ${destination_app}" >&2
            return 1
        elif [[ ! -e "${destination_app}" ]]; then
            if ! verify_app "${app_name}" "${backup_app}"; then
                echo "Refusing to recover an interrupted-install backup that did not pass app validation: ${backup_app}" >&2
                return 1
            fi
            mv -- "${backup_app}" "${destination_app}"
            rmdir -- "${backup_candidates[0]}"
            echo "Recovered the previous ${app_name} after an interrupted install."
        else
            # The replacement reached its destination before cleanup was
            # interrupted. Delete the old backup only when the current app is
            # still a complete, verifiable installation. A partial destination
            # may be the result of a failed rollback, so retain the known-good
            # backup and require manual recovery instead of discarding it.
            if verify_app "${app_name}" "${destination_app}"; then
                rm -rf -- "${backup_candidates[0]}"
            else
                echo "Existing ${app_name} is not verifiable; retaining interrupted-install backup ${backup_candidates[0]}" >&2
                return 1
            fi
        fi
    fi

    # A staging directory contains only a disposable copy. Remove abandoned
    # copies after the backup decision above; never use a broad destination
    # glob for cleanup.
    while IFS= read -r staging_candidate; do
        [[ -n "${staging_candidate}" ]] || continue
        rm -rf -- "${staging_candidate}"
    done < <(find "${destination}" -mindepth 1 -maxdepth 1 -type d \
        -name ".${app_name}.install.*" -print)
}

install_one() {
    local app_name="$1"
    local source_app="${source_root}/${app_name}.app"
    local destination_app="${destination}/${app_name}.app"
    local staging_dir
    local backup_dir=""
    local staged_app

    recover_interrupted_install "${app_name}" "${destination_app}"
    verify_app "${app_name}" "${source_app}"

    if [[ -e "${destination_app}" || -L "${destination_app}" ]]; then
        if [[ -L "${destination_app}" ]]; then
            echo "Refusing to replace symlink: ${destination_app}" >&2
            return 1
        fi
        if (( ! replace_existing )); then
            if [[ -t 0 ]]; then
                local answer
                read -r -p "Replace ${destination_app}? [y/N] " answer
                if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
                    echo "Skipped ${app_name}."
                    return 0
                fi
            else
                echo "App already exists: ${destination_app}; rerun with --replace." >&2
                return 2
            fi
        fi
    fi

    staging_dir="$(mktemp -d "${destination}/.${app_name}.install.XXXXXX")"
    staged_app="${staging_dir}/${app_name}.app"
    if ! ditto -- "${source_app}" "${staging_dir}/${app_name}.app"; then
        rm -rf -- "${staging_dir}"
        return 1
    fi
    if ! codesign --verify --deep --strict "${staged_app}"; then
        rm -rf -- "${staging_dir}"
        return 1
    fi

    if [[ -e "${destination_app}" ]]; then
        backup_dir="$(mktemp -d "${destination}/.${app_name}.backup.XXXXXX")"
        if ! mv -- "${destination_app}" "${backup_dir}/${app_name}.app"; then
            rm -rf -- "${staging_dir}" "${backup_dir}"
            return 1
        fi
    fi

    if ! mv -- "${staged_app}" "${destination_app}"; then
        rm -rf -- "${staging_dir}"
        if [[ -n "${backup_dir}" ]]; then
            if ! mv -- "${backup_dir}/${app_name}.app" "${destination_app}"; then
                echo "Installation failed and the previous app could not be restored: ${destination_app}" >&2
                echo "The previous app remains in: ${backup_dir}/${app_name}.app" >&2
                return 1
            fi
            rmdir -- "${backup_dir}" || true
        fi
        return 1
    fi
    if ! verify_app "${app_name}" "${destination_app}"; then
        rm -rf -- "${destination_app}"
        if [[ -n "${backup_dir}" ]]; then
            if ! mv -- "${backup_dir}/${app_name}.app" "${destination_app}"; then
                echo "Installation validation failed and the previous app could not be restored: ${destination_app}" >&2
                echo "The previous app remains in: ${backup_dir}/${app_name}.app" >&2
                return 1
            fi
            rmdir -- "${backup_dir}" || true
        fi
        echo "Installation aborted because the installed app did not pass signature validation." >&2
        return 1
    fi
    rmdir -- "${staging_dir}" || true
    if [[ -n "${backup_dir}" ]]; then
        if ! rm -rf -- "${backup_dir}"; then
            echo "Warning: the previous app backup was retained at ${backup_dir}" >&2
        fi
    fi
    echo "Installed ${destination_app}"
}

for app_name in "${app_names[@]}"; do
    install_one "${app_name}"
done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    parse_args "$@"
    normalize_destination

    install_lock="${destination}/.MacRemoteApp.install.lock"
    if [[ -L "${install_lock}" || ( -e "${install_lock}" && ! -f "${install_lock}" ) ]]; then
        echo "Refusing an unexpected install lock type: ${install_lock}" >&2
        exit 2
    fi
    command -v lockf >/dev/null 2>&1 || {
        echo "The macOS lockf utility is required for the install lock." >&2
        exit 2
    }
    install_script="${script_dir}/$(basename -- "${BASH_SOURCE[0]}")"
    worker_invocation="${0}-locked-worker"
    if lockf -t 0 "${install_lock}" bash -c '
        set -euo pipefail
        worker_script="$1"
        shift
        source "${worker_script}"
        main "$@"
    ' "${worker_invocation}" "${install_script}" "$@"
    then
        exit 0
    else
        lock_status=$?
        if (( lock_status == 75 )); then
            echo "Another MacRemoteApp installer is already running for this destination: ${destination}" >&2
        fi
        exit "${lock_status}"
    fi
fi
