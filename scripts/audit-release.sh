#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
release_root="${1:-${repo_root}/build/testing}"

cd "${repo_root}"
test -d "${release_root}"
audit_tmp_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/macremoteapp-release-audit.XXXXXX")"
trap 'rm -rf -- "${audit_tmp_dir}"' EXIT

verify_dmg_payload() {
    local dmg_path="$1"
    local app_name="$2"
    local mount_point="${audit_tmp_dir}/${app_name}-dmg"
    local role_name="${app_name#MacRemoteApp-}"
    local payload_name
    local manifest_name="MacRemoteApp-${role_name}-payload.sha256"
    local manifest_path="${mount_point}/${manifest_name}"
    local expected_manifest="${audit_tmp_dir}/${app_name}.expected.sha256"
    local extra_entry
    local applications_alias="${mount_point}/Applications"
    local applications_alias_target
    local payload_status=0

    mkdir -p -- "${mount_point}"
    if ! hdiutil attach \
        -readonly \
        -nobrowse \
        -mountpoint "${mount_point}" \
        "${dmg_path}" >/dev/null
    then
        echo "Release audit failed: unable to mount ${dmg_path} read-only" >&2
        return 1
    fi

    extra_entry="$(find "${mount_point}" -mindepth 1 -maxdepth 1 \
        ! -name "${app_name}.app" \
        ! -name "Install-MacRemoteApp-${role_name}.command" \
        ! -name "Uninstall-MacRemoteApp-${role_name}.command" \
        ! -name "MacRemoteApp-User-Guide.txt" \
        ! -name "MacRemoteApp-How-to-Debug.txt" \
        ! -name "MacRemoteApp-How-to-Collect-Debug-Logs.txt" \
        ! -name "Applications" \
        ! -name "${manifest_name}" \
        -print -quit)"
    if [[ -n "${extra_entry}" ]]; then
        echo "Release audit failed: unexpected top-level payload ${extra_entry} in ${dmg_path}" >&2
        payload_status=1
    fi

    if [[ -e "${applications_alias}" || -L "${applications_alias}" ]]; then
        applications_alias_target="$(readlink "${applications_alias}" 2>/dev/null || true)"
        if [[ ! -L "${applications_alias}" || "${applications_alias_target}" != "/Applications" ]]; then
            echo "Release audit failed: Applications entry must be a symlink to /Applications in ${dmg_path}" >&2
            payload_status=1
        fi
    else
        echo "Release audit failed: standard Applications alias is missing from ${dmg_path}" >&2
        payload_status=1
    fi

    if [[ ! -d "${mount_point}/${app_name}.app" ]]; then
        echo "Release audit failed: ${app_name}.app is missing from ${dmg_path}" >&2
        payload_status=1
    elif ! codesign --verify --deep --strict "${mount_point}/${app_name}.app"; then
        echo "Release audit failed: app payload signature is invalid in ${dmg_path}" >&2
        payload_status=1
    elif ! diff -qr \
        "${release_root}/${app_name}.app" \
        "${mount_point}/${app_name}.app" >/dev/null
    then
        echo "Release audit failed: app payload differs from the audited app bundle in ${dmg_path}" >&2
        payload_status=1
    fi

    for payload_name in \
        "Install-MacRemoteApp-${role_name}.command" \
        "Uninstall-MacRemoteApp-${role_name}.command" \
        "MacRemoteApp-User-Guide.txt" \
        "MacRemoteApp-How-to-Debug.txt" \
        "MacRemoteApp-How-to-Collect-Debug-Logs.txt"
    do
        if [[ ! -s "${mount_point}/${payload_name}" ]]; then
            echo "Release audit failed: ${payload_name} is missing from ${dmg_path}" >&2
            payload_status=1
        fi
    done

    : > "${expected_manifest}"
    for payload_name in \
        "Install-MacRemoteApp-${role_name}.command" \
        "Uninstall-MacRemoteApp-${role_name}.command" \
        "MacRemoteApp-User-Guide.txt" \
        "MacRemoteApp-How-to-Debug.txt" \
        "MacRemoteApp-How-to-Collect-Debug-Logs.txt"
    do
        if [[ -s "${mount_point}/${payload_name}" ]]; then
            printf '%s  %s\n' \
                "$(shasum -a 256 -- "${mount_point}/${payload_name}" | awk '{print $1}')" \
                "${payload_name}" >> "${expected_manifest}"
        fi
    done
    if [[ ! -s "${manifest_path}" ]]; then
        echo "Release audit failed: ${manifest_name} is missing from ${dmg_path}" >&2
        payload_status=1
    elif ! cmp -s "${expected_manifest}" "${manifest_path}"; then
        echo "Release audit failed: ${manifest_name} does not match the DMG payload in ${dmg_path}" >&2
        payload_status=1
    fi

    for payload_name in \
        "Install-MacRemoteApp-${role_name}.command" \
        "Uninstall-MacRemoteApp-${role_name}.command"
    do
        if [[ ! -x "${mount_point}/${payload_name}" ]]; then
            echo "Release audit failed: ${payload_name} is not executable in ${dmg_path}" >&2
            payload_status=1
        fi
    done

    if ! hdiutil detach "${mount_point}" >/dev/null; then
        echo "Release audit failed: unable to detach ${dmg_path}" >&2
        payload_status=1
    fi
    return "${payload_status}"
}

