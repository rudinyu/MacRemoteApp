#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
if (( $# > 1 )); then
    echo "Usage: bash scripts/release-notarized.sh [beta|rc|release]" >&2
    exit 2
fi

artifact_channel="${1:-release}"
case "${artifact_channel}" in
    beta|rc|release)
        ;;
    *)
        echo "Invalid artifact channel: ${artifact_channel}; expected beta, rc, or release" >&2
        exit 2
        ;;
esac

artifact_root="${repo_root}/build"
if [[ -L "${artifact_root}" || ( -e "${artifact_root}" && ! -d "${artifact_root}" ) ]]; then
    echo "Refusing to use a non-directory or symlink artifact root: ${artifact_root}" >&2
    exit 2
fi
mkdir -p -- "${artifact_root}"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    original_args=("$@")
    command -v lockf >/dev/null 2>&1 || {
        echo "The macOS lockf utility is required for the release lock." >&2
        exit 2
    }
    release_lock="${artifact_root}/.release.lock"
    if [[ -L "${release_lock}" || ( -e "${release_lock}" && ! -f "${release_lock}" ) ]]; then
        echo "Refusing an unexpected release lock type: ${release_lock}" >&2
        exit 2
    fi
    release_script="${script_dir}/$(basename -- "${BASH_SOURCE[0]}")"
    worker_invocation="${0}-locked-worker"
    if lockf -t 0 "${release_lock}" bash -c '
        set -euo pipefail
        worker_script="$1"
        shift
        source "${worker_script}"
        main "$@"
    ' "${worker_invocation}" "${release_script}" "${original_args[@]}"
    then
        exit 0
    else
        lock_status=$?
        if (( lock_status == 75 )); then
            echo "Another notarized release is already running for this repository: ${release_lock}" >&2
        fi
        exit "${lock_status}"
    fi
fi

