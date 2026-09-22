#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"

usage() {
    cat <<'EOF'
Usage: bash scripts/uninstall-device-apps.sh [options]

Remove the exact MacRemoteApp Host and/or Viewer app bundle from
~/Applications by default. Keychain trust records and macOS permissions are
not removed unless --clean-testing is explicitly supplied.

Options:
  --role host|viewer|both       Remove one role or both (default: inferred/both)
  --destination DIRECTORY       Application directory to inspect
  --clean-testing               Also remove build/testing and .build, reset
                                Host Screen Recording/Accessibility and
                                Host/Viewer Local Network TCC grants, remove
                                the app's trust/device identity Keychain items;
                                imported M2 identities are removed only when
                                --identities is supplied
  --identities DIRECTORY        Dedicated external MacRemoteApp-identities
                                directory containing generated M2 files;
                                requires --clean-testing; when only the local
                                .p12 and opposite .cer are present, set
                                MACREMOTEAPP_P12_PASSWORD to fingerprint the
                                local identity without printing the password
  --dry-run                     Show the selected cleanup without changing state
  --yes                         Skip the confirmation prompt
  --help                        Show this help
EOF
}

infer_role() {
    case "$(basename -- "$0")" in
        *Host*) printf '%s\n' host ;;
        *Viewer*) printf '%s\n' viewer ;;
        *) printf '%s\n' both ;;
    esac
}

role="$(infer_role)"
destination="${MACREMOTEAPP_INSTALL_DIR:-${HOME:?}/Applications}"
clean_testing=0
identity_dir=""
confirm=0
dry_run=0

while (( $# > 0 )); do
    case "$1" in
        --role)
            [[ $# -ge 2 ]] || { echo "--role requires host, viewer, or both" >&2; exit 2; }
            role="$2"
            shift 2
            ;;
        --destination)
            [[ $# -ge 2 ]] || { echo "--destination requires a directory" >&2; exit 2; }
            destination="$2"
            shift 2
            ;;
        --clean-testing)
            clean_testing=1
            shift
            ;;
        --identities)
            [[ $# -ge 2 ]] || { echo "--identities requires a directory" >&2; exit 2; }
            identity_dir="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --yes)
            confirm=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "${role}" in
    host)
        app_names=(MacRemoteApp-Host)
        ;;
    viewer)
        app_names=(MacRemoteApp-Viewer)
        ;;
    both)
        app_names=(MacRemoteApp-Host MacRemoteApp-Viewer)
        ;;
    *)
        echo "Invalid role: ${role}" >&2
        exit 2
        ;;
esac

bundle_identifier_for_app() {
    case "$1" in
        MacRemoteApp-Host)
            printf '%s\n' 'com.rudinyu.MacRemoteApp.Host'
            ;;
        MacRemoteApp-Viewer)
            printf '%s\n' 'com.rudinyu.MacRemoteApp.Viewer'
            ;;
        *)
            echo "Unsupported MacRemoteApp role: $1" >&2
            return 2
            ;;
    esac
}

validate_app_bundle() {
    local app_path="$1"
    local app_name="$2"
    local info_plist="${app_path}/Contents/Info.plist"
    local executable_path="${app_path}/Contents/MacOS/${app_name}"
    local expected_bundle_identifier
    local bundle_identifier
    local bundle_executable

    expected_bundle_identifier="$(bundle_identifier_for_app "${app_name}")"
    if [[ -L "${info_plist}" || ! -f "${info_plist}" ||
          -L "${executable_path}" || ! -f "${executable_path}" ]]; then
        echo "Refusing to remove an incomplete ${app_name}.app bundle: ${app_path}" >&2
        return 1
    fi
    bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info_plist}" 2>/dev/null || true)"
    bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${info_plist}" 2>/dev/null || true)"
    if [[ "${bundle_identifier}" != "${expected_bundle_identifier}" ||
          "${bundle_executable}" != "${app_name}" ]]; then
        echo "Refusing to remove a bundle with unexpected identity: ${app_path}" >&2
        return 1
    fi
}

