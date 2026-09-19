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
bash -n \
    scripts/create-m2-identities.sh \
    scripts/package-device-apps.sh \
    scripts/notarize-device-apps.sh
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

echo "Checking M8-M10 boundary"
forbidden_hits="$(rg -n \
    'WebRTC|AVAudio|AVAsset' \
    Apps Packages Tests --glob '*.swift' || true)"
if [[ -n "${forbidden_hits}" ]]; then
    echo "Validation failed: a later-milestone product API or feature was added" >&2
    echo "${forbidden_hits}" >&2
    exit 1
fi
pasteboard_scope_hits="$(rg -n 'NSPasteboard' Packages Tests --glob '*.swift' || true)"
if [[ -n "${pasteboard_scope_hits}" ]]; then
    echo "Validation failed: NSPasteboard is allowed only in Apps/Host and Apps/Viewer" >&2
    echo "${pasteboard_scope_hits}" >&2
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
    docs/M6_INPUT_INJECTION.md \
    docs/M7_CLIPBOARD_UX.md \
    docs/M8_PERFORMANCE_RESILIENCE.md \
    docs/M9_SECURITY_RELEASE.md \
    docs/M10_ACCEPTANCE.md
do
    test -s "${document}"
done

bash -n \
    scripts/run-m8-benchmark.sh \
    scripts/audit-release.sh \
    scripts/run-m10-acceptance.sh \
    scripts/notarize-device-apps.sh

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

echo "Building M8 benchmark tool"
swift build \
    --configuration release \
    --target M8Benchmark \
    --scratch-path "${build_root}/m8-benchmark"

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

echo "Running M8 deterministic benchmark"
MACREMOTEAPP_M8_REPORT="${build_root}/m8-performance-report.json" \
    bash scripts/run-m8-benchmark.sh

echo "Checking M8 benchmark rejects oversized sample input"
set +e
swift run \
    --configuration release \
    --scratch-path "${build_root}/m8-input-regression" \
    M8Benchmark \
    --samples 1000001 \
    --duration-seconds 30 \
    >/dev/null 2>&1
m8_input_exit=$?
set -e
if (( m8_input_exit == 0 )); then
    echo "M8 benchmark accepted an oversized sample count" >&2
    exit 1
fi
set +e
swift run \
    --configuration release \
    --scratch-path "${build_root}/m8-input-regression" \
    M8Benchmark \
    --samples not-a-number \
    --duration-seconds 30 \
    >/dev/null 2>&1
m8_malformed_input_exit=$?
set -e
if (( m8_malformed_input_exit == 0 )); then
    echo "M8 benchmark accepted a malformed sample count" >&2
    exit 1
fi

echo "Packaging and auditing M9 release candidates"
MACREMOTEAPP_SIGNING_IDENTITY=- bash scripts/package-device-apps.sh
bash scripts/audit-release.sh

echo "Public validation passed"