assert_architectures() {
    local app_name="$1"
    local binary_path="$2"
    local architectures
    architectures="$(lipo -archs "${binary_path}" 2>/dev/null)" || {
        echo "Release audit failed: unable to inspect architectures for ${app_name}" >&2
        return 1
    }
    case "${app_name}" in
        MacRemoteApp-Host)
            if [[ "${architectures}" != "arm64 x86_64" &&
                  "${architectures}" != "x86_64 arm64" ]]; then
                echo "Release audit failed: Host must contain arm64 and x86_64 (got ${architectures})" >&2
                return 1
            fi
            ;;
        MacRemoteApp-Viewer)
            if [[ "${architectures}" != "arm64" ]]; then
                echo "Release audit failed: Viewer must contain arm64 only (got ${architectures})" >&2
                return 1
            fi
            ;;
        *)
            echo "Release audit failed: unknown app architecture policy for ${app_name}" >&2
            return 1
            ;;
    esac
}

assert_role_metadata() {
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
            echo "Release audit failed: unknown app metadata policy for ${app_name}" >&2
            return 1
            ;;
    esac
    bundle_identifier="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' \
        "${app_path}/Contents/Info.plist" 2>/dev/null)" || {
        echo "Release audit failed: unreadable bundle metadata for ${app_name}" >&2
        return 1
    }
    bundle_executable="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleExecutable' \
        "${app_path}/Contents/Info.plist" 2>/dev/null)" || {
        echo "Release audit failed: missing CFBundleExecutable for ${app_name}" >&2
        return 1
    }
    if [[ "${bundle_identifier}" != "${expected_bundle_identifier}" ||
          "${bundle_executable}" != "${app_name}" ]]; then
        echo "Release audit failed: role metadata mismatch for ${app_name}" >&2
        return 1
    fi
}

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    app_path="${release_root}/${app_name}.app"
    binary_path="${app_path}/Contents/MacOS/${app_name}"
    test -d "${app_path}"
    test -x "${binary_path}"
    assert_architectures "${app_name}" "${binary_path}"
    assert_role_metadata "${app_name}" "${app_path}"
    plutil -lint "${app_path}/Contents/Info.plist" >/dev/null
    codesign --verify --deep --strict "${app_path}"

    signature_info="$(codesign --display --verbose=4 "${app_path}" 2>&1)"
    if ! printf '%s\n' "${signature_info}" | grep -Eq 'flags=.*runtime'; then
        echo "Release audit failed: ${app_name} is not signed with the hardened runtime" >&2
        exit 1
    fi

    entitlements_path="${audit_tmp_dir}/${app_name}.entitlements.txt"
    codesign --display --entitlements :- "${app_path}" >"${entitlements_path}" 2>&1 || true
    if grep -En 'com\.apple\.security\.get-task-allow|allow-dyld-environment-variables' \
        "${entitlements_path}" >/dev/null; then
        echo "Release audit failed: development entitlement found in ${app_name}" >&2
        exit 1
    fi

    debug_markers='--m3-list-windows|--m2-physical-host|--m2-physical-viewer|--m7-physical-host|--m7-physical-viewer|--m5-input-surface|MACREMOTEAPP_P12_PASSWORD'
    if strings "${binary_path}" | grep -En -- "${debug_markers}" >/dev/null; then
        echo "Release audit failed: debug/test command material is present in ${app_name}" >&2
        exit 1
    fi
done

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    dmg_path="${release_root}/${app_name}.dmg"
    test -s "${dmg_path}"
    codesign --verify --verbose=2 "${dmg_path}"
    verify_dmg_payload "${dmg_path}" "${app_name}"
done

if [[ -n "$(find "${release_root}" -type f \
    \( -name '*.p12' -o -name '*.p8' -o -name '*.key' -o -name '*.pem' \) \
    -print -quit)" ]]; then
    echo "Release audit failed: private identity material is inside the release artifact" >&2
    exit 1
fi

credential_pattern='BEGIN (RSA|EC|OPENSSH|DSA|ENCRYPTED)? ?PRIVATE KEY|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}'
credential_matches_repo="$(find "${repo_root}" \
    \( -path "${repo_root}/.git" \
       -o -path "${repo_root}/build" \
       -o -name '.build' \
       -o -name '.swiftpm' \) -prune -o \
    -type f -exec grep -I -E -l \
        "${credential_pattern}" \
        {} + || true)"
credential_matches_release="$(find "${release_root}" \
    -type f -exec grep -I -E -l "${credential_pattern}" {} + || true)"
if [[ -n "${credential_matches_repo}" || -n "${credential_matches_release}" ]]; then
    echo "Release audit failed: credential-like material found in repository or release inputs (match contents redacted)" >&2
    exit 1
fi

echo "M9 release audit passed: hardened apps, signed DMGs, no development entitlements, no debug commands, no identity material"
