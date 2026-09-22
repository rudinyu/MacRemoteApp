#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
build_root="${repo_root}/.build/public-validation"

if [[ -L "${repo_root}/.build" || ( -e "${repo_root}/.build" && ! -d "${repo_root}/.build" ) ]]; then
    echo "Refusing to clean an unexpected .build path: ${repo_root}/.build" >&2
    exit 2
fi
echo "Removing previous validation build cache before starting validation"
rm -rf -- "${repo_root}/.build"

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
    scripts/create-device-dmgs.sh \
    scripts/install-device-apps.sh \
    scripts/package-device-apps.sh \
    scripts/notarize-device-apps.sh \
    scripts/release-notarized.sh \
    scripts/uninstall-device-apps.sh
if ! bash scripts/install-device-apps.sh --help | grep -Eq -- '--allow-ad-hoc'; then
    echo "Validation failed: installer does not expose explicit ad-hoc opt-in" >&2
    exit 1
fi
test -x scripts/ensure-local-build-exclude.sh
test -x scripts/check-notary-profile.sh
bash -n scripts/ensure-local-build-exclude.sh
bash -n scripts/check-notary-profile.sh
test -s scripts/clear-testing-keychain.swift
swiftc -parse scripts/clear-testing-keychain.swift
plutil -lint Resources/Host-Info.plist Resources/Viewer-Info.plist >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' Resources/Host-Info.plist 2>/dev/null)" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' Resources/Host-Info.plist 2>/dev/null)" != ""
test "$(/usr/libexec/PlistBuddy -c 'Print :NSScreenCaptureUsageDescription' Resources/Host-Info.plist 2>/dev/null)" != ""
test "$(/usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' Resources/Viewer-Info.plist 2>/dev/null)" != ""
test -s Resources/MacRemoteAppIcon.svg
for forbidden_package_root in \
    "${repo_root}" \
    "${repo_root}/build" \
    "${repo_root}/build/other-channel" \
    "${repo_root}/build/MacRemoteApp-release.invalid" \
    "${repo_root}/../MacRemoteApp-Release" \
    "${HOME}/Downloads/MacRemoteApp-release" \
    /
do
    if MACREMOTEAPP_RELEASE_ROOT="${forbidden_package_root}" \
        bash scripts/package-device-apps.sh >/dev/null 2>&1; then
        echo "Validation failed: package script accepted unsafe output root ${forbidden_package_root}" >&2
        exit 1
    fi
done
if MACREMOTEAPP_RELEASE_ROOT="${repo_root}/build/release" \
    MACREMOTEAPP_SIGNING_IDENTITY=- \
    bash scripts/package-device-apps.sh >/dev/null 2>&1; then
    echo "Validation failed: package script accepted ad-hoc signing for the formal release channel" >&2
    exit 1
fi
for forbidden_build_root in \
    "${repo_root}/.build" \
    "${repo_root}/.build/.." \
    "${repo_root}/.build/../outside" \
    /
do
    if MACREMOTEAPP_RELEASE_BUILD_ROOT="${forbidden_build_root}" \
        MACREMOTEAPP_RELEASE_ROOT="${repo_root}/build/testing" \
        MACREMOTEAPP_SIGNING_IDENTITY=- \
        bash scripts/package-device-apps.sh >/dev/null 2>&1; then
        echo "Validation failed: package script accepted unsafe build root ${forbidden_build_root}" >&2
        exit 1
    fi
done
if MACREMOTEAPP_SIGNING_IDENTITY=- \
    bash scripts/create-device-dmgs.sh "${repo_root}/build/release" >/dev/null 2>&1; then
    echo "Validation failed: DMG script accepted ad-hoc signing for the formal release channel" >&2
    exit 1
fi
if MACREMOTEAPP_RELEASE_ROOT="${repo_root}/build/release" \
    MACREMOTEAPP_SIGNING_IDENTITY=- \
    bash scripts/notarize-device-apps.sh >/dev/null 2>&1; then
    echo "Validation failed: notarization script accepted direct writes to the formal release channel" >&2
    exit 1
fi
if bash scripts/uninstall-device-apps.sh \
    --clean-testing \
    --identities "${repo_root}" \
    --yes >/dev/null 2>&1; then
    echo "Validation failed: uninstall cleanup accepted an identity path inside the repository" >&2
    exit 1
fi
for forbidden_identity_path in \
    "${HOME}" \
    "${repo_root}/.." \
    "${repo_root}/workspace"
do
    if bash scripts/uninstall-device-apps.sh \
        --clean-testing \
        --identities "${forbidden_identity_path}" \
        --yes >/dev/null 2>&1; then
        echo "Validation failed: uninstall cleanup accepted an identity ancestor path ${forbidden_identity_path}" >&2
        exit 1
    fi
done
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
forbidden_hits="$(find Apps Packages Tests \
    -type f -name '*.swift' \
    -exec grep -nE 'WebRTC|AVAudio|AVAsset' {} + || true)"
if [[ -n "${forbidden_hits}" ]]; then
    echo "Validation failed: a later-milestone product API or feature was added" >&2
    echo "${forbidden_hits}" >&2
    exit 1
fi
pasteboard_scope_hits="$(find Packages Tests \
    -type f -name '*.swift' \
    -exec grep -nE 'NSPasteboard' {} + || true)"
if [[ -n "${pasteboard_scope_hits}" ]]; then
    echo "Validation failed: NSPasteboard is allowed only in Apps/Host and Apps/Viewer" >&2
    echo "${pasteboard_scope_hits}" >&2
    exit 1
fi

echo "Checking required repository documents"
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
    docs/M10_ACCEPTANCE.md \
    docs/USER_GUIDE.md \
    docs/DEBUGGING.md \
    docs/DEBUG_LOG_COLLECTION.md
do
    test -s "${document}"
done

bash -n \
    scripts/run-m8-benchmark.sh \
    scripts/audit-release.sh \
    scripts/create-device-dmgs.sh \
    scripts/check-notary-profile.sh \
    scripts/install-device-apps.sh \
    scripts/run-m10-acceptance.sh \
    scripts/notarize-device-apps.sh \
    scripts/release-notarized.sh \
    scripts/validate-notarized-release.sh \
    scripts/uninstall-device-apps.sh

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
MACREMOTEAPP_RUN_M2_LOCAL_IDENTITY_SMOKE=1 \
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
validation_release_build_root="${build_root}/release-build"
validation_release_root="${build_root}/release"
MACREMOTEAPP_RELEASE_BUILD_ROOT="${validation_release_build_root}" \
MACREMOTEAPP_RELEASE_ROOT="${validation_release_root}" \
MACREMOTEAPP_SIGNING_IDENTITY=- bash scripts/package-device-apps.sh
bash scripts/audit-release.sh "${validation_release_root}"

echo "Public validation passed"
if [[ -d "${repo_root}/.build" && ! -L "${repo_root}/.build" ]]; then
    rm -rf -- "${repo_root}/.build"
    echo "Cleared successful validation build cache: ${repo_root}/.build"
fi
