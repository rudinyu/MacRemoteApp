#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
source "${script_dir}/artifact-naming.sh"

fail() {
    echo "M10 Debug diagnostic promotion failed: $*" >&2
    exit 2
}

promotion_stage_root=""
promotion_release_root=""
promotion_backup_root=""
promotion_was_promoted=0
cleanup_promotion() {
    local status=$?
    if (( status != 0 )); then
        if (( promotion_was_promoted )) &&
           [[ -e "${promotion_release_root}" && ! -e "${promotion_stage_root}" ]]; then
            if ! mv -- "${promotion_release_root}" "${promotion_stage_root}"; then
                echo "Failed promotion remains at ${promotion_release_root}; staged path is ${promotion_stage_root}" >&2
            fi
        fi
        if [[ -n "${promotion_backup_root}" &&
              -e "${promotion_backup_root}" &&
              ! -e "${promotion_release_root}" ]]; then
            if mv -- "${promotion_backup_root}" "${promotion_release_root}"; then
                echo "Restored the previous Debug diagnostic artifacts after promotion failure." >&2
            else
                echo "Previous Debug diagnostic artifacts remain at ${promotion_backup_root}" >&2
            fi
        fi
    fi
    exit "${status}"
}

main() {
    if (( $# != 1 )); then
        echo "Usage: bash scripts/promote-debug-diagnostic-apps.sh .build/m10-debug-diagnostic/generation.ID/artifacts" >&2
        return 2
    fi

    local stage_root="$1"
    if [[ "${stage_root}" != /* ]]; then
        stage_root="${repo_root}/${stage_root}"
    fi
    if [[ -L "${stage_root}" || ! -d "${stage_root}" ]]; then
        fail "the staged artifacts must be a regular directory"
    fi
    stage_root="$(cd -P -- "${stage_root}" && pwd -P)"
    local generation_root="${stage_root%/artifacts}"
    local generation_name="${generation_root##*/}"
    local generation_parent="${generation_root%/*}"
    [[ "${stage_root}" == */artifacts &&
       "${generation_parent}" == "${repo_root}/.build/m10-debug-diagnostic" &&
       "${generation_name}" == generation.* &&
       "${generation_name#generation.}" =~ ^[A-Za-z0-9]+$ ]] ||
        fail "only an exact M10 Debug generation may be promoted"

    if [[ "${MACREMOTEAPP_ARTIFACT_CHANNEL:-debug-diagnostic}" != "debug-diagnostic" ]]; then
        fail "MACREMOTEAPP_ARTIFACT_CHANNEL must be debug-diagnostic"
    fi
    export MACREMOTEAPP_ARTIFACT_CHANNEL=debug-diagnostic
    local resolved_channel
    resolved_channel="$(macremoteapp_resolve_artifact_channel "${repo_root}" "${stage_root}")" || return 2
    [[ "${resolved_channel}" == debug-diagnostic ]] || fail "unexpected artifact channel ${resolved_channel}"

    local artifact_root="${repo_root}/build"
    local release_root="${artifact_root}/debug-diagnostic"
    local build_root="${repo_root}/.build/m10-debug-diagnostic"
    local lock_path="${build_root}/.promotion.lock"
    local candidate=""
    local recovery_count=0
    local device_stage=""
    local device_artifact=""

    MACREMOTEAPP_ARTIFACT_CHANNEL=debug-diagnostic \
        bash "${script_dir}/audit-debug-diagnostic-apps.sh" "${stage_root}" ||
        fail "staged artifacts did not pass the M10 Debug audit"

    if [[ -L "${build_root}" || ! -d "${build_root}" ]]; then
        fail "the M10 Debug staging root must be a regular directory"
    fi
    if [[ -L "${lock_path}" || ( -e "${lock_path}" && ! -f "${lock_path}" ) ]]; then
        fail "refusing an unexpected promotion lock type"
    fi
    if [[ -L "${artifact_root}" || ( -e "${artifact_root}" && ! -d "${artifact_root}" ) ]]; then
        fail "refusing a symlink or non-directory artifact root"
    fi
    mkdir -p -- "${artifact_root}"
    if [[ -L "${lock_path}" || ( -e "${lock_path}" && ! -f "${lock_path}" ) ]]; then
        fail "refusing an unexpected promotion lock type"
    fi
    device_stage="$(stat -f '%d' "${generation_parent}")" || fail "unable to inspect staging volume"
    device_artifact="$(stat -f '%d' "${artifact_root}")" || fail "unable to inspect artifact volume"
    [[ "${device_stage}" == "${device_artifact}" ]] ||
        fail "staging and artifact directories must be on the same filesystem for atomic promotion"

    local previous_candidates=()
    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        previous_candidates+=("${candidate}")
        recovery_count=$((recovery_count + 1))
    done < <(find "${artifact_root}" -mindepth 1 -maxdepth 1 \
        -name 'MacRemoteApp-debug-diagnostic.previous.*' -print)
    if (( recovery_count > 1 )); then
        printf 'Interrupted Debug diagnostic promotions need manual recovery:\n' >&2
        printf '  %s\n' "${previous_candidates[@]}" >&2
        fail "multiple previous-channel backups exist"
    fi
    if (( recovery_count == 1 )); then
        candidate="${previous_candidates[0]}"
        if [[ -L "${candidate}" || ! -d "${candidate}" ]]; then
            fail "an interrupted-promotion backup has an unexpected type: ${candidate}"
        fi
        if [[ ! -e "${release_root}" ]]; then
            mv -- "${candidate}" "${release_root}" || fail "unable to restore interrupted-promotion backup"
        else
            if [[ -L "${release_root}" || ! -d "${release_root}" ]]; then
                fail "refusing recovery over an unexpected artifact path"
            fi
            MACREMOTEAPP_ARTIFACT_CHANNEL=debug-diagnostic \
                bash "${script_dir}/audit-debug-diagnostic-apps.sh" "${release_root}" ||
                fail "current artifacts failed audit while a prior backup exists; both generations were preserved"
            rm -rf -- "${candidate}"
        fi
    fi

    promotion_stage_root="${stage_root}"
    promotion_release_root="${release_root}"
    promotion_backup_root=""
    promotion_was_promoted=0
    trap cleanup_promotion EXIT

    if [[ -e "${release_root}" || -L "${release_root}" ]]; then
        if [[ -L "${release_root}" || ! -d "${release_root}" ]]; then
            fail "refusing to replace a symlink or non-directory artifact path"
        fi
        promotion_backup_root="$(mktemp -d "${artifact_root}/MacRemoteApp-debug-diagnostic.previous.XXXXXX")"
        rmdir -- "${promotion_backup_root}"
        mv -- "${release_root}" "${promotion_backup_root}" || fail "unable to preserve existing Debug diagnostic artifacts"
    fi

    mv -- "${stage_root}" "${release_root}" || fail "unable to atomically promote staged artifacts"
    promotion_was_promoted=1
    MACREMOTEAPP_ARTIFACT_CHANNEL=debug-diagnostic \
        bash "${script_dir}/audit-debug-diagnostic-apps.sh" "${release_root}" ||
        fail "promoted artifacts did not pass the final M10 Debug audit"

    # The new generation is now valid. Cleanup failures must not trigger the
    # EXIT rollback path or replace the valid output with a partial backup.
    promotion_was_promoted=0
    if [[ -n "${promotion_backup_root}" && -d "${promotion_backup_root}" && ! -L "${promotion_backup_root}" ]]; then
        if rm -rf -- "${promotion_backup_root}"; then
            promotion_backup_root=""
        else
            echo "Validated Debug diagnostic artifacts remain promoted; previous artifacts need manual cleanup at ${promotion_backup_root}" >&2
        fi
    fi
    trap - EXIT
    echo "Promoted audited M10 Debug diagnostic artifacts into ${release_root}"
}

if [[ "${1:-}" == "--locked-worker" ]]; then
    shift
    main "$@"
    exit $?
fi

if (( $# != 1 )); then
    echo "Usage: bash scripts/promote-debug-diagnostic-apps.sh .build/m10-debug-diagnostic/generation.ID/artifacts" >&2
    exit 2
fi
command -v lockf >/dev/null 2>&1 || fail "the macOS lockf utility is required for serialized promotion"
artifact_root="${repo_root}/build"
stage_root="$1"
if [[ "${stage_root}" != /* ]]; then
    stage_root="${repo_root}/${stage_root}"
fi
if [[ -L "${stage_root}" || ! -d "${stage_root}" ]]; then
    fail "the staged artifacts must be a regular directory"
fi
stage_root="$(cd -P -- "${stage_root}" && pwd -P)"
generation_root="${stage_root%/artifacts}"
generation_name="${generation_root##*/}"
generation_parent="${generation_root%/*}"
build_root="${repo_root}/.build/m10-debug-diagnostic"
if [[ "${stage_root}" != */artifacts ||
      "${generation_parent}" != "${build_root}" ||
      "${generation_name}" != generation.* ||
      ! "${generation_name#generation.}" =~ ^[A-Za-z0-9]+$ ]]; then
    fail "only an exact M10 Debug generation may be promoted"
fi
if [[ -L "${build_root}" || ! -d "${build_root}" ]]; then
    fail "the M10 Debug staging root must be a regular directory"
fi
lock_path="${build_root}/.promotion.lock"
if [[ -L "${lock_path}" || ( -e "${lock_path}" && ! -f "${lock_path}" ) ]]; then
    fail "refusing an unexpected promotion lock type"
fi
script_path="${BASH_SOURCE[0]}"
if [[ "${script_path}" != /* ]]; then
    script_path="${repo_root}/${script_path#./}"
fi
if lockf -t 0 "${lock_path}" bash "${script_path}" --locked-worker "$1"; then
    exit 0
else
    status=$?
    if (( status == 75 )); then
        fail "another M10 Debug diagnostic promotion is already running"
    fi
    exit "${status}"
fi
