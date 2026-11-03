#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
test_root="$(mktemp -d "${TMPDIR:-/private/tmp}/macremoteapp-release-license.XXXXXX")"
trap 'rm -rf -- "${test_root}"' EXIT

fail() {
    echo "M9 release license packaging test failed: $*" >&2
    exit 1
}

extract_function() {
    local function_name="$1"
    local source_path="$2"
    local output_path="$3"

    if ! awk -v function_name="${function_name}" '
        $0 == function_name "() {" { inside=1 }
        inside { print }
        inside && /^}$/ { found=1; exit }
        END { if (!found) exit 1 }
    ' "${source_path}" >"${output_path}"; then
        fail "${function_name} is not available for deterministic fixture coverage"
    fi
}

assert_script_contains() {
    local script_path="$1"
    local expected="$2"
    if ! grep -Fq -- "${expected}" "${script_path}"; then
        fail "$(basename -- "${script_path}") is missing expected license handling: ${expected}"
    fi
}

package_function="${test_root}/package-app-function.sh"
extract_function package_app "${script_dir}/package-device-apps.sh" "${package_function}"
source "${package_function}"

repo_root="${test_root}/repository"
release_root="${test_root}/release"
fixture_binary="${test_root}/MacRemoteApp-Test"
fixture_plist="${test_root}/Test-Info.plist"
mkdir -p -- "${repo_root}" "${release_root}"
cp -- "${script_dir}/../LICENSE" "${repo_root}/LICENSE"
printf 'fixture executable\n' >"${fixture_binary}"
printf 'fixture plist\n' >"${fixture_plist}"
printf 'fixture icon\n' >"${release_root}/MacRemoteAppIcon.icns"
package_app MacRemoteApp-Test "${fixture_binary}" "${fixture_plist}"
cmp -s "${repo_root}/LICENSE" \
    "${release_root}/MacRemoteApp-Test.app/Contents/Resources/LICENSE" ||
    fail "package_app did not copy the exact repository LICENSE into the app bundle"
cmp -s "${fixture_binary}" \
    "${release_root}/MacRemoteApp-Test.app/Contents/MacOS/MacRemoteApp-Test" ||
    fail "package_app fixture did not create the executable payload"

license_copy_line="$(grep -n -F 'cp -- "${repo_root}/LICENSE"' "${script_dir}/package-device-apps.sh" | head -1 | cut -d: -f1)"
sign_app_line="$(grep -n -F 'macremoteapp_sign_app "${app_dir}" "${signing_identity}"' "${script_dir}/package-device-apps.sh" | head -1 | cut -d: -f1)"
[[ -n "${license_copy_line}" && -n "${sign_app_line}" && "${license_copy_line}" -lt "${sign_app_line}" ]] ||
    fail "the app LICENSE copy must occur before app signing"

assert_script_contains "${script_dir}/create-device-dmgs.sh" \
    'cp -- "${license_source}" "${staging_dir}/LICENSE"'
license_manifest_count="$(grep -Fc '"${staging_dir}/LICENSE"' "${script_dir}/create-device-dmgs.sh")"
[[ "${license_manifest_count}" == 2 ]] ||
    fail "the DMG LICENSE must be copied and included in the payload manifest"
assert_script_contains "${script_dir}/audit-release.sh" \
    '! -name "LICENSE" \'
assert_script_contains "${script_dir}/audit-release.sh" \
    '        "LICENSE" \'

audit_function="${test_root}/assert-license-copy-function.sh"
extract_function assert_license_copy "${script_dir}/audit-release.sh" "${audit_function}"
source "${audit_function}"
expected_license="${test_root}/expected/LICENSE"
actual_license="${test_root}/payload/LICENSE"
mkdir -p -- "${test_root}/expected" "${test_root}/payload"
cp -- "${repo_root}/LICENSE" "${expected_license}"
cp -- "${repo_root}/LICENSE" "${actual_license}"
assert_license_copy "${expected_license}" "${actual_license}" "matching fixture"

if assert_license_copy \
    "${expected_license}" \
    "${test_root}/payload/missing-LICENSE" \
    "missing fixture" >/dev/null 2>&1
then
    fail "the release audit accepted a missing LICENSE"
fi
printf 'altered license\n' >"${actual_license}"
if assert_license_copy \
    "${expected_license}" \
    "${actual_license}" \
    "altered fixture" >/dev/null 2>&1
then
    fail "the release audit accepted a modified LICENSE"
fi

symlink_license="${test_root}/payload/symlinked-LICENSE"
if ln -s "${expected_license}" "${symlink_license}" 2>/dev/null; then
    if assert_license_copy \
        "${expected_license}" \
        "${symlink_license}" \
        "symlink fixture" >/dev/null 2>&1
    then
        fail "the release audit accepted a symlinked LICENSE"
    fi
    echo "Symlink LICENSE rejection fixture passed"
else
    echo "Symlink LICENSE rejection fixture skipped (symlinks unsupported)"
fi

echo "M9 release license packaging fixtures passed"
