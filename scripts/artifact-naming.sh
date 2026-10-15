#!/usr/bin/env bash

# Shared, fail-closed product version and distribution-name handling.
# Source this file from packaging, notarization, audit, and validation scripts.

macremoteapp_validate_artifact_channel() {
    case "${1:-}" in
        testing|debug-diagnostic|beta|rc|release)
            return 0
            ;;
        *)
            echo "Invalid MacRemoteApp artifact channel" >&2
            return 1
            ;;
    esac
}

macremoteapp_resolve_artifact_channel() {
    local repo_root="$1"
    local release_root="$2"
    local artifact_channel
    local canonical_channel=""
    local is_staging_root=0
    local is_build_scratch=0
    local is_debug_diagnostic_scratch=0

    case "${release_root}" in
        "${repo_root}/build/testing") canonical_channel="testing" ;;
        "${repo_root}/build/debug-diagnostic") canonical_channel="debug-diagnostic" ;;
        "${repo_root}/build/beta") canonical_channel="beta" ;;
        "${repo_root}/build/rc") canonical_channel="rc" ;;
        "${repo_root}/build/release") canonical_channel="release" ;;
        "${repo_root}/build/MacRemoteApp-"*.staging.*) is_staging_root=1 ;;
        "${repo_root}/.build/m10-debug-diagnostic"|"${repo_root}/.build/m10-debug-diagnostic/"*)
            canonical_channel="debug-diagnostic"
            is_debug_diagnostic_scratch=1
            ;;
        "${repo_root}/.build"|"${repo_root}/.build/"*)
            canonical_channel="testing"
            is_build_scratch=1
            ;;
    esac

    if [[ "${MACREMOTEAPP_ARTIFACT_CHANNEL+x}" == "x" ]]; then
        artifact_channel="${MACREMOTEAPP_ARTIFACT_CHANNEL}"
        macremoteapp_validate_artifact_channel "${artifact_channel}" || return 1
        if [[ -n "${canonical_channel}" && "${artifact_channel}" != "${canonical_channel}" ]]; then
            echo "Artifact channel conflicts with the selected release root" >&2
            return 1
        fi
        if (( is_build_scratch )) && [[ "${artifact_channel}" != "testing" ]]; then
            echo "Repository .build outputs must use the testing artifact channel" >&2
            return 1
        fi
    else
        if (( is_debug_diagnostic_scratch )); then
            echo "M10 Debug diagnostic staging outputs require an explicit artifact channel" >&2
            return 1
        fi
        if (( is_staging_root )); then
            echo "Controlled staging outputs require an explicit artifact channel" >&2
            return 1
        fi
        artifact_channel="${canonical_channel:-testing}"
    fi

    macremoteapp_validate_artifact_channel "${artifact_channel}" || return 1
    printf '%s\n' "${artifact_channel}"
}

macremoteapp_require_release_channel() {
    case "${1:-}" in
        testing|beta|rc|release)
            return 0
            ;;
        debug-diagnostic)
            echo "The M10 Debug diagnostic channel is not eligible for M9 release validation or promotion" >&2
            return 1
            ;;
        *)
            echo "Invalid MacRemoteApp release channel" >&2
            return 1
            ;;
    esac
}

macremoteapp_read_plist_string() {
    local plist_path="$1"
    local key="$2"
    local role="$3"
    local plist_type
    local value_file
    local linefeed_count
    local value

    if [[ -L "${plist_path}" || ! -f "${plist_path}" ]]; then
        echo "Invalid ${role} release metadata file" >&2
        return 1
    fi

    plist_type="$(/usr/bin/plutil -type "${key}" "${plist_path}" 2>/dev/null)" || {
        echo "Missing ${key} in ${role} release metadata" >&2
        return 1
    }
    if [[ "${plist_type}" != "string" ]]; then
        echo "${key} must be a string in ${role} release metadata" >&2
        return 1
    fi

    value_file="$(mktemp "${TMPDIR:-/private/tmp}/macremoteapp-release-value.XXXXXX" 2>/dev/null)" || {
        value_file="$(mktemp "/private/tmp/macremoteapp-release-value.XXXXXX" 2>/dev/null)" || {
            echo "Unable to read ${role} release metadata" >&2
            return 1
        }
    }
    if ! /usr/bin/plutil -extract "${key}" raw -n "${plist_path}" >"${value_file}" 2>/dev/null; then
        rm -f -- "${value_file}"
        echo "Unable to read ${key} in ${role} release metadata" >&2
        return 1
    fi

    linefeed_count="$(LC_ALL=C /usr/bin/tr -cd '\n' <"${value_file}" | LC_ALL=C /usr/bin/wc -c | LC_ALL=C /usr/bin/tr -d '[:space:]')" || {
        rm -f -- "${value_file}"
        echo "Unable to validate ${key} in ${role} release metadata" >&2
        return 1
    }
    if [[ "${linefeed_count}" != "0" ]]; then
        rm -f -- "${value_file}"
        echo "${key} contains a line break in ${role} release metadata" >&2
        return 1
    fi

    value="$(<"${value_file}")"
    rm -f -- "${value_file}"
    printf '%s\n' "${value}"
}

