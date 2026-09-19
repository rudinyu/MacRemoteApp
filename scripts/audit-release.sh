#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
release_root="${1:-${repo_root}/.build/device-binaries/release}"

cd "${repo_root}"
test -d "${release_root}"
audit_tmp_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/macremoteapp-release-audit.XXXXXX")"
trap 'rm -rf -- "${audit_tmp_dir}"' EXIT

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    app_path="${release_root}/${app_name}.app"
    binary_path="${app_path}/Contents/MacOS/${app_name}"
    test -d "${app_path}"
    test -x "${binary_path}"
    plutil -lint "${app_path}/Contents/Info.plist" >/dev/null
    codesign --verify --deep --strict "${app_path}"

    signature_info="$(codesign --display --verbose=4 "${app_path}" 2>&1)"
    if ! printf '%s\n' "${signature_info}" | rg -q 'flags=.*runtime'; then
        echo "Release audit failed: ${app_name} is not signed with the hardened runtime" >&2
        exit 1
    fi

    entitlements_path="${audit_tmp_dir}/${app_name}.entitlements.txt"
    codesign --display --entitlements :- "${app_path}" >"${entitlements_path}" 2>&1 || true
    if rg -n 'com\.apple\.security\.get-task-allow|allow-dyld-environment-variables' \
        "${entitlements_path}" >/dev/null; then
        echo "Release audit failed: development entitlement found in ${app_name}" >&2
        exit 1
    fi

    debug_markers='--m3-list-windows|--m2-physical-host|--m2-physical-viewer|--m7-physical-host|--m7-physical-viewer|--m5-input-surface|MACREMOTEAPP_P12_PASSWORD'
    if strings "${binary_path}" | rg -n -- "${debug_markers}" >/dev/null; then
        echo "Release audit failed: debug/test command material is present in ${app_name}" >&2
        exit 1
    fi
done

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    dmg_path="${release_root}/${app_name}.dmg"
    test -s "${dmg_path}"
    codesign --verify --verbose=2 "${dmg_path}"
done

if find "${release_root}" -type f \( -name '*.p12' -o -name '*.key' -o -name '*.pem' \) -print -quit | rg -q .; then
    echo "Release audit failed: private identity material is inside the release artifact" >&2
    exit 1
fi

if git grep -q -I -E \
    'BEGIN (RSA|EC|OPENSSH) PRIVATE KEY|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}' \
    -- . ':!docs/M9_SECURITY_RELEASE.md'; then
    echo "Release audit failed: credential-like material found in tracked files (match contents redacted)" >&2
    exit 1
fi

echo "M9 release audit passed: hardened apps, signed DMGs, no development entitlements, no debug commands, no identity material"
