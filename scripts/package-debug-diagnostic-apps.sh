#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
source "${script_dir}/notarization-config.sh"
source "${script_dir}/artifact-naming.sh"
cd "${repo_root}"

release_root="${repo_root}/build/debug-diagnostic"
build_root="${repo_root}/.build/m10-debug-diagnostic"
artifact_root="${repo_root}/build"
build_base="${repo_root}/.build"
package_mode="package"
if (( $# == 1 )); then
    case "$1" in
        --check) package_mode="check" ;;
        --stage) package_mode="stage" ;;
        *)
            echo "Usage: bash scripts/package-debug-diagnostic-apps.sh [--check|--stage]" >&2
            exit 2
            ;;
    esac
fi

fail() {
    echo "Debug diagnostic packaging failed: $*" >&2
    exit 2
}

if [[ "${MACREMOTEAPP_RELEASE_ROOT+x}" == "x" &&
      "${MACREMOTEAPP_RELEASE_ROOT}" != "${release_root}" ]]; then
    fail "MACREMOTEAPP_RELEASE_ROOT is fixed to ${release_root}"
fi
if [[ "${MACREMOTEAPP_RELEASE_BUILD_ROOT+x}" == "x" &&
      "${MACREMOTEAPP_RELEASE_BUILD_ROOT}" != "${build_root}" ]]; then
    fail "MACREMOTEAPP_RELEASE_BUILD_ROOT is fixed to ${build_root}"
fi
if [[ "${MACREMOTEAPP_ARTIFACT_CHANNEL+x}" == "x" &&
      "${MACREMOTEAPP_ARTIFACT_CHANNEL}" != "debug-diagnostic" ]]; then
    fail "MACREMOTEAPP_ARTIFACT_CHANNEL must be debug-diagnostic"
fi

for directory in "${artifact_root}" "${release_root}" "${build_base}" "${build_root}"; do
    if [[ -L "${directory}" || ( -e "${directory}" && ! -d "${directory}" ) ]]; then
        fail "refusing a symlink or non-directory path: ${directory}"
    fi
done

artifact_channel="$(macremoteapp_resolve_artifact_channel "${repo_root}" "${release_root}")" || exit 2
[[ "${artifact_channel}" == "debug-diagnostic" ]] || fail "unexpected artifact channel ${artifact_channel}"

if [[ "${package_mode}" == "check" ]]; then
    printf 'SwiftPM configuration: debug\n'
    printf 'Artifact channel: %s\n' "${artifact_channel}"
    printf 'App bundles, versioned ZIPs, and DMGs: %s\n' "${release_root}"
    printf 'SwiftPM scratch and module caches: %s\n' "${build_root}"
    printf 'Host architectures: arm64, x86_64; Viewer architecture: arm64\n'
    printf 'Promotion: audited staging with rollback to %s\n' "${release_root}"
    exit 0
fi

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if ! DEVELOPER_DIR="$(xcode-select -p 2>/dev/null)"; then
        fail "unable to resolve the selected Xcode toolchain with xcode-select -p"
    fi
fi
if [[ ! -d "${DEVELOPER_DIR}" ]]; then
    fail "DEVELOPER_DIR must name an installed Xcode Developer directory"
fi
export DEVELOPER_DIR

signing_identity="$(macremoteapp_resolve_signing_identity -)" || fail "unable to resolve the configured Developer ID identity"
if [[ -z "${signing_identity}" || "${signing_identity}" == "-" ]]; then
    fail "set MACREMOTEAPP_SIGNING_IDENTITY to the existing Developer ID Application identity; ad-hoc signing is not supported"
fi

