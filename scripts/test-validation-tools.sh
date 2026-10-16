#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
source "${script_dir}/validation-support.sh"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/macremoteapp-validation.XXXXXX")"
trap 'rm -rf -- "${fixture_root}"' EXIT

fail() {
    echo "Validation-tool fixture failed: $*" >&2
    exit 1
}

if DEVELOPER_DIR="${fixture_root}/missing-xcode" \
    bash "${script_dir}/check-environment.sh" --mode quick >/dev/null 2>&1; then
    fail "invalid explicit DEVELOPER_DIR was accepted"
fi

if bash "${script_dir}/validate.sh" --unknown-option >/dev/null 2>&1; then
    fail "unknown validation option was accepted"
fi
if ! bash "${script_dir}/validate.sh" --help | grep -q -- '--quick|--full'; then
    fail "validation mode help does not describe the supported modes"
fi

if [[ -f "${repo_root}/.codex/ci.sh" ]]; then
    ci_capture_dir="${fixture_root}/ci-bin"
    mkdir -p "${ci_capture_dir}"
    cat >"${ci_capture_dir}/bash" <<'MOCK_BASH'
#!/bin/sh
printf '%s\n' "$@" >"${MACREMOTEAPP_TEST_CI_ARGUMENTS}"
MOCK_BASH
    chmod 700 "${ci_capture_dir}/bash"
    ci_arguments="${fixture_root}/ci-arguments.txt"
    MACREMOTEAPP_TEST_CI_ARGUMENTS="${ci_arguments}" \
        PATH="${ci_capture_dir}:${PATH}" \
        /bin/bash "${repo_root}/.codex/ci.sh" --quick --clean
    if ! diff -u <(printf '%s\n' "${repo_root}/.codex/../scripts/validate.sh" --quick --clean) "${ci_arguments}" >/dev/null; then
        fail ".codex/ci.sh did not forward mode and clean arguments"
    fi
else
    echo "Skipping optional local .codex/ci.sh forwarding fixture: file is absent."
fi

fixture_repo="${fixture_root}/repo"
mkdir -p "${fixture_repo}/.build/public-validation" \
    "${fixture_repo}/.build/m10-debug-diagnostic" \
    "${fixture_repo}/build/debug-diagnostic"
printf 'validation cache\n' >"${fixture_repo}/.build/public-validation/sentinel"
printf 'debug cache\n' >"${fixture_repo}/.build/m10-debug-diagnostic/sentinel"
printf 'retained artifact\n' >"${fixture_repo}/build/debug-diagnostic/sentinel"

macremoteapp_prepare_validation_paths "${fixture_repo}"
macremoteapp_acquire_validation_lock "${MACREMOTEAPP_VALIDATION_LOCK}"
if macremoteapp_acquire_validation_lock "${MACREMOTEAPP_VALIDATION_LOCK}" >/dev/null 2>&1; then
    fail "a second validation owner acquired an active lock"
fi
macremoteapp_clean_validation_cache "${fixture_repo}"
[[ ! -e "${fixture_repo}/.build/public-validation" ]] || fail "--clean target was retained"
[[ -f "${fixture_repo}/.build/m10-debug-diagnostic/sentinel" ]] || fail "clean removed the diagnostic cache"
[[ -f "${fixture_repo}/build/debug-diagnostic/sentinel" ]] || fail "clean removed retained debug artifacts"
macremoteapp_release_validation_lock
[[ ! -e "${MACREMOTEAPP_VALIDATION_LOCK}" ]] || fail "validation lock was not released"

stale_lock="${fixture_repo}/.build/.public-validation.lock"
mkdir -- "${stale_lock}"
printf 'leftover lock\n' >"${stale_lock}/owner"
if macremoteapp_acquire_validation_lock "${stale_lock}" >/dev/null 2>&1; then
    fail "a pre-existing lock was reclaimed automatically"
fi
[[ -d "${stale_lock}" ]] || fail "a pre-existing lock was removed"
rm -rf -- "${stale_lock}"

symlink_repo="${fixture_root}/symlink-parent"
mkdir -p "${fixture_root}/outside-build"
mkdir -p "${symlink_repo}"
ln -s "${fixture_root}/outside-build" "${symlink_repo}/.build"
if macremoteapp_prepare_validation_paths "${symlink_repo}" >/dev/null 2>&1; then
    fail "a symlink build parent was accepted"
fi
[[ -d "${fixture_root}/outside-build" ]] || fail "symlink guard changed its target"

symlink_cache_repo="${fixture_root}/symlink-cache"
mkdir -p "${symlink_cache_repo}/.build" "${fixture_root}/outside-cache"
ln -s "${fixture_root}/outside-cache" "${symlink_cache_repo}/.build/public-validation"
if macremoteapp_prepare_validation_paths "${symlink_cache_repo}" >/dev/null 2>&1; then
    fail "a symlink validation cache was accepted"
fi
[[ -d "${fixture_root}/outside-cache" ]] || fail "cache symlink guard changed its target"

echo "Validation-tool fixtures passed"
