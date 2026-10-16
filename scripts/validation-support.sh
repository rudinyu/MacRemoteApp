#!/usr/bin/env bash

# Shared read-only environment checks and bounded cache ownership for the
# public validation entry point.

macremoteapp_validation_error() {
    printf 'Validation environment error: %s\n' "$*" >&2
}

macremoteapp_is_full_xcode() {
    local developer_dir="$1"
    [[ -d "${developer_dir}/Toolchains/XcodeDefault.xctoolchain" &&
       -x "${developer_dir}/usr/bin/xcodebuild" &&
       -x "${developer_dir}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" &&
       -x "/usr/bin/xcrun" ]]
}

macremoteapp_select_developer_dir() {
    local candidate=""
    local selected_by=""

    if [[ "${DEVELOPER_DIR+x}" == x ]]; then
        if [[ -z "${DEVELOPER_DIR}" ]]; then
            macremoteapp_validation_error "DEVELOPER_DIR is set but empty. Set it to a full Xcode Developer directory."
            return 2
        fi
        candidate="${DEVELOPER_DIR}"
        selected_by="explicit DEVELOPER_DIR"
    elif macremoteapp_is_full_xcode "/Applications/Xcode.app/Contents/Developer"; then
        candidate="/Applications/Xcode.app/Contents/Developer"
        selected_by="/Applications/Xcode.app"
    else
        candidate="$(/usr/bin/xcode-select -p 2>/dev/null)" || {
            macremoteapp_validation_error "No full Xcode was found at /Applications/Xcode.app and xcode-select has no selected developer directory."
            return 2
        }
        selected_by="xcode-select"
    fi

    case "${candidate}" in
        *$'\n'*|*$'\r'*)
            macremoteapp_validation_error "The selected developer directory contains a newline."
            return 2
            ;;
    esac

    if [[ ! -d "${candidate}" ]]; then
        macremoteapp_validation_error "${selected_by} points to a missing developer directory: ${candidate}"
        return 2
    fi
    candidate="$(cd -- "${candidate}" && pwd -P)" || {
        macremoteapp_validation_error "Unable to resolve the selected developer directory."
        return 2
    }
    if ! macremoteapp_is_full_xcode "${candidate}"; then
        macremoteapp_validation_error "${selected_by} must point to a full Xcode installation; rejected: ${candidate}"
        return 2
    fi

    DEVELOPER_DIR="${candidate}"
    MACREMOTEAPP_SELECTED_DEVELOPER_DIR="${candidate}"
    export DEVELOPER_DIR
}

macremoteapp_version_at_least() {
    local version="$1"
    local minimum_major="$2"
    local minimum_minor="$3"
    local major minor remainder

    major="${version%%.*}"
    remainder="${version#*.}"
    minor="${remainder%%.*}"
    [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ ]] || return 1
    (( major > minimum_major || (major == minimum_major && minor >= minimum_minor) ))
}

