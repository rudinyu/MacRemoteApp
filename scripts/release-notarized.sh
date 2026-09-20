#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
default_release_root="$(cd -- "${repo_root}/.." && pwd -P)/MacRemoteApp-Release"
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
case "${release_root}" in
    /)
        echo "MACREMOTEAPP_RELEASE_ROOT must be a dedicated directory, not /" >&2
        exit 2
        ;;
    "${repo_root}"|"${repo_root}"/*)
        echo "MACREMOTEAPP_RELEASE_ROOT must be outside the repository: ${release_root}" >&2
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

cleanup_on_success() {
    local status=$?
    if (( status != 0 )); then
        if [[ -n "${backup_release_root}" && ! -e "${release_root}" && -e "${backup_release_root}" ]]; then
            mv -- "${backup_release_root}" "${release_root}"
        fi
        if [[ -n "${staging_release_root}" && -e "${staging_release_root}" ]]; then
            rm -rf -- "${staging_release_root}"
        fi
    fi
    if (( status == 0 )) && [[ -d "${repo_root}/.build" && ! -L "${repo_root}/.build" ]]; then
        rm -rf -- "${repo_root}/.build"
        echo "Cleared successful notarized-release build cache: ${repo_root}/.build"
    fi
    exit "${status}"
}
trap cleanup_on_success EXIT

echo "Checking local notary profile: ${notary_profile}"
xcrun notarytool history \
    --keychain-profile "${notary_profile}" \
    --output-format json >/dev/null

echo "Running deterministic CI before notarization"
if [[ -x "${repo_root}/.codex/ci.sh" ]]; then
    bash "${repo_root}/.codex/ci.sh"
else
    bash "${script_dir}/validate.sh"
fi

if [[ -d "${repo_root}/.build" && ! -L "${repo_root}/.build" ]]; then
    rm -rf -- "${repo_root}/.build"
    echo "Cleared successful validation build cache: ${repo_root}/.build"
fi

staging_release_root="$(mktemp -d "${release_root}.staging.XXXXXX")"
echo "Building, notarizing, stapling, and validating final test artifacts"
MACREMOTEAPP_RELEASE_ROOT="${staging_release_root}" \
MACREMOTEAPP_RELEASE_BUILD_ROOT="${repo_root}/.build/notarized-release-build" \
MACREMOTEAPP_SIGNING_IDENTITY="${signing_identity}" \
MACREMOTEAPP_NOTARY_PROFILE="${notary_profile}" \
    bash "${script_dir}/notarize-device-apps.sh"

if [[ -e "${release_root}" ]]; then
    backup_release_root="$(mktemp -d "${release_root}.previous.XXXXXX")"
    rmdir "${backup_release_root}"
    mv -- "${release_root}" "${backup_release_root}"
fi
if ! mv -- "${staging_release_root}" "${release_root}"; then
    if [[ -n "${backup_release_root}" && ! -e "${release_root}" ]]; then
        mv -- "${backup_release_root}" "${release_root}"
        backup_release_root=""
    fi
    exit 1
fi
staging_release_root=""
if [[ -n "${backup_release_root}" ]]; then
    rm -rf -- "${backup_release_root}"
    backup_release_root=""
fi

echo "Notarized test artifacts: ${release_root}"
