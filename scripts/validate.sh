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
    scripts/dmg-install.sh \
    scripts/dmg-uninstall.sh \
    scripts/install-device-apps.sh \
    scripts/package-device-apps.sh \
    scripts/notarize-device-apps.sh \
    scripts/release-notarized.sh \
    scripts/uninstall-device-apps.sh
if ! bash scripts/install-device-apps.sh --help | grep -Eq -- '--allow-ad-hoc'; then
    echo "Validation failed: installer does not expose explicit ad-hoc opt-in" >&2
    exit 1
fi
installer_probe_dir="$(mktemp -d "${TMPDIR}/installer-no-args.XXXXXX")"
installer_probe_output="${installer_probe_dir}/output.txt"
if MACREMOTEAPP_RELEASE_ROOT="${installer_probe_dir}/missing-release" \
    MACREMOTEAPP_INSTALL_DIR="${installer_probe_dir}/Applications" \
    bash scripts/install-device-apps.sh >"${installer_probe_output}" 2>&1; then
    rm -rf -- "${installer_probe_dir}"
    echo "Validation failed: installer unexpectedly succeeded without a release source" >&2
    exit 1
fi
if grep -q 'unbound variable' "${installer_probe_output}"; then
    rm -rf -- "${installer_probe_dir}"
    echo "Validation failed: installer no-argument launch hit an unbound-variable error" >&2
    exit 1
fi
rm -rf -- "${installer_probe_dir}"
make_valid_probe_app() {
    local app_dir="$1"
    local info_plist="$2"
    local executable_name="$3"
    mkdir -p "${app_dir}/Contents/MacOS"
    cp "${info_plist}" "${app_dir}/Contents/Info.plist"
    : >"${app_dir}/Contents/MacOS/${executable_name}"
    chmod 755 "${app_dir}/Contents/MacOS/${executable_name}"
    codesign --force --sign - --timestamp=none "${app_dir}" >/dev/null
}
if grep -Eq -- '--(role|source|destination|replace|require-developer-id|allow-ad-hoc|clean-testing)([[:space:]]|=|$)|MACREMOTEAPP_(RELEASE_ROOT|INSTALL_DIR|RELEASE_BUILD_ROOT)|tccutil|clear-testing-keychain|\.build' \
    scripts/dmg-install.sh scripts/dmg-uninstall.sh; then
    echo "Validation failed: DMG user scripts expose repository or CI controls" >&2
    exit 1
fi
if ! test -x scripts/dmg-install.sh || ! test -x scripts/dmg-uninstall.sh; then
    echo "Validation failed: DMG user scripts must be executable" >&2
    exit 1
fi
dmg_script_probe_dir="$(mktemp -d "${TMPDIR}/dmg-script-options.XXXXXX")"
dmg_install_probe="${dmg_script_probe_dir}/Install-MacRemoteApp-Viewer.command"
cp scripts/dmg-install.sh "${dmg_install_probe}"
chmod 755 "${dmg_install_probe}"
if "${dmg_install_probe}" --help >/dev/null 2>&1; then
    rm -rf -- "${dmg_script_probe_dir}"
    echo "Validation failed: DMG installer accepted command-line options" >&2
    exit 1
fi
rm -rf -- "${dmg_script_probe_dir}"

uninstaller_probe_home="$(mktemp -d "${TMPDIR}/uninstaller-command.XXXXXX")"
uninstaller_app_dir="${uninstaller_probe_home}/Applications"
make_valid_probe_app \
    "${uninstaller_app_dir}/MacRemoteApp-Viewer.app" \
    Resources/Viewer-Info.plist \
    MacRemoteApp-Viewer
uninstaller_command="${uninstaller_probe_home}/Uninstall-MacRemoteApp-Viewer.command"
cp scripts/dmg-uninstall.sh "${uninstaller_command}"
chmod 755 "${uninstaller_command}"
if HOME="${uninstaller_probe_home}" "${uninstaller_command}" <<< "y" >/dev/null 2>&1; then
    rm -rf -- "${uninstaller_probe_home}"
    echo "Validation failed: DMG-style Viewer uninstaller accepted an ad-hoc app" >&2
    exit 1
