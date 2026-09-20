#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 REPOSITORY_ROOT" >&2
    exit 2
fi

repo_root="$(cd -- "$1" && pwd -P)"
if ! (cd -- "${repo_root}" && git rev-parse --show-toplevel >/dev/null 2>&1); then
    echo "Unable to locate the repository Git directory: ${repo_root}" >&2
    exit 2
fi
exclude_file="$(cd -- "${repo_root}" && git rev-parse --git-path info/exclude)"
if [[ "${exclude_file}" != /* ]]; then
    exclude_file="${repo_root}/${exclude_file}"
fi

if [[ -L "${exclude_file}" || ( -e "${exclude_file}" && ! -f "${exclude_file}" ) ]]; then
    echo "Refusing to update a non-regular Git exclude file: ${exclude_file}" >&2
    exit 2
fi
mkdir -p -- "$(dirname -- "${exclude_file}")"
touch -- "${exclude_file}"

if ! grep -Fqx '/build/' "${exclude_file}"; then
    cat >> "${exclude_file}" <<'EOF'

# MacRemoteApp local build artifacts; intentionally not published to GitHub.
/build/
EOF
fi
