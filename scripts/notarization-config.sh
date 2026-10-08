#!/usr/bin/env bash

# Sourced by the two canonical notarization entry points. The shared config is
# deliberately parsed as data rather than sourced as shell code.

macremoteapp_notary__error() {
    printf 'Notarization configuration error: %s\n' "$1" >&2
}

macremoteapp_notary__file_mode() {
    local file_path="$1"
    local mode

    if mode="$(stat -f '%Lp' "$file_path" 2>/dev/null)" &&
       [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
        printf '%s' "$mode"
        return 0
    fi
    if mode="$(stat -c '%a' "$file_path" 2>/dev/null)"; then
        printf '%s' "$mode"
        return 0
    fi
    return 1
}

macremoteapp_notary__require_private_file() {
    local file_path="$1"
    local description="$2"
    local mode

    if [[ -L "$file_path" || ! -f "$file_path" || ! -r "$file_path" || ! -O "$file_path" ]]; then
        macremoteapp_notary__error "${description} must be a readable regular file owned by the current user."
        return 1
    fi
    if ! mode="$(macremoteapp_notary__file_mode "$file_path")" || [[ "$mode" != 600 ]]; then
        macremoteapp_notary__error "${description} must have owner-only mode 600."
        return 1
    fi
    return 0
}

macremoteapp_notary__parse_literal() {
    local raw_value="$1"
    local first last
    local safe_value_pattern='^[A-Za-z0-9_./ :+-]+$'

    MACREMOTEAPP_NOTARY_LITERAL=""
    [[ -n "$raw_value" ]] || return 1
    first="${raw_value:0:1}"
    last="${raw_value:${#raw_value}-1:1}"

    if [[ "$first" == '"' ]]; then
        [[ "$last" == '"' && ${#raw_value} -ge 2 ]] || return 1
        MACREMOTEAPP_NOTARY_LITERAL="${raw_value:1:${#raw_value}-2}"
        [[ "$MACREMOTEAPP_NOTARY_LITERAL" != *'"'* ]] || return 1
    elif [[ "$first" == "'" ]]; then
        [[ "$last" == "'" && ${#raw_value} -ge 2 ]] || return 1
        MACREMOTEAPP_NOTARY_LITERAL="${raw_value:1:${#raw_value}-2}"
        [[ "$MACREMOTEAPP_NOTARY_LITERAL" != *"'"* ]] || return 1
    elif [[ "$raw_value" =~ ^[A-Za-z0-9_./:+-]+$ ]]; then
        MACREMOTEAPP_NOTARY_LITERAL="$raw_value"
    else
        return 1
    fi

    [[ -n "$MACREMOTEAPP_NOTARY_LITERAL" &&
       "$MACREMOTEAPP_NOTARY_LITERAL" =~ $safe_value_pattern ]]
}

macremoteapp_notary__validate_api_key() {
    local repository_root="$1"
    local key_path="$2"
    local key_directory key_name resolved_key_path

    if [[ "$key_path" != /* || -L "$key_path" || ! -f "$key_path" ]]; then
        macremoteapp_notary__error "The configured API private key must be an absolute regular file, not a symlink."
        return 1
    fi
    key_directory="$(cd -- "$(dirname -- "$key_path")" 2>/dev/null && pwd -P)" || {
        macremoteapp_notary__error "The configured API private key path is unavailable."
        return 1
    }
    key_name="$(basename -- "$key_path")"
    resolved_key_path="${key_directory}/${key_name}"
    case "$resolved_key_path" in
        "$repository_root"|"$repository_root"/*)
            macremoteapp_notary__error "The configured API private key must remain outside the repository."
            return 1
            ;;
    esac
    macremoteapp_notary__require_private_file "$resolved_key_path" "The configured API private key"
}

macremoteapp_notary_scrub_environment() {
    # Credentials are read from the owner-only file, then passed only as
    # arguments to notarytool. Do not let ambient copies reach build/CI tools.
    unset MACOS_NOTARY_PROFILE MACOS_NOTARY_KEY_PATH MACOS_NOTARY_KEY_ID MACOS_NOTARY_ISSUER
}

macremoteapp_notary_resolve() {
    if (( $# < 1 || $# > 2 )); then
        macremoteapp_notary__error "internal configuration resolver usage error."
        return 2
    fi

    # Do not let a caller's shell tracing print credential arguments later.
    case "$-" in
        *x*) set +x ;;
    esac
    # These entry points run as standalone Bash processes. Keep parsed values
    # local to the shell even when an inherited BASH_ENV enabled allexport.
    set +a

    local repository_root="$1"
    local config_path="${2:-}"
    local project_profile=""
    local generic_profile=""
    local generic_key_path=""
    local generic_key_id=""
    local generic_issuer=""
    local raw_line line trimmed name raw_value line_number=0

    unset MACREMOTEAPP_RESOLVED_NOTARY_MODE \
        MACREMOTEAPP_RESOLVED_NOTARY_PROFILE \
        MACREMOTEAPP_RESOLVED_NOTARY_KEY_PATH \
        MACREMOTEAPP_RESOLVED_NOTARY_KEY_ID \
        MACREMOTEAPP_RESOLVED_NOTARY_ISSUER \
        MACREMOTEAPP_NOTARY_LITERAL

    if [[ ! -d "$repository_root" ]]; then
        macremoteapp_notary__error "the repository root is unavailable."
        return 2
    fi
    repository_root="$(cd -- "$repository_root" && pwd -P)" || return 2

    # The project's established Keychain profile is the explicit override.
    # Preserve its historical empty-value fallback to notarytool-profile.
    if [[ "${MACREMOTEAPP_NOTARY_PROFILE+x}" == x ]]; then
        project_profile="${MACREMOTEAPP_NOTARY_PROFILE:-notarytool-profile}"
        MACREMOTEAPP_RESOLVED_NOTARY_MODE="profile"
        MACREMOTEAPP_RESOLVED_NOTARY_PROFILE="$project_profile"
        MACREMOTEAPP_RESOLVED_NOTARY_KEY_PATH=""
        MACREMOTEAPP_RESOLVED_NOTARY_KEY_ID=""
        MACREMOTEAPP_RESOLVED_NOTARY_ISSUER=""
        macremoteapp_notary_scrub_environment
        return 0
    fi

    macremoteapp_notary_scrub_environment
    if [[ -z "$config_path" && -n "${HOME:-}" ]]; then
        config_path="${HOME}/.config/codex/notarization.env"
    fi

    if [[ -n "$config_path" && ( -e "$config_path" || -L "$config_path" ) ]]; then
        if [[ -L "$config_path" || ! -f "$config_path" ]]; then
            macremoteapp_notary__error "the shared configuration must be a regular non-symlink file."
            return 2
        fi
        if ! macremoteapp_notary__require_private_file "$config_path" "The shared configuration"; then
            return 2
        fi

        while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
            line_number=$((line_number + 1))
            line="${raw_line%$'\r'}"
            trimmed="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue

            if [[ "$trimmed" =~ ^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                name="${BASH_REMATCH[2]}"
                raw_value="${BASH_REMATCH[3]}"
                raw_value="${raw_value#"${raw_value%%[![:space:]]*}"}"
                raw_value="${raw_value%"${raw_value##*[![:space:]]}"}"
            else
                macremoteapp_notary__error "unsupported active syntax at line ${line_number}; the configuration is data, not a shell script."
                return 2
            fi

            case "$name" in
                MACOS_NOTARY_PROFILE|MACOS_NOTARY_KEY_PATH|MACOS_NOTARY_KEY_ID|MACOS_NOTARY_ISSUER)
                    ;;
                *)
                    macremoteapp_notary__error "unsupported variable at line ${line_number}."
                    return 2
                    ;;
            esac
            if ! macremoteapp_notary__parse_literal "$raw_value"; then
                macremoteapp_notary__error "invalid literal for ${name} at line ${line_number}."
                return 2
            fi
            case "$name" in
                MACOS_NOTARY_PROFILE)
                    [[ -z "$generic_profile" ]] || {
                        macremoteapp_notary__error "duplicate MACOS_NOTARY_PROFILE at line ${line_number}."
                        return 2
                    }
                    generic_profile="$MACREMOTEAPP_NOTARY_LITERAL"
                    ;;
                MACOS_NOTARY_KEY_PATH)
                    [[ -z "$generic_key_path" ]] || {
                        macremoteapp_notary__error "duplicate MACOS_NOTARY_KEY_PATH at line ${line_number}."
                        return 2
                    }
                    generic_key_path="$MACREMOTEAPP_NOTARY_LITERAL"
                    ;;
                MACOS_NOTARY_KEY_ID)
                    [[ -z "$generic_key_id" ]] || {
                        macremoteapp_notary__error "duplicate MACOS_NOTARY_KEY_ID at line ${line_number}."
                        return 2
                    }
                    generic_key_id="$MACREMOTEAPP_NOTARY_LITERAL"
                    ;;
                MACOS_NOTARY_ISSUER)
                    [[ -z "$generic_issuer" ]] || {
                        macremoteapp_notary__error "duplicate MACOS_NOTARY_ISSUER at line ${line_number}."
                        return 2
                    }
                    generic_issuer="$MACREMOTEAPP_NOTARY_LITERAL"
                    ;;
            esac
        done < "$config_path"
    fi

    if [[ -n "$generic_profile" ]]; then
        if [[ -n "$generic_key_path" || -n "$generic_key_id" || -n "$generic_issuer" ]]; then
            macremoteapp_notary__error "the shared configuration must choose either a Keychain profile or API-key credentials."
            return 2
        fi
        MACREMOTEAPP_RESOLVED_NOTARY_MODE="profile"
        MACREMOTEAPP_RESOLVED_NOTARY_PROFILE="$generic_profile"
        MACREMOTEAPP_RESOLVED_NOTARY_KEY_PATH=""
        MACREMOTEAPP_RESOLVED_NOTARY_KEY_ID=""
        MACREMOTEAPP_RESOLVED_NOTARY_ISSUER=""
        return 0
    fi

    if [[ -n "$generic_key_path" || -n "$generic_key_id" || -n "$generic_issuer" ]]; then
        if [[ -z "$generic_key_path" || -z "$generic_key_id" || -z "$generic_issuer" ]]; then
            macremoteapp_notary__error "the shared API-key configuration must define all three supported fields."
            return 2
        fi
        if ! macremoteapp_notary__validate_api_key "$repository_root" "$generic_key_path"; then
            return 2
        fi
        MACREMOTEAPP_RESOLVED_NOTARY_MODE="api-key"
        MACREMOTEAPP_RESOLVED_NOTARY_PROFILE=""
        MACREMOTEAPP_RESOLVED_NOTARY_KEY_PATH="$generic_key_path"
        MACREMOTEAPP_RESOLVED_NOTARY_KEY_ID="$generic_key_id"
        MACREMOTEAPP_RESOLVED_NOTARY_ISSUER="$generic_issuer"
        return 0
    fi

    # Preserve the existing Keychain profile behavior when no shared default
    # is present. An empty owner-only config file is equivalent to no default.
    MACREMOTEAPP_RESOLVED_NOTARY_MODE="profile"
    MACREMOTEAPP_RESOLVED_NOTARY_PROFILE="notarytool-profile"
    MACREMOTEAPP_RESOLVED_NOTARY_KEY_PATH=""
    MACREMOTEAPP_RESOLVED_NOTARY_KEY_ID=""
    MACREMOTEAPP_RESOLVED_NOTARY_ISSUER=""
}

macremoteapp_notary_submit() {
    if (( $# < 1 )); then
        macremoteapp_notary__error "internal notarytool submit usage error."
        return 2
    fi
    local artifact_path="$1"
    shift

    case "${MACREMOTEAPP_RESOLVED_NOTARY_MODE:-}" in
        profile)
            xcrun notarytool submit \
                "$artifact_path" \
                --keychain-profile "${MACREMOTEAPP_RESOLVED_NOTARY_PROFILE}" \
                "$@"
            ;;
        api-key)
            xcrun notarytool submit \
                "$artifact_path" \
                --key "${MACREMOTEAPP_RESOLVED_NOTARY_KEY_PATH}" \
                --key-id "${MACREMOTEAPP_RESOLVED_NOTARY_KEY_ID}" \
                --issuer "${MACREMOTEAPP_RESOLVED_NOTARY_ISSUER}" \
                "$@"
            ;;
        *)
            macremoteapp_notary__error "notarytool credentials have not been resolved."
            return 2
            ;;
    esac
}
