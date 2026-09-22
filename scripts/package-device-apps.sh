#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
cd "${repo_root}"

# Keep repository-local artifacts out of Git without publishing a .gitignore.
# This updates only this checkout's .git/info/exclude on the first packaging
# run, which is also safe for fresh clones.
bash "${script_dir}/ensure-local-build-exclude.sh" "${repo_root}"

build_root="${MACREMOTEAPP_RELEASE_BUILD_ROOT:-${repo_root}/.build/device-binaries}"
# `build/testing` is the local, replace-on-invocation channel; removing it
# first guarantees that only the latest testing artifacts remain. CI and the
# notarized channels pass an explicit release root and remain isolated.
release_root="${MACREMOTEAPP_RELEASE_ROOT:-${repo_root}/build/testing}"
artifact_root="${repo_root}/build"
if [[ -L "${artifact_root}" || ( -e "${artifact_root}" && ! -d "${artifact_root}" ) ]]; then
    echo "Refusing to use a non-directory or symlink artifact root: ${artifact_root}" >&2
    exit 2
fi
mkdir -p -- "${artifact_root}"
if [[ "${build_root}" != /* ]]; then
    build_root="${repo_root}/${build_root}"
fi
build_base="${repo_root}/.build"
if [[ -L "${build_base}" || ( -e "${build_base}" && ! -d "${build_base}" ) ]]; then
    echo "Refusing to use a non-directory or symlink build base: ${build_base}" >&2
    exit 2
fi
mkdir -p -- "${build_base}"
build_base="$(cd -P -- "${build_base}" && pwd -P)"
if [[ "${build_base}" != "${repo_root}/.build" ]]; then
    echo "MACREMOTEAPP_RELEASE_BUILD_ROOT must resolve inside the repository .build directory: ${build_root}" >&2
    exit 2
fi

case "${build_root}" in
    "${build_base}/"*)
        ;;
    *)
        echo "MACREMOTEAPP_RELEASE_BUILD_ROOT must be a repository-local .build descendant: ${build_root}" >&2
        exit 2
        ;;
esac
if [[ -L "${build_root}" || ( -e "${build_root}" && ! -d "${build_root}" ) ]]; then
    echo "Refusing to use a non-directory or symlink build root: ${build_root}" >&2
    exit 2
fi

# Resolve the nearest existing parent before mkdir/rm. A missing path beneath
# an existing symlink would otherwise pass the lexical prefix check and make
# the cleanup below follow that symlink outside the repository.
build_parent="$(dirname -- "${build_root}")"
existing_parent="${build_parent}"
while [[ ! -e "${existing_parent}" && ! -L "${existing_parent}" ]]; do
    next_parent="$(dirname -- "${existing_parent}")"
    if [[ "${next_parent}" == "${existing_parent}" ]]; then
        echo "Unable to resolve build-root parent: ${build_parent}" >&2
        exit 2
    fi
    existing_parent="${next_parent}"
done
if [[ -L "${existing_parent}" || ! -d "${existing_parent}" ]]; then
    echo "Refusing to follow a symlink or non-directory build-root parent: ${existing_parent}" >&2
    exit 2
fi
existing_parent="$(cd -P -- "${existing_parent}" && pwd -P)"
case "${existing_parent}" in
    "${build_base}"|"${build_base}/"*)
        ;;
    *)
        echo "MACREMOTEAPP_RELEASE_BUILD_ROOT must resolve inside the repository .build directory: ${build_root}" >&2
        exit 2
        ;;
esac
mkdir -p -- "${build_parent}"
if [[ -L "${build_root}" || ( -e "${build_root}" && ! -d "${build_root}" ) ]]; then
    echo "Refusing to use a non-directory or symlink build root: ${build_root}" >&2
    exit 2
fi
build_name="$(basename -- "${build_root}")"
if [[ "${build_name}" == "." || "${build_name}" == ".." || -z "${build_name}" ]]; then
    echo "MACREMOTEAPP_RELEASE_BUILD_ROOT must name a dedicated directory: ${build_root}" >&2
    exit 2
fi
build_parent="$(cd -P -- "${build_parent}" && pwd -P)"
build_root="${build_parent}/${build_name}"
case "${build_root}" in
    "${build_base}/"*)
        ;;
    *)
        echo "MACREMOTEAPP_RELEASE_BUILD_ROOT must resolve inside the repository .build directory: ${build_root}" >&2
        exit 2
        ;;
esac
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
    "${repo_root}/build/testing")
        ;;
    "${repo_root}/build/beta"|"${repo_root}/build/rc"|"${repo_root}/build/release")
        echo "Refusing to write a formal channel directly; use scripts/release-notarized.sh for replacement-safe notarized promotion: ${release_root}" >&2
        exit 2
        ;;
    "${repo_root}/build/MacRemoteApp-"*.staging.*)
        ;;
    "${repo_root}/.build/"*)
        ;;
    "${repo_root}"|"${repo_root}"/*)
        echo "MACREMOTEAPP_RELEASE_ROOT must be a build channel or an isolated .build descendant: ${release_root}" >&2
        exit 2
        ;;
    *)
        echo "MACREMOTEAPP_RELEASE_ROOT must be a repository-local build channel or isolated .build descendant: ${release_root}" >&2
        exit 2
        ;;
esac
case "${repo_root}" in
    "${release_root}"/*)
        echo "MACREMOTEAPP_RELEASE_ROOT must not contain the repository: ${release_root}" >&2
        exit 2
        ;;
esac

signing_identity="${MACREMOTEAPP_SIGNING_IDENTITY:-}"
if [[ -z "${signing_identity}" ]]; then
    signing_identity="-"
fi
require_developer_id=0
if [[ "${MACREMOTEAPP_REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
    require_developer_id=1
    if [[ "${signing_identity}" == "-" ]]; then
        echo "This release path requires a Developer ID Application identity; ad-hoc signing is not allowed." >&2
        exit 2
    fi
fi

echo "Removing previous build output before building ${release_root}"
rm -rf -- "${release_root}" "${build_root}"
mkdir -p -- "${release_root}"

build_target() {
    local target="$1"
    local arch="$2"
    local scratch_path="${build_root}/build-${target}-${arch}"
    # Keep build diagnostics on stderr so the command substitution below
    # captures only the verified binary directory. The build and path lookup
    # are separate commands so a failed build cannot be hidden by a trailing
    # `tail` in a pipeline.
    if ! swift build \
        --configuration release \
        --arch "${arch}" \
        --target "${target}" \
        --scratch-path "${scratch_path}" >&2
    then
        echo "Release build failed for ${target} (${arch})" >&2
        return 1
    fi

    local bin_path
    if ! bin_path="$(swift build \
        --configuration release \
        --arch "${arch}" \
        --target "${target}" \
        --scratch-path "${scratch_path}" \
        --show-bin-path)"
    then
        echo "Unable to resolve release binary path for ${target} (${arch})" >&2
        return 1
    fi
    printf '%s\n' "${bin_path}"
}

echo "Building Host arm64"
host_arm64="$(build_target Host arm64)/Host"
echo "Building Host x86_64"
host_x86_64="$(build_target Host x86_64)/Host"
echo "Building Viewer arm64"
viewer_arm64="$(build_target Viewer arm64)/Viewer"

host_binary="${release_root}/MacRemoteApp-Host"
viewer_binary="${release_root}/MacRemoteApp-Viewer"
lipo -create "${host_arm64}" "${host_x86_64}" -output "${host_binary}"
cp -- "${viewer_arm64}" "${viewer_binary}"
chmod 755 "${host_binary}" "${viewer_binary}"

icon_source_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/macremoteapp-icon-source.XXXXXX")"
icon_work_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/macremoteapp-iconset.XXXXXX")"
trap 'rm -rf -- "${icon_source_dir}" "${icon_work_dir}"' EXIT
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
iconutil -c icns "${iconset_dir}" -o "${release_root}/MacRemoteAppIcon.icns"

package_app() {
    local name="$1"
    local binary="$2"
    local info_plist="$3"
    local app_dir="${release_root}/${name}.app"

    mkdir -p -- "${app_dir}/Contents/MacOS" "${app_dir}/Contents/Resources"
    cp -- "${binary}" "${app_dir}/Contents/MacOS/${name}"
    cp -- "${info_plist}" "${app_dir}/Contents/Info.plist"
    cp -- "${release_root}/MacRemoteAppIcon.icns" \
        "${app_dir}/Contents/Resources/MacRemoteAppIcon.icns"
    chmod 755 "${app_dir}/Contents/MacOS/${name}"
}

package_app \
    MacRemoteApp-Host \
    "${host_binary}" \
    "${repo_root}/Resources/Host-Info.plist"
package_app \
    MacRemoteApp-Viewer \
    "${viewer_binary}" \
    "${repo_root}/Resources/Viewer-Info.plist"

if [[ "${signing_identity}" == "-" ]]; then
    echo "MACREMOTEAPP_SIGNING_IDENTITY=-; using ad-hoc signing for local validation." >&2
    echo "For stable macOS TCC identity, set it to a Developer ID Application certificate." >&2
fi

timestamp_arguments=(--timestamp)
if [[ "${signing_identity}" == "-" ]]; then
    timestamp_arguments=(--timestamp=none)
fi

for app_dir in \
    "${release_root}/MacRemoteApp-Host.app" \
    "${release_root}/MacRemoteApp-Viewer.app"
do
    codesign --force --deep --options runtime \
        --sign "${signing_identity}" \
        "${timestamp_arguments[@]}" "${app_dir}"
    codesign --verify --deep --strict "${app_dir}"
    if (( require_developer_id )); then
        signature_info="$(codesign --display --verbose=4 "${app_dir}" 2>&1)"
        if ! printf '%s\n' "${signature_info}" | grep -Eq 'Authority=Developer ID Application:'; then
            echo "Formal release packaging requires a Developer ID Application signature: ${app_dir}" >&2
            exit 1
        fi
        if ! printf '%s\n' "${signature_info}" | grep -Eq 'flags=.*runtime'; then
            echo "Formal release packaging requires the hardened runtime: ${app_dir}" >&2
            exit 1
        fi
    fi
done

ditto -c -k --keepParent \
    "${release_root}/MacRemoteApp-Host.app" \
    "${release_root}/MacRemoteApp-Host.app.zip"
ditto -c -k --keepParent \
    "${release_root}/MacRemoteApp-Viewer.app" \
    "${release_root}/MacRemoteApp-Viewer.app.zip"

MACREMOTEAPP_SIGNING_IDENTITY="${signing_identity}" \
    bash "${script_dir}/create-device-dmgs.sh" "${release_root}"

echo "Packaged signed artifacts in ${release_root}"
echo "Host:   ${release_root}/MacRemoteApp-Host.app"
echo "Viewer: ${release_root}/MacRemoteApp-Viewer.app"