fi
if [[ ! -d "${uninstaller_app_dir}/MacRemoteApp-Viewer.app" ]]; then
    rm -rf -- "${uninstaller_probe_home}"
    echo "Validation failed: ad-hoc rejection changed the Viewer app bundle" >&2
    exit 1
fi
rm -rf -- "${uninstaller_probe_home}"
host_uninstaller_probe_home="$(mktemp -d "${TMPDIR}/uninstaller-host-command.XXXXXX")"
host_uninstaller_app_dir="${host_uninstaller_probe_home}/Applications"
make_valid_probe_app \
    "${host_uninstaller_app_dir}/MacRemoteApp-Host.app" \
    Resources/Host-Info.plist \
    MacRemoteApp-Host
host_uninstaller_command="${host_uninstaller_probe_home}/Uninstall-MacRemoteApp-Host.command"
cp scripts/dmg-uninstall.sh "${host_uninstaller_command}"
chmod 755 "${host_uninstaller_command}"
if HOME="${host_uninstaller_probe_home}" "${host_uninstaller_command}" <<< "y" >/dev/null 2>&1; then
    rm -rf -- "${host_uninstaller_probe_home}"
    echo "Validation failed: DMG-style Host uninstaller accepted an ad-hoc app" >&2
    exit 1
fi
if [[ ! -d "${host_uninstaller_app_dir}/MacRemoteApp-Host.app" ]]; then
    rm -rf -- "${host_uninstaller_probe_home}"
    echo "Validation failed: ad-hoc rejection changed the Host app bundle" >&2
    exit 1
fi
rm -rf -- "${host_uninstaller_probe_home}"
invalid_bundle_probe_home="$(mktemp -d "${TMPDIR}/uninstaller-invalid-bundle.XXXXXX")"
invalid_bundle_app_dir="${invalid_bundle_probe_home}/Applications"
invalid_bundle_command="${invalid_bundle_probe_home}/Uninstall-MacRemoteApp-Viewer.command"
make_valid_probe_app \
    "${invalid_bundle_app_dir}/MacRemoteApp-Viewer.app" \
    Resources/Host-Info.plist \
    MacRemoteApp-Host
cp scripts/dmg-uninstall.sh "${invalid_bundle_command}"
chmod 755 "${invalid_bundle_command}"
if HOME="${invalid_bundle_probe_home}" "${invalid_bundle_command}" <<< "y" >/dev/null 2>&1; then
    rm -rf -- "${invalid_bundle_probe_home}"
    echo "Validation failed: uninstaller accepted a bundle with the wrong identity" >&2
    exit 1
fi
if [[ ! -d "${invalid_bundle_app_dir}/MacRemoteApp-Viewer.app" ]]; then
    rm -rf -- "${invalid_bundle_probe_home}"
    echo "Validation failed: identity mismatch probe removed the app bundle" >&2
    exit 1
fi
rm -rf -- "${invalid_bundle_probe_home}"
symlink_uninstaller_probe_home="$(mktemp -d "${TMPDIR}/uninstaller-symlink.XXXXXX")"
symlink_uninstaller_app_dir="${symlink_uninstaller_probe_home}/Applications"
symlink_uninstaller_command="${symlink_uninstaller_probe_home}/Uninstall-MacRemoteApp-Viewer.command"
mkdir -p "${symlink_uninstaller_app_dir}"
ln -s "${symlink_uninstaller_probe_home}/outside" \
    "${symlink_uninstaller_app_dir}/MacRemoteApp-Viewer.app"
cp scripts/dmg-uninstall.sh "${symlink_uninstaller_command}"
chmod 755 "${symlink_uninstaller_command}"
if HOME="${symlink_uninstaller_probe_home}" "${symlink_uninstaller_command}" <<< "y" >/dev/null 2>&1; then
    rm -rf -- "${symlink_uninstaller_probe_home}"
    echo "Validation failed: DMG-style uninstall command accepted an app symlink" >&2
    exit 1
fi
if [[ ! -L "${symlink_uninstaller_app_dir}/MacRemoteApp-Viewer.app" ]]; then
    rm -rf -- "${symlink_uninstaller_probe_home}"
    echo "Validation failed: symlink fail-closed probe changed its target" >&2
    exit 1
