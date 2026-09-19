#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash scripts/uninstall-device-apps.sh [options]

Remove the exact MacRemoteApp Host and/or Viewer app bundle from
~/Applications by default. Keychain trust records and macOS permissions are
not removed by this script.

Options:
  --role host|viewer|both       Remove one role or both (default: inferred/both)
  --destination DIRECTORY       Application directory to inspect
  --yes                         Skip the confirmation prompt
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
destination="${MACREMOTEAPP_INSTALL_DIR:-${HOME:?}/Applications}"
confirm=0

while (( $# > 0 )); do
    case "$1" in
        --role)
            [[ $# -ge 2 ]] || { echo "--role requires host, viewer, or both" >&2; exit 2; }
            role="$2"
            shift 2
            ;;
        --destination)
            [[ $# -ge 2 ]] || { echo "--destination requires a directory" >&2; exit 2; }
            destination="$2"
            shift 2
            ;;
        --yes)
            confirm=1
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

[[ -n "${destination}" && "${destination}" != "/" ]] || {
    echo "Refusing an empty or root destination." >&2
    exit 2
}

if [[ ! -d "${destination}" ]]; then
    echo "No application directory found: ${destination}"
    exit 0
fi
destination="$(cd -P -- "${destination}" && pwd)"

targets=()
for app_name in "${app_names[@]}"; do
    app_path="${destination}/${app_name}.app"
    if [[ -L "${app_path}" ]]; then
        echo "Refusing to remove symlink: ${app_path}" >&2
        exit 1
    fi
    if [[ -d "${app_path}" ]]; then
        targets+=("${app_path}")
    fi
done

if (( ${#targets[@]} == 0 )); then
    echo "No selected MacRemoteApp bundles found in ${destination}."
    exit 0
fi

if (( ! confirm )); then
    if [[ -t 0 ]]; then
        printf 'Remove the following app bundle(s)? [y/N]\n'
        printf '  %s\n' "${targets[@]}"
        read -r -p 'Confirm removal: ' answer
        if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
            echo "Nothing removed."
            exit 0
        fi
    else
        echo "Refusing non-interactive removal without --yes:" >&2
        printf '  %s\n' "${targets[@]}" >&2
        exit 2
    fi
fi

for app_path in "${targets[@]}"; do
    rm -rf -- "${app_path}"
    echo "Removed ${app_path}"
done
