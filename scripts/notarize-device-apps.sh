#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
release_root="${repo_root}/.build/device-binaries/release"
signing_identity="${MACREMOTEAPP_SIGNING_IDENTITY:-}"
notary_profile="${MACREMOTEAPP_NOTARY_PROFILE:-notarytool-profile}"

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

bash "${script_dir}/audit-release.sh" "${release_root}"
echo "Developer ID notarization and staple validation passed"
echo "Release artifacts: ${release_root}"