bash "${script_dir}/ensure-local-build-exclude.sh" "${repo_root}" >&2
mkdir -p -- "${artifact_root}" "${build_base}" "${build_root}"
generation_root="$(mktemp -d "${build_root}/generation.XXXXXX")"
package_root="${generation_root}/artifacts"
icon_source_dir=""
icon_work_dir=""
retain_generation=0
preserve_generation_on_failure=0
cleanup_generation() {
    local status=$?
    if [[ -n "${icon_source_dir}" && -d "${icon_source_dir}" ]]; then
        rm -rf -- "${icon_source_dir}"
    fi
    if [[ -n "${icon_work_dir}" && -d "${icon_work_dir}" ]]; then
        rm -rf -- "${icon_work_dir}"
    fi
    if (( ! retain_generation && !( status != 0 && preserve_generation_on_failure ) )) &&
       [[ -n "${generation_root}" && -d "${generation_root}" && ! -L "${generation_root}" ]]; then
        rm -rf -- "${generation_root}"
    fi
    exit "${status}"
}
trap cleanup_generation EXIT

mkdir -p -- "${package_root}" "${generation_root}/tmp" \
    "${generation_root}/clang-module-cache" "${generation_root}/swift-module-cache"
empty_entitlements_path="${generation_root}/debug-empty-entitlements.plist"
cat >"${empty_entitlements_path}" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
ENTITLEMENTS
plutil -lint "${empty_entitlements_path}" >/dev/null ||
    fail "unable to prepare the explicit empty Debug signing entitlements"

export TMPDIR="${generation_root}/tmp"
export CLANG_MODULE_CACHE_PATH="${generation_root}/clang-module-cache"
export SWIFT_MODULECACHE_PATH="${generation_root}/swift-module-cache"
export SWIFT_DETERMINISTIC_HASHING=1

build_target() {
    local target="$1"
    local arch="$2"
    local scratch_path="${generation_root}/swift-${target}-${arch}"
    local binary_path

    echo "Building ${target} (${arch}) in SwiftPM Debug configuration" >&2
    if ! swift build \
        --configuration debug \
        --arch "${arch}" \
        --target "${target}" \
        --scratch-path "${scratch_path}" >&2
    then
        fail "SwiftPM Debug build failed for ${target} (${arch})"
    fi
    if ! binary_path="$(swift build \
        --configuration debug \
        --arch "${arch}" \
        --target "${target}" \
        --scratch-path "${scratch_path}" \
        --show-bin-path)"
    then
        fail "unable to resolve the SwiftPM output path for ${target} (${arch})"
    fi
    test -x "${binary_path}/${target}"
    printf '%s\n' "${binary_path}/${target}"
}

host_arm64="$(build_target Host arm64)"
host_x86_64="$(build_target Host x86_64)"
viewer_arm64="$(build_target Viewer arm64)"
host_binary="${package_root}/MacRemoteApp-Host"
viewer_binary="${package_root}/MacRemoteApp-Viewer"
lipo -create "${host_arm64}" "${host_x86_64}" -output "${host_binary}"
cp -- "${viewer_arm64}" "${viewer_binary}"
chmod 755 "${host_binary}" "${viewer_binary}"

for binary in "${host_binary}" "${viewer_binary}"; do
    if ! strings "${binary}" | grep -F -- MACREMOTEAPP_M10_DEBUG_DIAGNOSTICS >/dev/null; then
        fail "the SwiftPM Debug marker is missing from $(basename -- "${binary}")"
    fi
done

icon_source_dir="$(mktemp -d "${TMPDIR}/macremoteapp-icon-source.XXXXXX")"
icon_work_dir="$(mktemp -d "${TMPDIR}/macremoteapp-iconset.XXXXXX")"
qlmanage -t -s 1024 -o "${icon_source_dir}" \
    "${repo_root}/Resources/MacRemoteAppIcon.svg" >/dev/null
icon_png="${icon_source_dir}/MacRemoteAppIcon.svg.png"
test -s "${icon_png}"
iconset_dir="${icon_work_dir}/MacRemoteAppIcon.iconset"
mkdir -p -- "${iconset_dir}"
for size in 16 32 128 256 512; do
    double_size=$((size * 2))
    sips -z "${size}" "${size}" "${icon_png}" \
        --out "${iconset_dir}/icon_${size}x${size}.png" >/dev/null
    sips -z "${double_size}" "${double_size}" "${icon_png}" \
        --out "${iconset_dir}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "${iconset_dir}" -o "${package_root}/MacRemoteAppIcon.icns"

