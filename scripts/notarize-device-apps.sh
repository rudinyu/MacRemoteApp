#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
default_release_root="$(cd -- "${repo_root}/.." && pwd -P)/MacRemoteApp-Release"
release_root="${MACREMOTEAPP_RELEASE_ROOT:-${default_release_root}}"
release_build_root="${MACREMOTEAPP_RELEASE_BUILD_ROOT:-${repo_root}/.build/notarized-release-build}"
signing_identity="${MACREMOTEAPP_SIGNING_IDENTITY:-}"
notary_profile="${MACREMOTEAPP_NOTARY_PROFILE:-notarytool-profile}"

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
if [[ -d "${release_root}" && -n "$(find "${release_root}" -mindepth 1 -print -quit)" ]]; then
    echo "MACREMOTEAPP_RELEASE_ROOT must be absent or empty for the low-level notarization step; use scripts/release-notarized.sh for replacement-safe releases." >&2
    exit 2
fi

if [[ -z "${signing_identity}" || "${signing_identity}" == "-" ]]; then
    echo "Set MACREMOTEAPP_SIGNING_IDENTITY to a Developer ID Application identity." >&2
    exit 2
fi
if [[ -z "${notary_profile}" ]]; then
    echo "MACREMOTEAPP_NOTARY_PROFILE must name an existing Keychain profile." >&2
    exit 2
fi

cd "${repo_root}"

echo "Building and signing release apps with Developer ID"
MACREMOTEAPP_RELEASE_BUILD_ROOT="${release_build_root}" \
MACREMOTEAPP_RELEASE_ROOT="${release_root}" \
MACREMOTEAPP_SIGNING_IDENTITY="${signing_identity}" \
    bash "${script_dir}/package-device-apps.sh"

notarized_zip_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/macremoteapp-notarized.XXXXXX")"
trap 'rm -rf -- "${notarized_zip_dir}"' EXIT

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    app_path="${release_root}/${app_name}.app"
    app_zip="${release_root}/${app_name}.app.zip"
    test -d "${app_path}"
    test -s "${app_zip}"

    signature_info="$(codesign --display --verbose=4 "${app_path}" 2>&1)"
    if ! printf '%s\n' "${signature_info}" | rg -q 'Authority=Developer ID Application:'; then
        echo "Notarization requires a Developer ID Application signature: ${app_name}" >&2
        exit 1
    fi
    if ! printf '%s\n' "${signature_info}" | rg -q 'flags=.*runtime'; then
        echo "Notarization requires the hardened runtime: ${app_name}" >&2
        exit 1
    fi

    echo "Submitting ${app_name} with Keychain profile ${notary_profile}"
    xcrun notarytool submit \
        "${app_zip}" \
        --keychain-profile "${notary_profile}" \
        --wait

    echo "Stapling and validating ${app_name}"
    xcrun stapler staple "${app_path}"
    xcrun stapler validate "${app_path}"
    spctl --assess --type exec --verbose=4 "${app_path}"

    # Rebuild the distributable archive after stapling so the shipped zip
    # contains the notarization ticket. The temporary archive stays outside
    # the repository's tracked source files.
    notarized_zip="${notarized_zip_dir}/${app_name}.app.zip"
    ditto -c -k --keepParent "${app_path}" "${notarized_zip}"
    mv -f -- "${notarized_zip}" "${app_zip}"
done

# Rebuild the disk images after the nested app tickets have been stapled, then
# notarize and staple each distributable DMG as its own release artifact.
MACREMOTEAPP_SIGNING_IDENTITY="${signing_identity}" \
    bash "${script_dir}/create-device-dmgs.sh" "${release_root}"

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    dmg_path="${release_root}/${app_name}.dmg"
    test -s "${dmg_path}"

    signature_info="$(codesign --display --verbose=4 "${dmg_path}" 2>&1)"
    if ! printf '%s\n' "${signature_info}" | rg -q 'Authority=Developer ID Application:'; then
        echo "Notarization requires a Developer ID Application signature: ${dmg_path}" >&2
        exit 1
    fi

    echo "Submitting ${app_name}.dmg with Keychain profile ${notary_profile}"
    xcrun notarytool submit \
        "${dmg_path}" \
        --keychain-profile "${notary_profile}" \
        --wait

    echo "Stapling and validating ${app_name}.dmg"
    xcrun stapler staple "${dmg_path}"
    xcrun stapler validate "${dmg_path}"
    spctl --assess --type install --verbose=4 "${dmg_path}"
done

bash "${script_dir}/validate-notarized-release.sh" "${release_root}"
echo "Developer ID notarization and staple validation passed for apps and DMGs"
echo "Release artifacts: ${release_root}"
