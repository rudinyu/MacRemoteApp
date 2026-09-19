#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
role="${1:-deterministic}"
build_root="${repo_root}/.build/m10-acceptance"

mkdir -p -- "${build_root}/tmp"
export TMPDIR="${build_root}/tmp"
export CLANG_MODULE_CACHE_PATH="${build_root}/clang-module-cache"
export SWIFT_MODULECACHE_PATH="${build_root}/swift-module-cache"
mkdir -p -- "${CLANG_MODULE_CACHE_PATH}" "${SWIFT_MODULECACHE_PATH}"
cd "${repo_root}"

case "${role}" in
    deterministic)
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
        deterministic_release_build_root="${build_root}/release-build"
        deterministic_release_root="${build_root}/release"
        MACREMOTEAPP_RELEASE_BUILD_ROOT="${deterministic_release_build_root}" \
        MACREMOTEAPP_RELEASE_ROOT="${deterministic_release_root}" \
        MACREMOTEAPP_SIGNING_IDENTITY=- bash scripts/package-device-apps.sh
        bash scripts/audit-release.sh "${deterministic_release_root}"
        swift test \
            --configuration debug \
            --scratch-path "${build_root}/root-tests"
        for package_dir in \
            Packages/RemoteProtocol \
            Packages/CaptureCore \
            Packages/CodecCore \
            Packages/TransportCore \
            Packages/InputCore \
            Packages/SecurityCore; do
            package_name="$(basename -- "${package_dir}")"
            swift test \
                --package-path "${package_dir}" \
                --configuration debug \
                --scratch-path "${build_root}/package-${package_name}"
        done
        echo "M10 deterministic gate passed; physical two-machine acceptance remains required."
        ;;
    host)
        : "${MACREMOTEAPP_LOCAL_IDENTITY_P12:?set MACREMOTEAPP_LOCAL_IDENTITY_P12 to the Host PKCS#12 path}"
        : "${MACREMOTEAPP_PEER_CERT:?set MACREMOTEAPP_PEER_CERT to the Viewer certificate path}"
        : "${MACREMOTEAPP_P12_PASSWORD:?set MACREMOTEAPP_P12_PASSWORD without committing it}"
        swift run \
            --configuration debug \
            --scratch-path "${build_root}/host-swiftpm" \
            Host \
            --m2-physical-host
        ;;
    host-clipboard)
        : "${MACREMOTEAPP_LOCAL_IDENTITY_P12:?set MACREMOTEAPP_LOCAL_IDENTITY_P12 to the Host PKCS#12 path}"
        : "${MACREMOTEAPP_PEER_CERT:?set MACREMOTEAPP_PEER_CERT to the Viewer certificate path}"
        : "${MACREMOTEAPP_P12_PASSWORD:?set MACREMOTEAPP_P12_PASSWORD without committing it}"
        swift run \
            --configuration debug \
            --scratch-path "${build_root}/host-clipboard-swiftpm" \
            Host \
            --m7-physical-host
        ;;
    viewer)
        : "${MACREMOTEAPP_LOCAL_IDENTITY_P12:?set MACREMOTEAPP_LOCAL_IDENTITY_P12 to the Viewer PKCS#12 path}"
        : "${MACREMOTEAPP_PEER_CERT:?set MACREMOTEAPP_PEER_CERT to the Host certificate path}"
        : "${MACREMOTEAPP_P12_PASSWORD:?set MACREMOTEAPP_P12_PASSWORD without committing it}"
        swift run \
            --configuration debug \
            --scratch-path "${build_root}/viewer-swiftpm" \
            Viewer \
            --m2-physical-viewer
        ;;
    viewer-clipboard)
        : "${MACREMOTEAPP_LOCAL_IDENTITY_P12:?set MACREMOTEAPP_LOCAL_IDENTITY_P12 to the Viewer PKCS#12 path}"
        : "${MACREMOTEAPP_PEER_CERT:?set MACREMOTEAPP_PEER_CERT to the Host certificate path}"
        : "${MACREMOTEAPP_P12_PASSWORD:?set MACREMOTEAPP_P12_PASSWORD without committing it}"
        swift run \
            --configuration debug \
            --scratch-path "${build_root}/viewer-clipboard-swiftpm" \
            Viewer \
            --m7-physical-viewer
        ;;
    *)
        echo "usage: $0 deterministic|host|viewer|host-clipboard|viewer-clipboard" >&2
        exit 2
        ;;
esac