macremoteapp_check_environment() {
    local mode="${1:-full}"
    local xcode_output swift_output swift_version swift_tool
    local python_tool="" python_output="" python_version=""
    local git_revision git_status git_state architecture

    if [[ "${mode}" != full && "${mode}" != quick ]]; then
        macremoteapp_validation_error "Unknown validation mode: ${mode}"
        return 2
    fi
    macremoteapp_select_developer_dir || return $?

    xcode_output="$(/usr/bin/xcodebuild -version 2>&1)" || {
        macremoteapp_validation_error "The selected Xcode cannot run xcodebuild -version."
        return 2
    }
    MACREMOTEAPP_XCODE_VERSION="$(printf '%s\n' "${xcode_output}" | sed -n '1p')"
    MACREMOTEAPP_XCODE_BUILD="$(printf '%s\n' "${xcode_output}" | sed -n '2p')"
    if [[ -z "${MACREMOTEAPP_XCODE_VERSION}" || -z "${MACREMOTEAPP_XCODE_BUILD}" ]]; then
        macremoteapp_validation_error "The selected Xcode returned incomplete version information."
        return 2
    fi

    swift_tool="$(/usr/bin/xcrun --find swift 2>/dev/null)" || {
        macremoteapp_validation_error "The selected Xcode does not provide Swift through xcrun."
        return 2
    }
    if [[ ! -x "${swift_tool}" ]]; then
        macremoteapp_validation_error "The selected Swift compiler is not executable: ${swift_tool}"
        return 2
    fi
    swift_output="$("${swift_tool}" --version 2>&1)" || {
        macremoteapp_validation_error "The selected Swift compiler cannot report its version."
        return 2
    }
    MACREMOTEAPP_SWIFT_TOOL="${swift_tool}"
    MACREMOTEAPP_SWIFT_VERSION="$(printf '%s\n' "${swift_output}" | sed -n '1p')"
    swift_version="$(printf '%s\n' "${swift_output}" | sed -nE 's/^.*Apple Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | sed -n '1p')"
    if [[ -z "${swift_version}" ]] || ! macremoteapp_version_at_least "${swift_version}" 6 0; then
        macremoteapp_validation_error "Swift 6.0 or newer is required; selected compiler reported: ${MACREMOTEAPP_SWIFT_VERSION}"
        return 2
    fi

    if [[ "${mode}" == full ]]; then
        python_tool="$(command -v python3 2>/dev/null)" || {
            macremoteapp_validation_error "Python 3.9 or newer is required for full validation's notarization-adapter fixture."
            return 2
        }
        python_output="$("${python_tool}" --version 2>&1)" || {
            macremoteapp_validation_error "The selected Python 3 interpreter cannot report its version."
            return 2
        }
        python_version="$(printf '%s\n' "${python_output}" | sed -nE 's/^Python ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | sed -n '1p')"
        if [[ -z "${python_version}" ]] || ! macremoteapp_version_at_least "${python_version}" 3 9; then
            macremoteapp_validation_error "Python 3.9 or newer is required for full validation; selected interpreter reported: ${python_output}"
            return 2
        fi
    fi

    git_revision="$(GIT_OPTIONAL_LOCKS=0 git rev-parse --short=12 HEAD 2>/dev/null)" || {
        macremoteapp_validation_error "Unable to read the repository Git revision."
        return 2
    }
    git_status="$(GIT_OPTIONAL_LOCKS=0 git status --porcelain --untracked-files=normal 2>/dev/null)" || {
        macremoteapp_validation_error "Unable to read the repository Git worktree state."
        return 2
    }
    if [[ -n "${git_status}" ]]; then
        git_state="dirty"
    else
        git_state="clean"
    fi
    architecture="$(/usr/bin/uname -m)" || {
        macremoteapp_validation_error "Unable to read the current architecture."
        return 2
    }

    MACREMOTEAPP_XCODE_VERSION_LINE="${MACREMOTEAPP_XCODE_VERSION}"
    MACREMOTEAPP_XCODE_BUILD_LINE="${MACREMOTEAPP_XCODE_BUILD}"
    MACREMOTEAPP_SWIFT_TOOL_PATH="${MACREMOTEAPP_SWIFT_TOOL}"
    MACREMOTEAPP_SWIFT_VERSION_LINE="${MACREMOTEAPP_SWIFT_VERSION}"
    MACREMOTEAPP_PYTHON_TOOL="${python_tool}"
    MACREMOTEAPP_PYTHON_VERSION="${python_output}"
    MACREMOTEAPP_PYTHON_MINIMUM="3.9"
    MACREMOTEAPP_GIT_REVISION="${git_revision}"
    MACREMOTEAPP_GIT_STATE="${git_state}"
    MACREMOTEAPP_ARCHITECTURE="${architecture}"

    printf 'Environment check (%s mode; read-only)\n' "${mode}"
    printf 'DEVELOPER_DIR=%s\n' "${MACREMOTEAPP_SELECTED_DEVELOPER_DIR}"
    printf 'Xcode=%s; %s\n' "${MACREMOTEAPP_XCODE_VERSION_LINE}" "${MACREMOTEAPP_XCODE_BUILD_LINE}"
    printf 'Swift=%s (%s)\n' "${MACREMOTEAPP_SWIFT_TOOL_PATH}" "${MACREMOTEAPP_SWIFT_VERSION_LINE}"
    printf 'Architecture=%s\n' "${MACREMOTEAPP_ARCHITECTURE}"
    if [[ "${mode}" == full ]]; then
        printf 'Python3=%s (%s; minimum 3.9)\n' "${MACREMOTEAPP_PYTHON_TOOL}" "${MACREMOTEAPP_PYTHON_VERSION}"
    else
        printf 'Python3=not required for quick mode\n'
    fi
    printf 'Git=%s (%s)\n' "${MACREMOTEAPP_GIT_REVISION}" "${MACREMOTEAPP_GIT_STATE}"
}