package_app() {
    local name="$1"
    local binary="$2"
    local info_plist="$3"
    local app_dir="${package_root}/${name}.app"

    mkdir -p -- "${app_dir}/Contents/MacOS" "${app_dir}/Contents/Resources"
    cp -- "${binary}" "${app_dir}/Contents/MacOS/${name}"
    cp -- "${info_plist}" "${app_dir}/Contents/Info.plist"
    cp -- "${package_root}/MacRemoteAppIcon.icns" \
        "${app_dir}/Contents/Resources/MacRemoteAppIcon.icns"
    chmod 755 "${app_dir}/Contents/MacOS/${name}"
}

package_app MacRemoteApp-Host "${host_binary}" "${repo_root}/Resources/Host-Info.plist"
package_app MacRemoteApp-Viewer "${viewer_binary}" "${repo_root}/Resources/Viewer-Info.plist"

release_identity="$(macremoteapp_release_identity \
    "${package_root}/MacRemoteApp-Host.app/Contents/Info.plist" \
    "${package_root}/MacRemoteApp-Viewer.app/Contents/Info.plist")" || exit 2
source_release_identity="$(macremoteapp_release_identity \
    "${repo_root}/Resources/Host-Info.plist" \
    "${repo_root}/Resources/Viewer-Info.plist")" || exit 2
[[ "${release_identity}" == "${source_release_identity}" ]] ||
    fail "packaged Host and Viewer metadata differ from the source release identity"

for app_name in MacRemoteApp-Host MacRemoteApp-Viewer; do
    app_dir="${package_root}/${app_name}.app"
    macremoteapp_sign_app "${app_dir}" "${signing_identity}" "${empty_entitlements_path}" >&2
    codesign --verify --deep --strict "${app_dir}"
    signature_info="$(codesign --display --verbose=4 "${app_dir}" 2>&1)"
    if ! printf '%s\n' "${signature_info}" | grep -Eq 'Authority=Developer ID Application:' ||
       ! printf '%s\n' "${signature_info}" | grep -Eq 'TeamIdentifier=LYK4LV2859' ||
       ! printf '%s\n' "${signature_info}" | grep -Eq 'flags=.*runtime'; then
        fail "${app_name} must use the existing Developer ID team and hardened runtime"
    fi
    entitlement_info="$(codesign --display --entitlements :- "${app_dir}" 2>&1 || true)"
    if printf '%s\n' "${entitlement_info}" | grep -Eq 'com\.apple\.security\.get-task-allow|allow-dyld-environment-variables'; then
        fail "development entitlements are forbidden in ${app_name}"
    fi
done

for role in Host Viewer; do
    app_name="MacRemoteApp-${role}"
    app_zip_name="$(macremoteapp_expected_distribution_name \
        "${artifact_channel}" "${release_identity}" "${app_name}" app-zip)" || exit 2
    ditto -c -k --keepParent \
        "${package_root}/${app_name}.app" \
        "${package_root}/${app_zip_name}"
done

MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}" \
MACREMOTEAPP_REQUIRE_DEVELOPER_ID=1 \
MACREMOTEAPP_SIGNING_IDENTITY="${signing_identity}" \
    bash "${script_dir}/create-device-dmgs.sh" "${package_root}" >&2
MACREMOTEAPP_ARTIFACT_CHANNEL="${artifact_channel}" \
    bash "${script_dir}/audit-debug-diagnostic-apps.sh" "${package_root}" >&2

if [[ "${package_mode}" == "stage" ]]; then
    retain_generation=1
    printf '%s\n' "${package_root}"
    exit 0
fi

echo "Promoting audited signed Debug diagnostic artifacts into ${release_root}"
if ! bash "${script_dir}/promote-debug-diagnostic-apps.sh" "${package_root}"; then
    preserve_generation_on_failure=1
    fail "promotion failed; the current generation is retained at ${generation_root}"
fi
echo "Built signed Debug diagnostic apps, ZIPs, and DMGs in ${release_root}"
