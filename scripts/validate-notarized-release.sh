#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
release_root="${1:-${repo_root}/build/release}"

if (( $# > 1 )); then
    echo "usage: $0 [release-root]" >&2
    exit 2
fi

cd "${repo_root}"
test -d "${release_root}"

bash "${script_dir}/audit-release.sh" "${release_root}"

validation_tmp_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/macremoteapp-notarized-validation.XXXXXX")"
trap 'rm -rf -- "${validation_tmp_dir}"' EXIT

verify_role_metadata() {
    local app_name="$1"
    local app_path="$2"
    local expected_bundle_identifier
    local bundle_identifier
    local bundle_executable

    case "${app_name}" in
        MacRemoteApp-Host)
            expected_bundle_identifier="com.rudinyu.MacRemoteApp.Host"
            ;;
        MacRemoteApp-Viewer)
            expected_bundle_identifier="com.rudinyu.MacRemoteApp.Viewer"
            ;;
        *)
            echo "Notarized release validation failed: unknown app role ${app_name}" >&2
            return 1
            ;;
    esac
    bundle_identifier="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' \
        "${app_path}/Contents/Info.plist" 2>/dev/null)" || {
        echo "Notarized release validation failed: unreadable bundle metadata for ${app_name}" >&2
        return 1
    }
    bundle_executable="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleExecutable' \
        "${app_path}/Contents/Info.plist" 2>/dev/null)" || {
        echo "Notarized release validation failed: missing CFBundleExecutable for ${app_name}" >&2
        return 1
    }
    if [[ "${bundle_identifier}" != "${expected_bundle_identifier}" ||
          "${bundle_executable}" != "${app_name}" ]]; then
        echo "Notarized release validation failed: role metadata mismatch for ${app_name}" >&2
        return 1
    fi
}

validate_app_archive() {
    local app_name="$1"
    local app_path="${release_root}/${app_name}.app"
    local app_zip="${release_root}/${app_name}.app.zip"
    local extraction_dir="${validation_tmp_dir}/${app_name}"
    local extracted_app="${extraction_dir}/${app_name}.app"
    local extra_entry

    if [[ ! -s "${app_zip}" ]]; then
        echo "Notarized release validation failed: missing app archive ${app_zip}" >&2
        return 1
    fi
    mkdir -p -- "${extraction_dir}"
    if ! ditto -x -k "${app_zip}" "${extraction_dir}"; then
        echo "Notarized release validation failed: unable to extract ${app_zip}" >&2
        return 1
    fi
    if [[ ! -d "${extracted_app}" || -L "${extracted_app}" ]]; then
        echo "Notarized release validation failed: ${app_zip} does not contain ${app_name}.app" >&2
        return 1
    fi
    verify_role_metadata "${app_name}" "${app_path}"
    verify_role_metadata "${app_name}" "${extracted_app}"
    extra_entry="$(find "${extraction_dir}" -mindepth 1 -maxdepth 1 \
        ! -name "${app_name}.app" -print -quit)"
    if [[ -n "${extra_entry}" ]]; then
        echo "Notarized release validation failed: unexpected top-level payload ${extra_entry} in ${app_zip}" >&2
        return 1
    fi
    if ! diff -qr "${app_path}" "${extracted_app}" >/dev/null; then
        echo "Notarized release validation failed: ${app_zip} differs from ${app_path}" >&2
        return 1
    fi
    codesign --verify --deep --strict "${extracted_app}"
    xcrun stapler validate "${extracted_app}"
    spctl --assess --type exec --verbose=4 "${extracted_app}"
}

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    app_path="${release_root}/${app_name}.app"
    validate_app_archive "${app_name}"
    signature_info="$(codesign --display --verbose=4 "${app_path}" 2>&1)"
    if ! printf '%s\n' "${signature_info}" | grep -Eq 'Authority=Developer ID Application:'; then
        echo "Notarized release validation failed: ${app_name} is not Developer ID signed" >&2
        exit 1
    fi
    if ! printf '%s\n' "${signature_info}" | grep -Eq 'flags=.*runtime'; then
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
    if ! printf '%s\n' "${signature_info}" | grep -Eq 'Authority=Developer ID Application:'; then
        echo "Notarized release validation failed: ${app_name}.dmg is not Developer ID signed" >&2
        exit 1
    fi

    echo "Validating notarization ticket for ${app_name}.dmg"
    xcrun stapler validate "${dmg_path}"
    spctl --assess --type install --verbose=4 "${dmg_path}"
done

echo "Notarized release validation passed: ${release_root}"
