#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
build_root="${repo_root}/.build/public-validation"

mkdir -p "${build_root}/clang-module-cache" "${build_root}/swift-module-cache"
export TMPDIR="${build_root}/tmp"
export CLANG_MODULE_CACHE_PATH="${build_root}/clang-module-cache"
export SWIFT_MODULECACHE_PATH="${build_root}/swift-module-cache"
export SWIFT_DETERMINISTIC_HASHING=1
mkdir -p "${TMPDIR}"

cd "${repo_root}"

echo "Validating Swift package graph"
swift package describe >/dev/null

echo "Validating physical smoke and app bundle inputs"
bash -n scripts/create-m2-identities.sh scripts/package-device-apps.sh
plutil -lint Resources/Host-Info.plist Resources/Viewer-Info.plist >/dev/null
test -s Resources/MacRemoteAppIcon.svg
for forbidden_identity_path in \
    "${repo_root}" \
    "${repo_root}/Tests"
do
    if bash scripts/create-m2-identities.sh "${forbidden_identity_path}" >/dev/null 2>&1; then
        echo "Validation failed: identity material was accepted inside the repository" >&2
        exit 1
    fi
done

echo "Checking M6 boundary"
forbidden_hits="$(rg -n \
    'NSPasteboard|WebRTC|AVAudio' \
    Apps Packages Tests --glob '*.swift' || true)"
if [[ -n "${forbidden_hits}" ]]; then
    echo "Validation failed: a later-milestone product API or feature was added" >&2
    echo "${forbidden_hits}" >&2
    exit 1
fi

echo "Checking required M5 documents"
for document in \
    docs/PRODUCT_SPEC.md \
    docs/ARCHITECTURE.md \
    docs/PROTOCOL.md \
    docs/SECURITY.md \
    docs/DEVELOPMENT_PLAN.md \
    docs/M1_PROTOCOL.md \
    docs/M2_SESSION.md \
    docs/M2_PHYSICAL_SMOKE.md \
    docs/M3_CAPTURE.md \
    docs/M4_CODEC.md \
    docs/M5_INPUT.md \
    docs/M6_INPUT_INJECTION.md
do
    test -s "${document}"
done

echo "Building Host (arm64)"
swift build \
    --configuration debug \
    --arch arm64 \
    --target Host \
    --scratch-path "${build_root}/host-arm64"

echo "Building Host (x86_64)"
swift build \
    --configuration debug \
    --arch x86_64 \
    --target Host \
    --scratch-path "${build_root}/host-x86_64"

echo "Building Viewer (arm64)"
swift build \
    --configuration debug \
    --arch arm64 \
    --target Viewer \
    --scratch-path "${build_root}/viewer-arm64"

echo "Testing root smoke target"
swift test --configuration debug --scratch-path "${build_root}/root"

for package_dir in \
    Packages/RemoteProtocol \
    Packages/CaptureCore \
    Packages/CodecCore \
    Packages/TransportCore \
    Packages/InputCore \
    Packages/SecurityCore
do
    package_name="$(basename "${package_dir}")"
    echo "Testing ${package_dir}"
    swift test \
        --package-path "${package_dir}" \
        --scratch-path "${build_root}/package-${package_name}" \
        --configuration debug
done

echo "Public validation passed"