macremoteapp_prepare_validation_paths() {
    local repo_root="$1"

    MACREMOTEAPP_BUILD_PARENT="${repo_root}/.build"
    MACREMOTEAPP_VALIDATION_CACHE="${MACREMOTEAPP_BUILD_PARENT}/public-validation"
    MACREMOTEAPP_VALIDATION_LOCK="${MACREMOTEAPP_BUILD_PARENT}/.public-validation.lock"

    if [[ -L "${MACREMOTEAPP_BUILD_PARENT}" ||
          ( -e "${MACREMOTEAPP_BUILD_PARENT}" && ! -d "${MACREMOTEAPP_BUILD_PARENT}" ) ]]; then
        macremoteapp_validation_error "Refusing to use an unexpected build parent path: ${MACREMOTEAPP_BUILD_PARENT}"
        return 2
    fi
    if [[ ! -d "${MACREMOTEAPP_BUILD_PARENT}" ]]; then
        mkdir -p -- "${MACREMOTEAPP_BUILD_PARENT}" || {
            macremoteapp_validation_error "Unable to create the project build parent: ${MACREMOTEAPP_BUILD_PARENT}"
            return 2
        }
    fi
    if [[ -L "${MACREMOTEAPP_BUILD_PARENT}" || ! -d "${MACREMOTEAPP_BUILD_PARENT}" ]]; then
        macremoteapp_validation_error "The build parent changed to an unexpected path: ${MACREMOTEAPP_BUILD_PARENT}"
        return 2
    fi
    if [[ -L "${MACREMOTEAPP_VALIDATION_CACHE}" ||
          ( -e "${MACREMOTEAPP_VALIDATION_CACHE}" && ! -d "${MACREMOTEAPP_VALIDATION_CACHE}" ) ]]; then
        macremoteapp_validation_error "Refusing to use an unexpected validation cache path: ${MACREMOTEAPP_VALIDATION_CACHE}"
        return 2
    fi
    if [[ -L "${MACREMOTEAPP_VALIDATION_LOCK}" ||
          ( -e "${MACREMOTEAPP_VALIDATION_LOCK}" && ! -d "${MACREMOTEAPP_VALIDATION_LOCK}" ) ]]; then
        macremoteapp_validation_error "Refusing an unexpected validation lock path: ${MACREMOTEAPP_VALIDATION_LOCK}"
        return 2
    fi
}

macremoteapp_acquire_validation_lock() {
    local lock_path="$1"
    local lock_token="${BASHPID:-$$}-$$"

    if [[ -L "${lock_path}" || ( -e "${lock_path}" && ! -d "${lock_path}" ) ]]; then
        macremoteapp_validation_error "Refusing an unexpected validation lock path: ${lock_path}"
        return 2
    fi
    if ! mkdir -- "${lock_path}" 2>/dev/null; then
        macremoteapp_validation_error "Validation cache is locked at ${lock_path}. If no validation is active, inspect and remove this leftover lock directory manually; it is never reclaimed automatically."
        return 2
    fi
    if ! printf '%s\n' "${lock_token}" >"${lock_path}/owner"; then
        rmdir -- "${lock_path}" 2>/dev/null || true
        macremoteapp_validation_error "Unable to record ownership of the validation lock."
        return 2
    fi
    MACREMOTEAPP_VALIDATION_LOCK_PATH="${lock_path}"
    MACREMOTEAPP_VALIDATION_LOCK_TOKEN="${lock_token}"
}

macremoteapp_verify_validation_lock() {
    local expected_lock="$1"
    local lock_path="${MACREMOTEAPP_VALIDATION_LOCK_PATH:-}"
    local lock_token="${MACREMOTEAPP_VALIDATION_LOCK_TOKEN:-}"
    local owner_path="${lock_path}/owner"

    if [[ "${lock_path}" != "${expected_lock}" || -z "${lock_token}" ||
          -L "${lock_path}" || ! -d "${lock_path}" ||
          -L "${owner_path}" || ! -f "${owner_path}" ]]; then
        macremoteapp_validation_error "The current process does not own the validation cache lock."
        return 1
    fi
    if [[ "$(cat -- "${owner_path}")" != "${lock_token}" ]]; then
        macremoteapp_validation_error "Validation lock ownership changed; refusing cache mutation."
        return 1
    fi
}