fi
rm -rf -- "${symlink_uninstaller_probe_home}"
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
host_listener_line="$(grep -n 'let listener = try NetworkBonjourListener' Apps/Host/HostRuntime.swift | head -1 | cut -d: -f1)"
host_permission_line="$(grep -n 'try await prepareScreenRecordingPermission()' Apps/Host/HostRuntime.swift | head -1 | cut -d: -f1)"
if [[ -z "${host_listener_line}" || -z "${host_permission_line}" ||
      "${host_permission_line}" -ge "${host_listener_line}" ]]; then
    echo "Validation failed: Host must complete the Screen Recording setup before constructing the Bonjour listener" >&2
    exit 1
fi
if ! grep -q 'NSApplication.shared.activate(ignoringOtherApps: true)' Apps/Host/main.swift; then
    echo "Validation failed: Host startup does not activate the signed app before TCC requests" >&2
    exit 1
fi
if ! grep -q 'listener.stateUpdateHandler' Packages/TransportCore/Sources/TransportCore/BonjourDiscovery.swift ||
   ! grep -q 'startAndWaitForReadiness' Packages/TransportCore/Sources/TransportCore/BonjourDiscovery.swift ||
   ! grep -q 'serviceRegistrationUpdateHandler' Packages/TransportCore/Sources/TransportCore/BonjourDiscovery.swift ||
   ! grep -q 'serviceRegistered' Packages/TransportCore/Sources/TransportCore/BonjourDiscovery.swift ||
   ! grep -q 'case .failed' Packages/TransportCore/Sources/TransportCore/BonjourDiscovery.swift ||
   ! grep -q 'try await listener.startAndWaitForReadiness()' Apps/Host/HostRuntime.swift; then
    echo "Validation failed: Host Bonjour startup does not await socket and service-registration readiness" >&2
    exit 1
fi
if ! grep -q 'func requestRetry()' Apps/Host/HostRuntime.swift ||
   ! grep -q 'private func waitForRetry()' Apps/Host/HostRuntime.swift ||
   ! grep -q 'Retry setup' Apps/Host/main.swift; then
    echo "Validation failed: Host permission/listener failures are not recoverable from the resident app" >&2
    exit 1
fi
if ! grep -q 'onHostSelection' Apps/Viewer/ViewerRuntime.swift ||
   ! grep -q 'setHostOptions' Apps/Viewer/ViewerRuntime.swift ||
   grep -q 'services.first(where:' Apps/Viewer/ViewerRuntime.swift; then
    echo "Validation failed: Viewer must require explicit Host selection" >&2
    exit 1
fi
if ! grep -q 'addPresentedHandler' Apps/Viewer/MetalVideoRenderer.swift ||
   ! grep -q 'presentedTime' Apps/Viewer/MetalVideoRenderer.swift ||
   ! grep -q 'DispatchTime.now().uptimeNanoseconds' Packages/CaptureCore/Sources/CaptureCore/ScreenCaptureEngine.swift; then
    echo "Validation failed: physical presentation timing is not wired to the display boundary" >&2
    exit 1
fi
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
test "$(/usr/libexec/PlistBuddy -c 'Print :NSBonjourServices:0' "${validation_release_root}/MacRemoteApp-Host.app/Contents/Info.plist" 2>/dev/null)" = "_macremote._tcp"
test "$(/usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' "${validation_release_root}/MacRemoteApp-Host.app/Contents/Info.plist" 2>/dev/null)" != ""
test "$(/usr/libexec/PlistBuddy -c 'Print :NSScreenCaptureUsageDescription' "${validation_release_root}/MacRemoteApp-Host.app/Contents/Info.plist" 2>/dev/null)" != ""
test "$(/usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' "${validation_release_root}/MacRemoteApp-Viewer.app/Contents/Info.plist" 2>/dev/null)" != ""

echo "Public validation passed"
if [[ -d "${repo_root}/.build" && ! -L "${repo_root}/.build" ]]; then
    rm -rf -- "${repo_root}/.build"
    echo "Cleared successful validation build cache: ${repo_root}/.build"
fi
