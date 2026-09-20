#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
package_release_root="${repo_root}/.build/device-binaries/release"
notarized_release_root="$(cd -- "${repo_root}/.." && pwd -P)/MacRemoteApp-Release"

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
  --require-developer-id        Require a Developer ID Application signature
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

role="$(infer_role)"
source_root="${MACREMOTEAPP_RELEASE_ROOT:-}"
destination="${MACREMOTEAPP_INSTALL_DIR:-${HOME:?}/Applications}"
replace_existing=0
require_developer_id=0

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

if [[ -z "${source_root}" ]]; then
    if [[ -d "${script_dir}/MacRemoteApp-Host.app" ||
          -d "${script_dir}/MacRemoteApp-Viewer.app" ]]; then
        source_root="${script_dir}"
    elif [[ -d "${package_release_root}" ]]; then
        # Preserve the package-then-install workflow. The package output is
        # preferred when present so an older external release is not selected
        # accidentally; the notarized directory is the fallback after a
        # successful release flow has cleared .build.
        source_root="${package_release_root}"
    else
        source_root="${notarized_release_root}"
    fi
fi

[[ -d "${source_root}" ]] || {
    echo "Release source directory not found: ${source_root}" >&2
    echo "Run scripts/package-device-apps.sh first or pass --source." >&2
    exit 1
}
source_root="$(cd -P -- "${source_root}" && pwd)"

[[ -n "${destination}" && "${destination}" != "/" ]] || {
    echo "Refusing to install into an empty or root destination." >&2
    exit 2
}
mkdir -p -- "${destination}"
destination="$(cd -P -- "${destination}" && pwd)"
if [[ "${source_root}" == "${destination}" ]]; then
    echo "Source and destination must be different directories." >&2
    exit 2
fi

verify_app() {
    local app_name="$1"
    local app_path="${source_root}/${app_name}.app"
    local binary_path="${app_path}/Contents/MacOS/${app_name}"

    [[ -d "${app_path}" && ! -L "${app_path}" ]] || {
        echo "App bundle not found: ${app_path}" >&2
        return 1
    }
    [[ -x "${binary_path}" ]] || {
        echo "App executable not found: ${binary_path}" >&2
        return 1
    }
    codesign --verify --deep --strict "${app_path}"
    if (( require_developer_id )); then
        local signature_info
        signature_info="$(codesign --display --verbose=4 "${app_path}" 2>&1)"
        if ! printf '%s\n' "${signature_info}" | rg -q 'Authority=Developer ID Application:'; then
            echo "A Developer ID Application signature is required: ${app_path}" >&2
            return 1
        fi
    fi
}

install_one() {
    local app_name="$1"
    local source_app="${source_root}/${app_name}.app"
    local destination_app="${destination}/${app_name}.app"
    local staging_dir

    verify_app "${app_name}"

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
        rm -rf -- "${destination_app}"
    fi

    staging_dir="$(mktemp -d "${destination}/.${app_name}.install.XXXXXX")"
    if ! ditto -- "${source_app}" "${staging_dir}/${app_name}.app"; then
        rm -rf -- "${staging_dir}"
        return 1
    fi
    if ! codesign --verify --deep --strict "${staging_dir}/${app_name}.app"; then
        rm -rf -- "${staging_dir}"
        return 1
    fi
    mv -- "${staging_dir}/${app_name}.app" "${destination_app}"
    rmdir -- "${staging_dir}"
    echo "Installed ${destination_app}"
}

for app_name in "${app_names[@]}"; do
    install_one "${app_name}"
done