macremoteapp_release_validation_lock() {
    local lock_path="${MACREMOTEAPP_VALIDATION_LOCK_PATH:-}"
    local lock_token="${MACREMOTEAPP_VALIDATION_LOCK_TOKEN:-}"
    local owner_path="${lock_path}/owner"

    if [[ -z "${lock_path}" || -z "${lock_token}" ]]; then
        return 0
    fi
    macremoteapp_verify_validation_lock "${lock_path}" || return 1
    rm -- "${owner_path}" && rmdir -- "${lock_path}"
}

macremoteapp_clean_validation_cache() {
    local repo_root="$1"
    local expected_cache="${repo_root}/.build/public-validation"

    if [[ "${MACREMOTEAPP_VALIDATION_CACHE:-}" != "${expected_cache}" ]]; then
        macremoteapp_validation_error "Refusing to clean a cache path outside the public-validation directory."
        return 2
    fi
    macremoteapp_verify_validation_lock "${repo_root}/.build/.public-validation.lock" || return 2
    if [[ -L "${expected_cache}" || ( -e "${expected_cache}" && ! -d "${expected_cache}" ) ]]; then
        macremoteapp_validation_error "Refusing to clean an unexpected validation cache path: ${expected_cache}"
        return 2
    fi
    if [[ -d "${expected_cache}" ]]; then
        rm -rf -- "${expected_cache}"
    fi
}

macremoteapp_write_validation_report() {
    local report_path="$1"
    local mode="$2"
    local result="$3"
    local exit_code="$4"
    local started_at="$5"
    local completed_at="$6"
    local temporary_path="${report_path}.tmp.$$"

    if [[ -L "${report_path}" || -L "${temporary_path}" ]]; then
        macremoteapp_validation_error "Refusing to overwrite a symlink validation report."
        return 1
    fi
    {
        printf 'mode=%s\n' "${mode}"
        if [[ "${mode}" == quick ]]; then
            printf 'coverage=package graph; shell syntax and focused validation-tool fixtures; native Host and Viewer debug builds; root smoke tests\n'
            printf 'full_ci=not_run\n'
        else
            printf 'coverage=full public validation suite including architecture builds, package tests, M8/M9/M10 gates\n'
        fi
        printf 'result=%s\n' "${result}"
        printf 'exit_code=%s\n' "${exit_code}"
        printf 'started_utc=%s\n' "${started_at}"
        printf 'completed_utc=%s\n' "${completed_at}"
        printf 'git_revision=%s\n' "${MACREMOTEAPP_GIT_REVISION:-unknown}"
        printf 'git_worktree=%s\n' "${MACREMOTEAPP_GIT_STATE:-unknown}"
        printf 'architecture=%s\n' "${MACREMOTEAPP_ARCHITECTURE:-unknown}"
        printf 'developer_dir=%s\n' "${MACREMOTEAPP_SELECTED_DEVELOPER_DIR:-unknown}"
        printf 'xcode=%s; %s\n' "${MACREMOTEAPP_XCODE_VERSION_LINE:-unknown}" "${MACREMOTEAPP_XCODE_BUILD_LINE:-unknown}"
        printf 'swift=%s (%s)\n' "${MACREMOTEAPP_SWIFT_TOOL_PATH:-unknown}" "${MACREMOTEAPP_SWIFT_VERSION_LINE:-unknown}"
        if [[ "${mode}" == full ]]; then
            printf 'python3=%s (%s; minimum %s)\n' "${MACREMOTEAPP_PYTHON_TOOL:-unknown}" "${MACREMOTEAPP_PYTHON_VERSION:-unknown}" "${MACREMOTEAPP_PYTHON_MINIMUM:-3.9}"
        else
            printf 'python3=not-required\n'
        fi
    } >"${temporary_path}" || return 1
    chmod 600 "${temporary_path}"
    mv -f -- "${temporary_path}" "${report_path}"
}
