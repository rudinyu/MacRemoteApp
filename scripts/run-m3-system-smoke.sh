#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
cd "${repo_root}"

MACREMOTEAPP_RUN_M3_SYSTEM_SMOKE=1 \
swift test \
    --package-path Packages/CaptureCore \
    --configuration debug \
    --scratch-path .build/m3-system-smoke \
    --filter CaptureCoreTests/testM3SystemCaptureSmokeWhenOptedIn
