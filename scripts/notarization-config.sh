#!/usr/bin/env bash

# Thin adapter for the shared macOS notarization helper. Authentication
# configuration stays in the owner-only Codex config; this file only maps the
# project's legacy override names and artifact flow.
case "$-" in
    *x*) set +x ;;
esac

macremoteapp_notarization_helper_path() {
    local helper="${MACREMOTEAPP_NOTARIZATION_HELPER:-}"
    if [[ -z "$helper" ]]; then
        if [[ -z "${HOME:-}" ]]; then
            echo "The shared macOS notarization helper is unavailable." >&2
            return 1
        fi
        helper="$HOME/.codex/skills/macos-notarization-release/scripts/macos_notarization.py"
    fi
    if [[ ! -f "$helper" || -L "$helper" ]]; then
        echo "The shared macOS notarization helper is unavailable." >&2
        return 1
    fi
    printf '%s\n' "$helper"
}

macremoteapp_notarization_call() {
    local helper python
    helper="$(macremoteapp_notarization_helper_path)" || return 1
    python="$(command -v python3)" || {
        echo "Python 3 is required to run the shared macOS notarization helper." >&2
        return 1
    }
    "$python" "$helper" "$@"
}

macremoteapp_notary_resolve() {
    if (( $# != 1 )); then
        echo "Internal notarization configuration usage error." >&2
        return 2
    fi
    local repository_root="$1"
    local resolved_auth
    local arguments=(resolve-auth --auth auto --default-profile notarytool-profile \
        --project-root "$repository_root")

    if [[ -n "${MACREMOTEAPP_NOTARY_PROFILE+x}" ]]; then
        local project_profile="${MACREMOTEAPP_NOTARY_PROFILE:-notarytool-profile}"
        arguments=(resolve-auth --auth keychain-profile --profile "$project_profile" \
            --project-root "$repository_root")
        MACREMOTEAPP_RESOLVED_NOTARY_PROFILE="$project_profile"
    else
        MACREMOTEAPP_RESOLVED_NOTARY_PROFILE=""
    fi

    resolved_auth="$(macremoteapp_notarization_call "${arguments[@]}")" || {
        echo "Unable to resolve notarization authentication using the shared helper." >&2
        return 1
    }
    case "$resolved_auth" in
        keychain-profile)
            MACREMOTEAPP_RESOLVED_NOTARY_MODE="profile"
            ;;
        api-key)
            MACREMOTEAPP_RESOLVED_NOTARY_MODE="api-key"
            ;;
        *)
            echo "The shared helper returned an unexpected authentication selection." >&2
            return 1
            ;;
    esac
    MACREMOTEAPP_NOTARY_PROJECT_ROOT="$repository_root"
}

macremoteapp_notary_submit() {
    if (( $# != 1 )); then
        echo "Internal notarization submit usage error." >&2
        return 2
    fi
    local artifact_path="$1"
    local auth_kind="${MACREMOTEAPP_RESOLVED_NOTARY_MODE:-}"
    local project_root="${MACREMOTEAPP_NOTARY_PROJECT_ROOT:-}"
    local arguments
    case "$auth_kind" in
        profile)
            auth_kind="keychain-profile"
            ;;
        api-key)
            ;;
        *)
            echo "Notarization authentication has not been resolved." >&2
            return 2
            ;;
    esac
    if [[ -z "$project_root" ]]; then
        echo "Notarization project root has not been resolved." >&2
        return 2
    fi

    arguments=(submit "$artifact_path" --authorized --wait --auth "$auth_kind" \
        --project-root "$project_root" --default-profile notarytool-profile)
    if [[ -n "${MACREMOTEAPP_RESOLVED_NOTARY_PROFILE:-}" ]]; then
        arguments+=(--profile "$MACREMOTEAPP_RESOLVED_NOTARY_PROFILE")
    fi
    macremoteapp_notarization_call "${arguments[@]}"
}

macremoteapp_resolve_signing_identity() {
    local default_identity="${1:--}"
    if [[ -n "${MACREMOTEAPP_SIGNING_IDENTITY:-}" ]]; then
        if [[ "$MACREMOTEAPP_SIGNING_IDENTITY" == "-" ]]; then
            printf '%s\n' "-"
            return 0
        fi
        macremoteapp_notarization_call resolve-signing-identity \
            --identity "$MACREMOTEAPP_SIGNING_IDENTITY" \
            --default-identity "$default_identity"
        return $?
    fi
    macremoteapp_notarization_call resolve-signing-identity \
        --default-identity "$default_identity"
}

macremoteapp_sign_app() {
    if (( $# < 2 || $# > 3 )); then
        echo "Internal app-signing usage error." >&2
        return 2
    fi
    local app_path="$1"
    local identity="$2"
    local entitlements="${3:-}"
    if [[ "$identity" == "-" ]]; then
        local arguments=(--force --deep --options runtime)
        if [[ -n "$entitlements" ]]; then
            arguments+=(--entitlements "$entitlements")
        fi
        arguments+=(--sign - --timestamp=none "$app_path")
        codesign "${arguments[@]}"
        return $?
    fi

    local arguments=(sign "$app_path" --authorized --identity "$identity")
    if [[ -n "$entitlements" ]]; then
        arguments+=(--entitlements "$entitlements")
    fi
    macremoteapp_notarization_call "${arguments[@]}"
}

macremoteapp_notary_staple() {
    if (( $# != 1 )); then
        echo "Internal ticket-stapling usage error." >&2
        return 2
    fi
    macremoteapp_notarization_call staple "$1"
}

macremoteapp_notary_verify() {
    if (( $# != 1 )); then
        echo "Internal artifact-verification usage error." >&2
        return 2
    fi
    macremoteapp_notarization_call verify "$1"
}