macremoteapp_validate_release_identity() {
    [[ "${1:-}" =~ ^[0123456789]+[.][0123456789]+[.][0123456789]+$ ]]
}

macremoteapp_release_identity() {
    local host_plist="$1"
    local viewer_plist="$2"
    local host_short_version
    local host_build
    local viewer_short_version
    local viewer_build

    host_short_version="$(macremoteapp_read_plist_string "${host_plist}" CFBundleShortVersionString Host)" || return 1
    host_build="$(macremoteapp_read_plist_string "${host_plist}" CFBundleVersion Host)" || return 1
    viewer_short_version="$(macremoteapp_read_plist_string "${viewer_plist}" CFBundleShortVersionString Viewer)" || return 1
    viewer_build="$(macremoteapp_read_plist_string "${viewer_plist}" CFBundleVersion Viewer)" || return 1

    if [[ ! "${host_short_version}" =~ ^[0123456789]+[.][0123456789]+$ ]]; then
        echo "Host CFBundleShortVersionString must be numeric major.minor" >&2
        return 1
    fi
    if [[ ! "${host_build}" =~ ^[0123456789]+$ ]]; then
        echo "Host CFBundleVersion must be numeric" >&2
        return 1
    fi
    if [[ ! "${viewer_short_version}" =~ ^[0123456789]+[.][0123456789]+$ ]]; then
        echo "Viewer CFBundleShortVersionString must be numeric major.minor" >&2
        return 1
    fi
    if [[ ! "${viewer_build}" =~ ^[0123456789]+$ ]]; then
        echo "Viewer CFBundleVersion must be numeric" >&2
        return 1
    fi
    if [[ "${host_short_version}" != "${viewer_short_version}" ||
          "${host_build}" != "${viewer_build}" ]]; then
        echo "Host and Viewer release metadata must match" >&2
        return 1
    fi

    printf '%s.%s\n' "${host_short_version}" "${host_build}"
}

macremoteapp_expected_distribution_name() {
    local artifact_channel="$1"
    local release_identity="$2"
    local app_name="$3"
    local artifact_kind="$4"
    local extension

    macremoteapp_validate_artifact_channel "${artifact_channel}" || return 1
    if ! macremoteapp_validate_release_identity "${release_identity}"; then
        echo "Invalid MacRemoteApp release identity" >&2
        return 1
    fi
    case "${app_name}" in
        MacRemoteApp-Host|MacRemoteApp-Viewer)
            ;;
        *)
            echo "Invalid MacRemoteApp app role for distribution naming" >&2
            return 1
            ;;
    esac
    case "${artifact_kind}" in
        dmg) extension="dmg" ;;
        app-zip) extension="app.zip" ;;
        *)
            echo "Invalid MacRemoteApp distribution artifact kind" >&2
            return 1
            ;;
    esac

    if [[ "${artifact_channel}" == "release" ]]; then
        printf '%s.%s\n' "${app_name}" "${extension}"
    elif [[ "${artifact_channel}" == "debug-diagnostic" ]]; then
        printf '%s-debug-diagnostic-%s.%s\n' "${app_name}" "${release_identity}" "${extension}"
    else
        printf '%s-%s.%s\n' "${app_name}" "${release_identity}" "${extension}"
    fi
}