terminate_running_app() {
    local app_name="$1"
    local bundle_identifier="$2"
    local attempt

    if ! pgrep -x "${app_name}" >/dev/null 2>&1; then
        return 0
    fi

    echo "Requesting ${app_name} to quit before removal..."
    osascript -e "tell application id \"${bundle_identifier}\" to quit" >/dev/null 2>&1 || true
    for attempt in {1..50}; do
        if ! pgrep -x "${app_name}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done

    echo "${app_name} is still running; quit it and rerun the uninstall command." >&2
    return 1
}

if [[ -n "${identity_dir}" && "${clean_testing}" -ne 1 ]]; then
    echo "--identities requires --clean-testing." >&2
    exit 2
fi

if (( clean_testing )); then
    if [[ ! -f "${repo_root}/Package.swift" || "${script_dir}" != "${repo_root}/scripts" ]]; then
        echo "--clean-testing must be run from the repository checkout, not from a copied DMG script." >&2
        exit 2
    fi
    artifact_root="${repo_root}/build"
    if [[ -L "${artifact_root}" || ( -e "${artifact_root}" && ! -d "${artifact_root}" ) ]]; then
        echo "Refusing to clean a non-directory or symlink artifact root: ${artifact_root}" >&2
        exit 2
    fi

    identity_parent="$(dirname -- "${identity_dir:-${repo_root}/_no_identity_cleanup}")"
    if [[ -n "${identity_dir}" ]]; then
        identity_name="$(basename -- "${identity_dir}")"
        [[ "${identity_name}" != "." && "${identity_name}" != ".." && -n "${identity_name}" ]] || {
            echo "--identities must name a dedicated external directory." >&2
            exit 2
        }
        identity_parent="$(cd -- "${identity_parent}" && pwd -P)"
        identity_dir="${identity_parent}/${identity_name}"
        case "${identity_dir}" in
            /|"${repo_root}"|"${repo_root}"/*)
                echo "Refusing to remove identities inside the repository or at filesystem root: ${identity_dir}" >&2
                exit 2
                ;;
        esac
        case "${repo_root}" in
            "${identity_dir}"|"${identity_dir}"/*)
                echo "Refusing to remove an identity path that contains the repository: ${identity_dir}" >&2
                exit 2
                ;;
        esac
        if [[ "${identity_name}" != MacRemoteApp-identities ]]; then
            echo "--identities must name the dedicated MacRemoteApp-identities directory." >&2
            exit 2
        fi
        if [[ -L "${identity_dir}" ]]; then
            echo "Refusing to remove a symlink identity directory: ${identity_dir}" >&2
            exit 2
        fi
        if [[ -e "${identity_dir}" && ! -d "${identity_dir}" ]]; then
            echo "Identity path is not a directory: ${identity_dir}" >&2
            exit 2
        fi
    fi
fi

[[ -n "${destination}" && "${destination}" != "/" ]] || {
    echo "Refusing an empty or root destination." >&2
    exit 2
}

if [[ ! -d "${destination}" ]]; then
    echo "No application directory found: ${destination}"
    if (( ! clean_testing )); then
        exit 0
    fi
else
    destination="$(cd -P -- "${destination}" && pwd)"
fi

targets=()
for app_name in "${app_names[@]}"; do
    app_path="${destination}/${app_name}.app"
    if [[ -L "${app_path}" ]]; then
        echo "Refusing to remove symlink: ${app_path}" >&2
        exit 1
    fi
    if [[ -d "${app_path}" ]]; then
        validate_app_bundle "${app_path}" "${app_name}"
        targets+=("${app_path}")
    fi
done

if (( dry_run )); then
    if (( ${#targets[@]} > 0 )); then
        echo "Dry run: would remove app bundle(s):"
        printf '  %s\n' "${targets[@]}"
    else
        echo "Dry run: no selected app bundles found in ${destination}."
    fi
    if (( clean_testing )); then
        echo "Dry run: would remove ${repo_root}/build/testing"
        echo "Dry run: would remove ${repo_root}/.build"
        echo "Dry run: would reset Host Screen Recording/Accessibility and Host/Viewer Local Network TCC grants"
        echo "Dry run: would remove MacRemoteApp trust/device identity Keychain items"
        [[ -n "${identity_dir}" ]] && echo "Dry run: would remove generated files and the empty ${identity_dir}"
    fi
    exit 0
fi

if (( ${#targets[@]} == 0 && ! clean_testing )); then
    echo "No selected MacRemoteApp bundles found in ${destination}."
    exit 0
fi

if (( ! confirm )); then
    if [[ -t 0 ]]; then
        if (( ${#targets[@]} > 0 )); then
            printf 'Remove the following app bundle(s)?\n'
            printf '  %s\n' "${targets[@]}"
        fi
        if (( clean_testing )); then
            printf '%s\n' 'Also clean repository testing state:'
            printf '  %s\n' "${repo_root}/build/testing"
            printf '  %s\n' "${repo_root}/.build"
            printf '  Host Screen Recording/Accessibility and Host/Viewer Local Network TCC grants'
            printf '\n  MacRemoteApp trust/device identity Keychain items\n'
            [[ -n "${identity_dir}" ]] && printf '  %s\n' "${identity_dir}"
        fi
        read -r -p 'Confirm removal: ' answer
        if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
            echo "Nothing removed."
            exit 0
        fi
    else
        echo "Refusing non-interactive removal without --yes:" >&2
        if (( ${#targets[@]} > 0 )); then
            printf '  %s\n' "${targets[@]}" >&2
        fi
        (( clean_testing )) && echo "  plus repository testing state: ${repo_root}" >&2
        exit 2
    fi
fi

remove_directory() {
    local path="$1"
    local label="$2"
    if [[ -L "${path}" ]]; then
        echo "Refusing to remove symlink ${label}: ${path}" >&2
        return 1
    fi
    if [[ -e "${path}" && ! -d "${path}" ]]; then
        echo "Refusing to remove non-directory ${label}: ${path}" >&2
        return 1
    fi
    if [[ -d "${path}" ]]; then
        if ! rm -rf -- "${path}"; then
            echo "Failed to remove ${label}: ${path}" >&2
            return 1
        fi
        echo "Removed ${label}: ${path}"
    else
        echo "No ${label} found: ${path}"
    fi
}

remove_generated_identity_files() {
    local directory="$1"
    local file_name
    local file_path
    local remaining

    if [[ -L "${directory}" ]]; then
        echo "Refusing to remove symlink external M2 identities: ${directory}" >&2
        return 1
    fi
    if [[ ! -d "${directory}" ]]; then
        echo "No external M2 identities found: ${directory}"
        return 0
    fi

    remaining="$(find "${directory}" -mindepth 1 -maxdepth 1 \
        ! \( -name host.p12 -o -name host.cer -o -name viewer.p12 -o -name viewer.cer \) \
        -print -quit)"
    if [[ -n "${remaining}" ]]; then
        echo "Refusing to remove non-generated contents from external M2 identities: ${remaining}" >&2
        return 1
    fi

    for file_name in host.p12 host.cer viewer.p12 viewer.cer; do
        file_path="${directory}/${file_name}"
        if [[ -L "${file_path}" ]]; then
            echo "Refusing to remove symlink identity material: ${file_path}" >&2
            return 1
        fi
        if [[ -d "${file_path}" ]]; then
            echo "Refusing to remove directory identity material: ${file_path}" >&2
            return 1
        fi
        if [[ -e "${file_path}" ]]; then
            if ! rm -f -- "${file_path}"; then
                echo "Failed to remove generated identity: ${file_path}" >&2
                return 1
            fi
            echo "Removed generated identity: ${file_path}"
        fi
    done

    if ! rmdir -- "${directory}"; then
        echo "Failed to remove empty external M2 identities directory: ${directory}" >&2
        return 1
    fi
    echo "Removed external M2 identities directory: ${directory}"
}

if (( ${#targets[@]} > 0 )); then
    for app_path in "${targets[@]}"; do
        app_name="$(basename -- "${app_path}" .app)"
        validate_app_bundle "${app_path}" "${app_name}"
        terminate_running_app "${app_name}" "$(bundle_identifier_for_app "${app_name}")"
        # Recheck after the quit wait so a replacement cannot turn the
        # validated path into an unrelated directory before deletion.
        validate_app_bundle "${app_path}" "${app_name}"
        rm -rf -- "${app_path}"
        if [[ -e "${app_path}" || -L "${app_path}" ]]; then
            echo "Failed to remove ${app_path}" >&2
            exit 1
        fi
        echo "Removed ${app_path}"
    done
fi

if (( clean_testing )); then
    cleanup_failure=0
    remove_directory "${repo_root}/build/testing" "testing artifacts" || cleanup_failure=1
    remove_directory "${repo_root}/.build" "SwiftPM cache" || cleanup_failure=1

    for service in ScreenCapture Accessibility; do
        if tccutil reset "${service}" com.rudinyu.MacRemoteApp.Host >/dev/null 2>&1; then
            echo "Reset Host ${service} TCC grant"
        else
            echo "Warning: unable to reset Host ${service} TCC grant; check macOS Privacy settings." >&2
            cleanup_failure=1
        fi
    done
    for bundle_id in com.rudinyu.MacRemoteApp.Host com.rudinyu.MacRemoteApp.Viewer; do
        if tccutil reset LocalNetwork "${bundle_id}" >/dev/null 2>&1; then
            echo "Reset ${bundle_id} LocalNetwork TCC grant"
        else
            echo "Warning: unable to reset ${bundle_id} LocalNetwork TCC grant; check macOS Privacy settings." >&2
            cleanup_failure=1
        fi
    done

    if swift "${script_dir}/clear-testing-keychain.swift"; then
        :
    else
        echo "Warning: Keychain cleanup failed; inspect Keychain Access and retry." >&2
        cleanup_failure=1
    fi

    remove_imported_test_identity() {
        local role_name="$1"
        local common_name="MacRemoteApp-${role_name}"
        local certificate_path="${identity_dir}/${role_name}.cer"
        local pkcs12_path="${identity_dir}/${role_name}.p12"
        local pkcs12_password
        local identity_output
        local certificate_output
        local certificate_subject
        local certificate_hash

        if [[ -f "${certificate_path}" ]]; then
            if ! certificate_output="$(openssl x509 \
                -inform DER \
                -in "${certificate_path}" \
                -noout \
                -subject \
                -nameopt RFC2253 \
                -fingerprint -sha1 2>&1)"; then
                echo "Unable to inspect generated public certificate: ${certificate_path}" >&2
                return 1
            fi
        else
            pkcs12_password="${MACREMOTEAPP_P12_PASSWORD:-}"
            if [[ -z "${pkcs12_password}" ]]; then
                echo "MACREMOTEAPP_P12_PASSWORD is required to inspect ${pkcs12_path}; refusing to remove its Keychain identity." >&2
                return 1
            fi
            if ! certificate_output="$(
                MACREMOTEAPP_P12_PASSWORD="${pkcs12_password}" \
                    openssl pkcs12 \
                        -in "${pkcs12_path}" \
                        -clcerts \
                        -nokeys \
                        -passin env:MACREMOTEAPP_P12_PASSWORD 2>/dev/null |
                    openssl x509 \
                        -noout \
                        -subject \
                        -nameopt RFC2253 \
                        -fingerprint -sha1 2>&1
            )"; then
                echo "Unable to inspect generated PKCS#12 certificate: ${pkcs12_path}" >&2
                return 1
            fi
        fi
        certificate_subject="$(printf '%s\n' "${certificate_output}" | \
            sed -n -E 's/^subject[[:space:]]*=[[:space:]]*//p' | \
            sed -E 's/[[:space:]]*=[[:space:]]*/=/g' | \
            head -n 1)"
        if ! printf '%s\n' "${certificate_subject}" | \
            awk -v expected="CN=${common_name}" '
                BEGIN { RS = "," }
                {
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
                    if ($0 == expected) {
                        found = 1
                    }
                }
                END { exit !found }
            '; then
            echo "The supplied certificate is not the generated ${common_name} certificate." >&2
            return 1
        fi
        certificate_hash="$(printf '%s\n' "${certificate_output}" | \
            awk -F= '/Fingerprint/ { gsub(":", "", $2); print toupper($2); exit }')"
        [[ "${certificate_hash}" =~ ^[A-Fa-f0-9]{40}$ ]] || {
            echo "Unable to derive the generated certificate fingerprint: ${certificate_path}" >&2
            return 1
        }

        if ! identity_output="$(security find-identity -p basic 2>&1)"; then
            echo "Unable to inspect Keychain identities for ${common_name}: ${identity_output}" >&2
            return 1
        fi
        if ! printf '%s\n' "${identity_output}" | \
            awk -v fingerprint="${certificate_hash}" '$2 == fingerprint { found = 1 } END { exit !found }'; then
            echo "No imported test identity found: ${common_name}"
            return 0
        fi
        if ! security delete-identity -Z "${certificate_hash}" -t >/dev/null 2>&1; then
            echo "Unable to remove imported test identity ${common_name} (${certificate_hash})." >&2
            return 1
        fi
        echo "Removed imported test identity: ${common_name} (${certificate_hash})"
    }

    identity_keychain_cleanup_ok=1
    if [[ -n "${identity_dir}" && -d "${identity_dir}" ]]; then
        for role_name in host viewer; do
            certificate_path="${identity_dir}/${role_name}.cer"
            pkcs12_path="${identity_dir}/${role_name}.p12"
            if [[ -L "${certificate_path}" || -L "${pkcs12_path}" ]]; then
                echo "Refusing to inspect symlink identity material for ${role_name}." >&2
                cleanup_failure=1
                identity_keychain_cleanup_ok=0
            elif [[ ! -e "${certificate_path}" && ! -e "${pkcs12_path}" ]]; then
                echo "Skipped ${role_name} identity cleanup; neither its .cer nor .p12 is present on this device."
            elif [[ -e "${certificate_path}" && ! -f "${certificate_path}" ]]; then
                echo "Refusing to inspect non-file identity material: ${certificate_path}" >&2
                cleanup_failure=1
                identity_keychain_cleanup_ok=0
            elif [[ ! -e "${certificate_path}" && ! -f "${pkcs12_path}" ]]; then
                echo "Refusing to inspect non-file identity material: ${pkcs12_path}" >&2
                cleanup_failure=1
                identity_keychain_cleanup_ok=0
            elif ! remove_imported_test_identity "${role_name}"; then
                cleanup_failure=1
                identity_keychain_cleanup_ok=0
            fi
        done
    else
        echo "Skipped imported M2 identity Keychain cleanup; pass --identities to identify generated certificates."
    fi

    if [[ -n "${identity_dir}" ]]; then
        if (( identity_keychain_cleanup_ok )); then
            remove_generated_identity_files "${identity_dir}" || cleanup_failure=1
        else
            echo "Preserved external M2 identities after Keychain cleanup failure: ${identity_dir}" >&2
        fi
    fi

    if (( cleanup_failure )); then
        exit 1
    fi
    echo "Testing cleanup complete; build/beta, build/rc, and build/release were preserved."
fi
