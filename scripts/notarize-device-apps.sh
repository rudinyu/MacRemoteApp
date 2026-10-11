#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
source "${script_dir}/notarization-config.sh"
source "${script_dir}/artifact-naming.sh"
if [[ "${MACREMOTEAPP_ARTIFACT_CHANNEL+x}" != "x" ]]; then
    MACREMOTEAPP_ARTIFACT_CHANNEL=testing
    export MACREMOTEAPP_ARTIFACT_CHANNEL
fi
artifact_root="${repo_root}/build"
if [[ -L "${artifact_root}" || ( -e "${artifact_root}" && ! -d "${artifact_root}" ) ]]; then
    echo "Refusing to use a non-directory or symlink artifact root: ${artifact_root}" >&2
    exit 2
fi
default_release_root="${repo_root}/build/MacRemoteApp-notarize.staging.$$"
release_root="${MACREMOTEAPP_RELEASE_ROOT:-${default_release_root}}"
release_build_root="${MACREMOTEAPP_RELEASE_BUILD_ROOT:-${repo_root}/.build/notarized-release-build}"

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
    "${repo_root}/build/beta"|"${repo_root}/build/rc"|"${repo_root}/build/release")
        echo "Refusing to notarize directly into a formal channel; use scripts/release-notarized.sh for the lock-protected promotion: ${release_root}" >&2
        exit 2
        ;;
    "${repo_root}/build/MacRemoteApp-"*.staging.*)
        ;;
    "${repo_root}"|"${repo_root}"/*)
        echo "MACREMOTEAPP_RELEASE_ROOT must be a repository-local build channel or controlled staging directory: ${release_root}" >&2
        exit 2
        ;;
    *)
        echo "MACREMOTEAPP_RELEASE_ROOT must be a repository-local build channel or controlled staging directory: ${release_root}" >&2
        exit 2
        ;;
esac
case "${repo_root}" in
    "${release_root}"/*)
        echo "MACREMOTEAPP_RELEASE_ROOT must not contain the repository: ${release_root}" >&2
        exit 2
        ;;
esac
artifact_channel="$(macremoteapp_resolve_artifact_channel "${repo_root}" "${release_root}")" || exit 2
if [[ -d "${release_root}" && -n "$(find "${release_root}" -mindepth 1 -print -quit)" ]]; then
    echo "MACREMOTEAPP_RELEASE_ROOT must be absent or empty for the low-level notarization step; use scripts/release-notarized.sh for replacement-safe releases." >&2
    exit 2
fi

macremoteapp_notary_resolve "${repo_root}"
signing_identity="$(macremoteapp_resolve_signing_identity -)"
if [[ -z "${signing_identity}" || "${signing_identity}" == "-" ]]; then
    echo "Set MACREMOTEAPP_SIGNING_IDENTITY to a Developer ID Application identity." >&2
    exit 2
fi
bash "${script_dir}/ensure-local-build-exclude.sh" "${repo_root}"
mkdir -p -- "${artifact_root}"
cd "${repo_root}"

echo "Building and signing release apps with Developer ID"
env \
    -u MACOS_NOTARY_PROFILE \
    -u MACOS_NOTARY_KEY_PATH \
    -u MACOS_NOTARY_KEY_ID \
    -u MACOS_NOTARY_ISSUER \
    MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}" \
    MACREMOTEAPP_RELEASE_BUILD_ROOT="${release_build_root}" \
    MACREMOTEAPP_RELEASE_ROOT="${release_root}" \
    MACREMOTEAPP_SIGNING_IDENTITY="${signing_identity}" \
    MACREMOTEAPP_REQUIRE_DEVELOPER_ID=1 \
    bash "${script_dir}/package-device-apps.sh"

release_identity="$(macremoteapp_release_identity \
    "${release_root}/MacRemoteApp-Host.app/Contents/Info.plist" \
    "${release_root}/MacRemoteApp-Viewer.app/Contents/Info.plist")" || exit 2
echo "Product version: ${release_identity}; artifact channel: ${artifact_channel}"

notarized_zip_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/macremoteapp-notarized.XXXXXX")"
trap 'rm -rf -- "${notarized_zip_dir}"' EXIT

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    app_path="${release_root}/${app_name}.app"
    app_zip_name="$(macremoteapp_expected_distribution_name \
        "${artifact_channel}" "${release_identity}" "${app_name}" app-zip)"
    app_zip="${release_root}/${app_zip_name}"
    test -d "${app_path}"
    test -s "${app_zip}"

    signature_info="$(codesign --display --verbose=4 "${app_path}" 2>&1)"
    if ! printf '%s\n' "${signature_info}" | grep -Eq 'Authority=Developer ID Application:'; then
        echo "Notarization requires a Developer ID Application signature: ${app_name}" >&2
        exit 1
    fi
    if ! printf '%s\n' "${signature_info}" | grep -Eq 'flags=.*runtime'; then
        echo "Notarization requires the hardened runtime: ${app_name}" >&2
        exit 1
    fi

    echo "Submitting ${app_zip_name} with resolved notarization authentication."
    macremoteapp_notary_submit "${app_zip}"

    echo "Stapling and verifying ${app_name}"
    macremoteapp_notary_staple "${app_path}"
    macremoteapp_notary_verify "${app_path}"

    # Rebuild the distributable archive after stapling so the shipped zip
    # contains the notarization ticket. The temporary archive stays outside
    # the repository's tracked source files.
    notarized_zip="${notarized_zip_dir}/${app_zip_name}"
    ditto -c -k --keepParent "${app_path}" "${notarized_zip}"
    mv -f -- "${notarized_zip}" "${app_zip}"
done

# Rebuild the disk images after the nested app tickets have been stapled, then
# notarize and staple each distributable DMG as its own release artifact.
env \
    -u MACOS_NOTARY_PROFILE \
    -u MACOS_NOTARY_KEY_PATH \
    -u MACOS_NOTARY_KEY_ID \
    -u MACOS_NOTARY_ISSUER \
    MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}" \
    MACREMOTEAPP_SIGNING_IDENTITY="${signing_identity}" \
    bash "${script_dir}/create-device-dmgs.sh" "${release_root}"

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    dmg_name="$(macremoteapp_expected_distribution_name \
        "${artifact_channel}" "${release_identity}" "${app_name}" dmg)"
    dmg_path="${release_root}/${dmg_name}"
    test -s "${dmg_path}"

    signature_info="$(codesign --display --verbose=4 "${dmg_path}" 2>&1)"
    if ! printf '%s\n' "${signature_info}" | grep -Eq 'Authority=Developer ID Application:'; then
        echo "Notarization requires a Developer ID Application signature: ${dmg_path}" >&2
        exit 1
    fi

    echo "Submitting ${dmg_name} with resolved notarization authentication."
    macremoteapp_notary_submit "${dmg_path}"

    echo "Stapling and verifying ${dmg_name}"
    macremoteapp_notary_staple "${dmg_path}"
    macremoteapp_notary_verify "${dmg_path}"
done

env \
    -u MACOS_NOTARY_PROFILE \
    -u MACOS_NOTARY_KEY_PATH \
    -u MACOS_NOTARY_KEY_ID \
    -u MACOS_NOTARY_ISSUER \
    MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}" \
    bash "${script_dir}/validate-notarized-release.sh" "${release_root}"
echo "Developer ID notarization and staple validation passed for apps and DMGs"
echo "Release artifacts: ${release_root}"
