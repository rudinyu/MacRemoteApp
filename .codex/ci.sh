#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
ci_tmp_dir="${repo_root}/.build/ci-tmp"

mkdir -p "${ci_tmp_dir}" \
    "${repo_root}/.build/clang-module-cache" \
    "${repo_root}/.build/swift-module-cache"

export TMPDIR="${ci_tmp_dir}"
export CLANG_MODULE_CACHE_PATH="${repo_root}/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="${repo_root}/.build/swift-module-cache"
export SWIFT_DETERMINISTIC_HASHING=1

cd "${repo_root}"

echo "Validating Swift package graph"
swift package describe >/dev/null

echo "Checking M0 source scope"
forbidden_hits="$(rg -n \
    'ScreenCaptureKit|VideoToolbox|Network\.framework|import Network|import CoreGraphics|import ApplicationServices|import Metal|CGEvent|AXUIElement|NSPasteboard|WebRTC|AVAudio' \
    Apps Packages Tests --glob '*.swift' || true)"
if [[ -n "${forbidden_hits}" ]]; then
    echo "M0 scope check failed: forbidden product API or feature reference found" >&2
    echo "${forbidden_hits}" >&2
    exit 1
fi

echo "Building Host target"
swift build --configuration debug --target Host

echo "Building Viewer target"
swift build --configuration debug --target Viewer

echo "Testing root smoke target"
swift test --configuration debug

for package_dir in \
    Packages/RemoteProtocol \
    Packages/CaptureCore \
    Packages/CodecCore \
    Packages/TransportCore \
    Packages/InputCore \
    Packages/SecurityCore
do
    echo "Testing ${package_dir}"
    package_name="$(basename "${package_dir}")"
    swift test \
        --package-path "${package_dir}" \
        --scratch-path "${repo_root}/.build/package-${package_name}" \
        --configuration debug
done

echo "M0 validation passed"
