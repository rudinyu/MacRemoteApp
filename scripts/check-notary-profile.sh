#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
    echo "Usage: bash scripts/check-notary-profile.sh [profile-name]" >&2
    exit 2
fi

profile_name="${1:-${MACREMOTEAPP_NOTARY_PROFILE:-notarytool-profile}}"
if [[ -z "${profile_name}" ]]; then
    echo "MACREMOTEAPP_NOTARY_PROFILE must name an existing Keychain profile." >&2
    exit 2
fi

echo "Checking local notary profile: ${profile_name}"
if xcrun notarytool history \
    --keychain-profile "${profile_name}" \
    --output-format json >/dev/null
then
    echo "Keychain history operation succeeded for: ${profile_name}"
else
    history_exit=$?
    cat >&2 <<EOF
The optional notarytool history operation could not be completed for
'${profile_name}' in this macOS session.
This does not prove that the profile is unusable: the release flow does not
use history, and its actual notarytool submit operation is authoritative.
Run this diagnostic from the same logged-in user session that created the
profile, or run the release flow to test the real submit path. The profile
name is safe to share, but its credentials must stay in Keychain.
EOF
    exit "${history_exit}"
fi
