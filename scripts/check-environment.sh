#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
source "${script_dir}/validation-support.sh"

mode="full"
while (( $# > 0 )); do
    case "$1" in
        --mode)
            if (( $# < 2 )); then
                echo "Usage: bash scripts/check-environment.sh [--mode full|quick]" >&2
                exit 2
            fi
            mode="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: bash scripts/check-environment.sh [--mode full|quick]"
            echo "Read-only check of the selected full Xcode, Swift, architecture, Git state, and Python when full validation needs it."
            exit 0
            ;;
        *)
            echo "Usage: bash scripts/check-environment.sh [--mode full|quick]" >&2
            exit 2
            ;;
    esac
done

cd -- "${repo_root}"
macremoteapp_check_environment "${mode}"
