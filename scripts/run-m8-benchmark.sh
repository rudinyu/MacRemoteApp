#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
build_root="${repo_root}/.build/m8-benchmark"
report_path="${MACREMOTEAPP_M8_REPORT:-${build_root}/performance-report.json}"
samples="${MACREMOTEAPP_M8_SAMPLES:-1800}"
duration_seconds="${MACREMOTEAPP_M8_DURATION_SECONDS:-30}"

mkdir -p -- "${build_root}/tmp" "$(dirname -- "${report_path}")"
export TMPDIR="${build_root}/tmp"
export CLANG_MODULE_CACHE_PATH="${build_root}/clang-module-cache"
export SWIFT_MODULECACHE_PATH="${build_root}/swift-module-cache"
mkdir -p -- "${CLANG_MODULE_CACHE_PATH}" "${SWIFT_MODULECACHE_PATH}"

cd "${repo_root}"
temporary_report="${build_root}/performance-report.json.tmp"
trap 'rm -f -- "${temporary_report}"' EXIT

echo "Running M8 deterministic benchmark harness"
set +e
swift run \
    --configuration release \
    --scratch-path "${build_root}/swiftpm" \
    M8Benchmark \
    --samples "${samples}" \
    --duration-seconds "${duration_seconds}" \
    >"${temporary_report}"
benchmark_exit=$?
set -e

test -s "${temporary_report}"
mv -- "${temporary_report}" "${report_path}"
echo "M8 sanitized report: ${report_path}"
if (( benchmark_exit != 0 )); then
    echo "M8 benchmark verdict failed; see ${report_path}" >&2
    exit "${benchmark_exit}"
fi
