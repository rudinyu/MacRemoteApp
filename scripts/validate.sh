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

echo "Checking M5 boundary"
forbidden_hits="$(rg -n \
    'CGEvent|AXUIElement|NSPasteboard|WebRTC|AVAudio' \
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
    docs/M3_CAPTURE.md \
    docs/M4_CODEC.md \
    docs/M5_INPUT.md
do
    test -s "${document}"
done

echo "Building Host"
swift build --configuration debug --target Host --scratch-path "${build_root}/host"

echo "Building Viewer"
swift build --configuration debug --target Viewer --scratch-path "${build_root}/viewer"

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
