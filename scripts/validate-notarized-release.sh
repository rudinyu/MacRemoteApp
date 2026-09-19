#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
release_root="${1:-${repo_root}/.build/device-binaries/release}"

if (( $# > 1 )); then
    echo "usage: $0 [release-root]" >&2
    exit 2
fi

cd "${repo_root}"
test -d "${release_root}"

bash "${script_dir}/audit-release.sh" "${release_root}"

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    app_path="${release_root}/${app_name}.app"
    signature_info="$(codesign --display --verbose=4 "${app_path}" 2>&1)"
    if ! printf '%s\n' "${signature_info}" | rg -q 'Authority=Developer ID Application:'; then
        echo "Notarized release validation failed: ${app_name} is not Developer ID signed" >&2
        exit 1
    fi
    if ! printf '%s\n' "${signature_info}" | rg -q 'flags=.*runtime'; then
        echo "Notarized release validation failed: ${app_name} lacks the hardened runtime" >&2
        exit 1
    fi

    echo "Validating notarization ticket for ${app_name}.app"
    xcrun stapler validate "${app_path}"
    spctl --assess --type exec --verbose=4 "${app_path}"
done

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    dmg_path="${release_root}/${app_name}.dmg"
    signature_info="$(codesign --display --verbose=4 "${dmg_path}" 2>&1)"
    if ! printf '%s\n' "${signature_info}" | rg -q 'Authority=Developer ID Application:'; then
        echo "Notarized release validation failed: ${app_name}.dmg is not Developer ID signed" >&2
        exit 1
    fi

    echo "Validating notarization ticket for ${app_name}.dmg"
    xcrun stapler validate "${dmg_path}"
    spctl --assess --type install --verbose=4 "${dmg_path}"
done

echo "Notarized release validation passed: ${release_root}"