main() {
bash "${script_dir}/ensure-local-build-exclude.sh" "${repo_root}"
for channel in testing beta rc release; do
    if [[ "${channel}" != "${artifact_channel}" ]]; then
        mkdir -p -- "${artifact_root}/${channel}"
    fi
done
default_release_root="${repo_root}/build/${artifact_channel}"
release_root="${MACREMOTEAPP_RELEASE_ROOT:-${default_release_root}}"
notary_profile="${MACREMOTEAPP_NOTARY_PROFILE:-notarytool-profile}"
signing_identity="${MACREMOTEAPP_SIGNING_IDENTITY:-}"

if [[ "${release_root}" != /* ]]; then
    release_root="${repo_root}/${release_root}"
fi
if [[ -L "${release_root}" ]]; then
    echo "MACREMOTEAPP_RELEASE_ROOT must not be a symlink: ${release_root}" >&2
    exit 2
fi
if [[ -e "${release_root}" ]]; then
    if [[ ! -d "${release_root}" ]]; then
        echo "MACREMOTEAPP_RELEASE_ROOT must be a directory: ${release_root}" >&2
        exit 2
    fi
    release_root="$(cd -- "${release_root}" && pwd -P)"
else
    release_name="$(basename -- "${release_root}")"
    if [[ "${release_name}" == "." || "${release_name}" == ".." || -z "${release_name}" ]]; then
        echo "MACREMOTEAPP_RELEASE_ROOT must name a dedicated directory: ${release_root}" >&2
        exit 2
    fi
    release_root="$(cd -- "$(dirname -- "${release_root}")" && pwd -P)/${release_name}"
fi
if [[ "${release_root}" =~ ^/+$ ]]; then
    echo "MACREMOTEAPP_RELEASE_ROOT must be a dedicated directory, not the filesystem root" >&2
    exit 2
fi
expected_release_root="${repo_root}/build/${artifact_channel}"
if [[ "${release_root}" != "${expected_release_root}" ]]; then
    echo "MACREMOTEAPP_RELEASE_ROOT must match the selected ${artifact_channel} channel: ${expected_release_root}" >&2
    exit 2
fi
case "${release_root}" in
    /)
        echo "MACREMOTEAPP_RELEASE_ROOT must be a dedicated directory, not /" >&2
        exit 2
        ;;
    "${repo_root}/build/beta"|"${repo_root}/build/rc"|"${repo_root}/build/release")
        ;;
    "${repo_root}"|"${repo_root}"/*)
        echo "MACREMOTEAPP_RELEASE_ROOT must be a repository-local build channel directory: ${release_root}" >&2
        exit 2
        ;;
    *)
        echo "MACREMOTEAPP_RELEASE_ROOT must be one of build/beta, build/rc, or build/release: ${release_root}" >&2
        exit 2
        ;;
esac
case "${repo_root}" in
    "${release_root}"/*)
        echo "MACREMOTEAPP_RELEASE_ROOT must not contain the repository: ${release_root}" >&2
        exit 2
        ;;
esac
if [[ -z "${signing_identity}" || "${signing_identity}" == "-" ]]; then
    echo "Set MACREMOTEAPP_SIGNING_IDENTITY to a Developer ID Application identity." >&2
    exit 2
fi
if [[ -z "${notary_profile}" ]]; then
    echo "MACREMOTEAPP_NOTARY_PROFILE must name an existing Keychain profile." >&2
    exit 2
fi

cd "${repo_root}"

staging_release_root=""
backup_release_root=""
release_parent="$(cd -- "$(dirname -- "${release_root}")" && pwd -P)"
# Keep staging beside the destination. This preserves same-filesystem atomic
# rename semantics even when the checkout itself is on a separate mount.
staging_parent="${release_parent}"

recover_orphaned_promotion() {
    local candidates=()
    local candidate
    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] && candidates+=("${candidate}")
    done < <(find "${staging_parent}" -maxdepth 1 -type d \
        -name "MacRemoteApp-${artifact_channel}.previous.*" -print)

    if (( ${#candidates[@]} > 1 )); then
        echo "Multiple interrupted ${artifact_channel} promotions need manual recovery:" >&2
        printf '  %s\n' "${candidates[@]}" >&2
        exit 2
    fi
    if (( ${#candidates[@]} == 1 )); then
        if [[ ! -e "${release_root}" ]]; then
            mv -- "${candidates[0]}" "${release_root}"
            echo "Recovered the previous ${artifact_channel} artifacts after an interrupted promotion."
        elif [[ -d "${release_root}" && ! -L "${release_root}" ]]; then
            # The new promotion reached its destination before the process
            # died while cleaning up the backup. The current channel is the
            # authoritative result; remove only the exact old backup.
            rm -rf -- "${candidates[0]}"
        else
            echo "Refusing to recover over an unexpected release path: ${release_root}" >&2
            exit 2
        fi
    fi
}

cleanup_on_success() {
    local status=$?
    if (( status != 0 )); then
        if [[ -n "${staging_release_root}" && -e "${staging_release_root}" ]]; then
            rm -rf -- "${staging_release_root}"
        fi
        if [[ -n "${backup_release_root}" && ! -e "${release_root}" && -e "${backup_release_root}" ]]; then
            if mv -- "${backup_release_root}" "${release_root}"; then
                echo "Restored previous ${artifact_channel} artifacts after the failed build."
                backup_release_root=""
            else
                echo "Previous ${artifact_channel} artifacts remain at ${backup_release_root}" >&2
            fi
        fi
    fi
    if (( status == 0 )) && [[ -d "${repo_root}/.build" && ! -L "${repo_root}/.build" ]]; then
        rm -rf -- "${repo_root}/.build"
        echo "Cleared successful notarized-release build cache: ${repo_root}/.build"
    fi
    if (( status == 0 )) && [[ -n "${backup_release_root}" && -e "${backup_release_root}" ]]; then
        rm -rf -- "${backup_release_root}"
        backup_release_root=""
    fi
    exit "${status}"
}
trap cleanup_on_success EXIT
recover_orphaned_promotion
mkdir -p -- "${release_root}"

if [[ -L "${repo_root}/.build" || ( -e "${repo_root}/.build" && ! -d "${repo_root}/.build" ) ]]; then
    echo "Refusing to clean an unexpected .build path: ${repo_root}/.build" >&2
    exit 2
fi
if [[ -e "${repo_root}/.build" ]]; then
    rm -rf -- "${repo_root}/.build"
fi

echo "Running deterministic CI before notarization"
bash "${script_dir}/validate.sh"

if [[ -d "${repo_root}/.build" && ! -L "${repo_root}/.build" ]]; then
    rm -rf -- "${repo_root}/.build"
    echo "Cleared successful validation build cache: ${repo_root}/.build"
fi

staging_release_root="$(mktemp -d "${staging_parent}/MacRemoteApp-${artifact_channel}.staging.XXXXXX")"
echo "Building, notarizing, stapling, and validating ${artifact_channel} test artifacts"
MACREMOTEAPP_RELEASE_ROOT="${staging_release_root}" \
MACREMOTEAPP_RELEASE_BUILD_ROOT="${repo_root}/.build/notarized-release-build" \
MACREMOTEAPP_SIGNING_IDENTITY="${signing_identity}" \
MACREMOTEAPP_NOTARY_PROFILE="${notary_profile}" \
    bash "${script_dir}/notarize-device-apps.sh"

echo "Promoting validated notarized artifacts into ${release_root}"
if [[ -e "${release_root}" ]]; then
    backup_release_root="$(mktemp -d "${staging_parent}/MacRemoteApp-${artifact_channel}.previous.XXXXXX")"
    rmdir -- "${backup_release_root}"
    mv -- "${release_root}" "${backup_release_root}"
fi
if ! mv -- "${staging_release_root}" "${release_root}"; then
    exit 1
fi
staging_release_root=""

echo "Notarized ${artifact_channel} artifacts: ${release_root}"
}
