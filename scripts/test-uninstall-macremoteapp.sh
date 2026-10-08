#!/bin/bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script_source="${repo_root}/scripts/Uninstall-MacRemoteApp.command"
if [[ -d /private/tmp && ! -L /private/tmp ]]; then
    temp_parent="/private/tmp"
else
    temp_parent="/tmp"
fi
test_root="$(/usr/bin/mktemp -d "${temp_parent}/macremoteapp-uninstall.XXXXXX")"
trap '/bin/rm -rf -- "$test_root"' EXIT HUP INT TERM

mock_bin="${test_root}/mockbin"
system_apps="${test_root}/system-applications"
script_copy="${test_root}/Uninstall-MacRemoteApp.command"
/bin/mkdir -p "${mock_bin}" "${system_apps}"

write_mock() {
    local path="$1"
    /bin/cat >"${path}"
    /bin/chmod 755 "${path}"
}

write_mock "${mock_bin}/id" <<'MOCK'
#!/bin/bash
case "$1" in
    -u) printf '%s\n' "${FIXTURE_UID:-501}" ;;
    -un) printf '%s\n' fixture-user ;;
    *) exit 2 ;;
esac
MOCK

write_mock "${mock_bin}/dscl" <<'MOCK'
#!/bin/bash
printf 'NFSHomeDirectory: %s\n' "${FIXTURE_HOME}"
MOCK

write_mock "${mock_bin}/PlistBuddy" <<'MOCK'
#!/bin/bash
[[ "$1" == -c && -f "$3" ]] || exit 2
case "$2" in
    'Print :CFBundleIdentifier') key=CFBundleIdentifier ;;
    'Print :CFBundleExecutable') key=CFBundleExecutable ;;
    'Print :CFBundleVersion') key=CFBundleVersion ;;
    *) exit 2 ;;
esac
while IFS='=' read -r field value; do
    if [[ "$field" == "$key" ]]; then
        printf '%s\n' "$value"
        exit 0
    fi
done <"$3"
exit 1
MOCK

write_mock "${mock_bin}/codesign" <<'MOCK'
#!/bin/bash
if [[ "$1" == --verify ]]; then
    [[ "${FIXTURE_BAD_SIGNATURE:-0}" != 1 ]]
    exit $?
fi
if [[ "$1" == --display ]]; then
    printf 'Authority=Developer ID Application: MacRemoteApp (LYK4LV2859)\n'
    printf 'TeamIdentifier=%s\n' "${MOCK_TEAM_IDENTIFIER:-LYK4LV2859}"
    exit 0
fi
exit 2
MOCK

write_mock "${mock_bin}/spctl" <<'MOCK'
#!/bin/bash
exit 0
MOCK

write_mock "${mock_bin}/pgrep" <<'MOCK'
#!/bin/bash
[[ "$1" == -x && -n "$2" ]] || exit 2
count=0
if [[ -f "${FIXTURE_STATE}/pgrep-count" ]]; then
    IFS= read -r count <"${FIXTURE_STATE}/pgrep-count"
fi
count=$((count + 1))
printf '%s\n' "$count" >"${FIXTURE_STATE}/pgrep-count"
if [[ -n "${FIXTURE_PGREP_ERROR_AT_CALL:-}" && "$count" -eq "$FIXTURE_PGREP_ERROR_AT_CALL" ]]; then
    exit 2
fi
if [[ -n "${FIXTURE_LAUNCH_AT_CALL:-}" && "$count" -eq "$FIXTURE_LAUNCH_AT_CALL" ]]; then
    : >"${FIXTURE_STATE}/running.${FIXTURE_LAUNCH_ROLE}"
fi
[[ -e "${FIXTURE_STATE}/running.${2}" ]]
MOCK

write_mock "${mock_bin}/tccutil" <<'MOCK'
#!/bin/bash
[[ "$#" -eq 3 && "$1" == reset && "$2" == All ]] || exit 2
case "$3" in
    com.rudinyu.MacRemoteApp.Host|com.rudinyu.MacRemoteApp.Viewer) ;;
    *) exit 2 ;;
esac
printf '%s %s %s\n' "$1" "$2" "$3" >>"${FIXTURE_STATE}/tcc.log"
[[ "${FIXTURE_TCC_FAIL_ID:-}" != "$3" ]]
MOCK

write_mock "${mock_bin}/mkdir" <<'MOCK'
#!/bin/bash
[[ -n "${TEST_ROOT:-}" && "${TEST_ROOT}" == /* && "${TEST_ROOT}" != "/" && -d "${TEST_ROOT}" && ! -L "${TEST_ROOT}" ]] || exit 2
canonical_root="$(cd -- "${TEST_ROOT}" && pwd -P)" || exit 2
[[ "${canonical_root}" == "${TEST_ROOT}" ]] || exit 2
[[ -n "${FIXTURE_STATE:-}" && "${FIXTURE_STATE}" == "${TEST_ROOT}"/* && -d "${FIXTURE_STATE}" ]] || exit 2
target=""
for argument in "$@"; do target="$argument"; done
case "$target" in "${TEST_ROOT}"/*) ;; *) exit 2 ;; esac
printf 'mkdir %s\n' "$target" >>"${FIXTURE_STATE}/actions.log"
exec /bin/mkdir "$@"
MOCK

write_mock "${mock_bin}/mv" <<'MOCK'
#!/bin/bash
[[ -n "${TEST_ROOT:-}" && "${TEST_ROOT}" == /* && "${TEST_ROOT}" != "/" && -d "${TEST_ROOT}" && ! -L "${TEST_ROOT}" ]] || exit 2
canonical_root="$(cd -- "${TEST_ROOT}" && pwd -P)" || exit 2
[[ "${canonical_root}" == "${TEST_ROOT}" ]] || exit 2
[[ -n "${FIXTURE_STATE:-}" && "${FIXTURE_STATE}" == "${TEST_ROOT}"/* && -d "${FIXTURE_STATE}" ]] || exit 2
[[ "$#" -eq 3 && "$1" == -- ]] || exit 2
case "$2" in "${TEST_ROOT}"/*) ;; *) exit 2 ;; esac
case "$3" in "${TEST_ROOT}"/*) ;; *) exit 2 ;; esac
printf 'mv %s %s\n' "$2" "$3" >>"${FIXTURE_STATE}/actions.log"
exec /bin/mv "$@"
MOCK

write_mock "${mock_bin}/rm" <<'MOCK'
#!/bin/bash
[[ -n "${TEST_ROOT:-}" && "${TEST_ROOT}" == /* && "${TEST_ROOT}" != "/" && -d "${TEST_ROOT}" && ! -L "${TEST_ROOT}" ]] || exit 2
canonical_root="$(cd -- "${TEST_ROOT}" && pwd -P)" || exit 2
[[ "${canonical_root}" == "${TEST_ROOT}" ]] || exit 2
[[ -n "${FIXTURE_STATE:-}" && "${FIXTURE_STATE}" == "${TEST_ROOT}"/* && -d "${FIXTURE_STATE}" ]] || exit 2
[[ "$#" -eq 3 && "$2" == -- ]] || exit 2
case "$3" in "${TEST_ROOT}"/*) ;; *) exit 2 ;; esac
printf 'rm %s\n' "$3" >>"${FIXTURE_STATE}/actions.log"
exec /bin/rm "$@"
MOCK

/usr/bin/sed \
    -e "s|readonly SYSTEM_APPLICATIONS=\"/Applications\"|readonly SYSTEM_APPLICATIONS=\"${system_apps}\"|" \
    -e "s|readonly ID_TOOL=\"/usr/bin/id\"|readonly ID_TOOL=\"${mock_bin}/id\"|" \
    -e "s|readonly DSCL_TOOL=\"/usr/bin/dscl\"|readonly DSCL_TOOL=\"${mock_bin}/dscl\"|" \
    -e "s|readonly PLIST_BUDDY_TOOL=\"/usr/libexec/PlistBuddy\"|readonly PLIST_BUDDY_TOOL=\"${mock_bin}/PlistBuddy\"|" \
    -e "s|readonly CODESIGN_TOOL=\"/usr/bin/codesign\"|readonly CODESIGN_TOOL=\"${mock_bin}/codesign\"|" \
    -e "s|readonly SPCTL_TOOL=\"/usr/sbin/spctl\"|readonly SPCTL_TOOL=\"${mock_bin}/spctl\"|" \
    -e "s|readonly PGREP_TOOL=\"/usr/bin/pgrep\"|readonly PGREP_TOOL=\"${mock_bin}/pgrep\"|" \
    -e "s|readonly TCCUTIL_TOOL=\"/usr/bin/tccutil\"|readonly TCCUTIL_TOOL=\"${mock_bin}/tccutil\"|" \
    -e "s|readonly MKDIR_TOOL=\"/bin/mkdir\"|readonly MKDIR_TOOL=\"${mock_bin}/mkdir\"|" \
    -e "s|readonly MV_TOOL=\"/bin/mv\"|readonly MV_TOOL=\"${mock_bin}/mv\"|" \
    -e "s|readonly RM_TOOL=\"/bin/rm\"|readonly RM_TOOL=\"${mock_bin}/rm\"|" \
    "${script_source}" >"${script_copy}"
assert_rewritten() {
    local expected="$1"
    /usr/bin/grep -Fq -- "$expected" "${script_copy}" || {
        /usr/bin/printf 'Fixture setup failed; expected transformed line: %s\n' "$expected" >&2
        exit 2
    }
}
assert_rewritten "readonly SYSTEM_APPLICATIONS=\"${system_apps}\""
assert_rewritten "readonly ID_TOOL=\"${mock_bin}/id\""
assert_rewritten "readonly DSCL_TOOL=\"${mock_bin}/dscl\""
assert_rewritten "readonly PLIST_BUDDY_TOOL=\"${mock_bin}/PlistBuddy\""
assert_rewritten "readonly CODESIGN_TOOL=\"${mock_bin}/codesign\""
assert_rewritten "readonly SPCTL_TOOL=\"${mock_bin}/spctl\""
assert_rewritten "readonly PGREP_TOOL=\"${mock_bin}/pgrep\""
assert_rewritten "readonly TCCUTIL_TOOL=\"${mock_bin}/tccutil\""
assert_rewritten "readonly MKDIR_TOOL=\"${mock_bin}/mkdir\""
assert_rewritten "readonly MV_TOOL=\"${mock_bin}/mv\""
assert_rewritten "readonly RM_TOOL=\"${mock_bin}/rm\""
for original_tool_line in \
    'readonly SYSTEM_APPLICATIONS="/Applications"' \
    'readonly ID_TOOL="/usr/bin/id"' \
    'readonly DSCL_TOOL="/usr/bin/dscl"' \
    'readonly PLIST_BUDDY_TOOL="/usr/libexec/PlistBuddy"' \
    'readonly CODESIGN_TOOL="/usr/bin/codesign"' \
    'readonly SPCTL_TOOL="/usr/sbin/spctl"' \
    'readonly PGREP_TOOL="/usr/bin/pgrep"' \
    'readonly TCCUTIL_TOOL="/usr/bin/tccutil"' \
    'readonly MKDIR_TOOL="/bin/mkdir"' \
    'readonly MV_TOOL="/bin/mv"' \
    'readonly RM_TOOL="/bin/rm"'
do
    if /usr/bin/grep -Fq -- "${original_tool_line}" "${script_copy}"; then
        /usr/bin/printf 'Fixture setup failed; production command remains in transformed script: %s\n' \
            "${original_tool_line}" >&2
        exit 2
    fi
done
/bin/bash -n "${script_copy}"

TEST_ROOT="${test_root}"
FIXTURE_HOME="${test_root}/home"
FIXTURE_STATE="${test_root}/state"
export TEST_ROOT FIXTURE_HOME FIXTURE_STATE
FIXTURE_UID=501
export FIXTURE_UID
case_number=1
LAST_OUTPUT=""
LAST_STATUS=0

reset_case() {
    case_number=$((case_number + 1))
    /bin/rm -rf -- "${FIXTURE_HOME}" "${FIXTURE_STATE}" "${system_apps}"
    /bin/mkdir -p "${FIXTURE_HOME}" "${FIXTURE_STATE}" "${system_apps}"
    FIXTURE_LAUNCH_AT_CALL=""
    FIXTURE_LAUNCH_ROLE=""
    FIXTURE_PGREP_ERROR_AT_CALL=""
    FIXTURE_TCC_FAIL_ID=""
    FIXTURE_HELPER_FAIL=""
    FIXTURE_BAD_SIGNATURE=""
    MOCK_TEAM_IDENTIFIER=""
    export FIXTURE_LAUNCH_AT_CALL FIXTURE_LAUNCH_ROLE FIXTURE_PGREP_ERROR_AT_CALL
    export FIXTURE_TCC_FAIL_ID
    export FIXTURE_HELPER_FAIL FIXTURE_BAD_SIGNATURE MOCK_TEAM_IDENTIFIER
    FIXTURE_UID=501
    export FIXTURE_UID
}

make_app() {
    local apps_root="$1"
    local app_name="$2"
    local bundle_id="$3"
    local build="$4"
    local app_path="${apps_root}/${app_name}.app"
    /bin/mkdir -p "${app_path}/Contents/MacOS"
    /usr/bin/printf 'CFBundleIdentifier=%s\nCFBundleExecutable=%s\nCFBundleVersion=%s\n' \
        "$bundle_id" "$app_name" "$build" >"${app_path}/Contents/Info.plist"
    /bin/cat >"${app_path}/Contents/MacOS/${app_name}" <<'APP'
#!/bin/bash
printf '%s %s\n' "${0##*/}" "$*" >>"${FIXTURE_STATE}/helpers.log"
[[ "${FIXTURE_HELPER_FAIL:-}" != "${0##*/}" ]]
APP
    /bin/chmod 755 "${app_path}/Contents/MacOS/${app_name}"
}

capture_command() {
    if LAST_OUTPUT="$(/bin/bash "${script_copy}" "$@" 2>&1)"; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi
}

capture_input() {
    local input="$1"
    shift
    if LAST_OUTPUT="$(/usr/bin/printf '%s\n' "$input" | /bin/bash "${script_copy}" "$@" 2>&1)"; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi
}

fail() {
    /usr/bin/printf 'FAIL: %s\n%s\n' "$1" "${LAST_OUTPUT}" >&2
    exit 1
}

assert_status() {
    [[ "${LAST_STATUS}" == "$1" ]] || fail "expected exit $1, got ${LAST_STATUS}"
}

assert_contains() {
    case "${LAST_OUTPUT}" in *"$1"*) ;; *) fail "output did not contain: $1" ;; esac
}

assert_no_mutations() {
    [[ ! -e "${FIXTURE_STATE}/helpers.log" ]] || fail "app cleanup helper unexpectedly ran"
    [[ ! -e "${FIXTURE_STATE}/tcc.log" ]] || fail "TCC reset unexpectedly ran"
    [[ ! -e "${FIXTURE_STATE}/actions.log" ]] || fail "filesystem mutation unexpectedly ran"
}

assert_tcc_log() {
    local expected
    expected="$(/usr/bin/printf 'reset All com.rudinyu.MacRemoteApp.Host\nreset All com.rudinyu.MacRemoteApp.Viewer')"
    [[ -f "${FIXTURE_STATE}/tcc.log" ]] || fail "scoped TCC calls were not recorded"
    [[ "$(/bin/cat "${FIXTURE_STATE}/tcc.log")" == "${expected}" ]] || fail "unexpected TCC command scope"
}

echo "Fixture ${case_number}: help exits before consulting or mutating the host"
reset_case
capture_command --help
assert_status 0
assert_contains 'Local Network'
assert_no_mutations

echo "Fixture ${case_number}: dry-run reports running apps and performs no mutations"
reset_case
/bin/mkdir -p "${FIXTURE_HOME}/Applications"
make_app "${FIXTURE_HOME}/Applications" MacRemoteApp-Host com.rudinyu.MacRemoteApp.Host 1003
: >"${FIXTURE_STATE}/running.MacRemoteApp-Host"
capture_command --dry-run
assert_status 0
assert_contains 'Quit these apps before cleanup: Host'
assert_no_mutations

echo "Fixture ${case_number}: cancellation preserves apps and leftovers"
reset_case
/bin/mkdir -p "${FIXTURE_HOME}/Applications" "${FIXTURE_HOME}/Library/Preferences"
make_app "${FIXTURE_HOME}/Applications" MacRemoteApp-Host com.rudinyu.MacRemoteApp.Host 1003
leftover="${FIXTURE_HOME}/Library/Preferences/com.rudinyu.MacRemoteApp.Host.plist"
: >"${leftover}"
capture_input NO
assert_status 0
assert_contains 'Cancelled. Nothing was removed.'
[[ -f "${leftover}" && -d "${FIXTURE_HOME}/Applications/MacRemoteApp-Host.app" ]] || fail "cancellation changed fixture data"
assert_no_mutations

echo "Fixture ${case_number}: root execution is rejected"
reset_case
FIXTURE_UID=0
capture_command
assert_status 1
assert_contains 'Run this helper as your normal macOS user'
assert_no_mutations

echo "Fixture ${case_number}: symlinked Applications ancestor is rejected"
reset_case
/bin/mkdir -p "${test_root}/linked-applications"
/bin/ln -s "${test_root}/linked-applications" "${FIXTURE_HOME}/Applications"
capture_command --dry-run
assert_status 1
assert_contains 'symlinked or unsafe Applications path'
assert_no_mutations

echo "Fixture ${case_number}: symlinked Library data ancestor is rejected before cleanup"
reset_case
/bin/mkdir -p "${test_root}/outside-library/Preferences"
: >"${test_root}/outside-library/Preferences/com.rudinyu.MacRemoteApp.Host.plist"
/bin/ln -s "${test_root}/outside-library" "${FIXTURE_HOME}/Library"
capture_command --dry-run
assert_status 1
assert_contains 'unsafe or symlinked app-data path'
[[ -f "${test_root}/outside-library/Preferences/com.rudinyu.MacRemoteApp.Host.plist" ]] || fail "symlinked data target changed"
assert_no_mutations

echo "Fixture ${case_number}: invalid app signature is rejected"
reset_case
/bin/mkdir -p "${FIXTURE_HOME}/Applications"
make_app "${FIXTURE_HOME}/Applications" MacRemoteApp-Host com.rudinyu.MacRemoteApp.Host 1003
FIXTURE_BAD_SIGNATURE=1
capture_command --dry-run
assert_status 1
assert_contains 'failed code-signature verification'
assert_no_mutations

echo "Fixture ${case_number}: TeamIdentifier suffix spoof is rejected"
reset_case
/bin/mkdir -p "${FIXTURE_HOME}/Applications"
make_app "${FIXTURE_HOME}/Applications" MacRemoteApp-Host com.rudinyu.MacRemoteApp.Host 1003
MOCK_TEAM_IDENTIFIER=LYK4LV2859.suffix
capture_command --dry-run
assert_status 1
assert_contains 'without the MacRemoteApp Developer ID publisher'
assert_no_mutations

echo "Fixture ${case_number}: missing apps still clean exact leftovers and scoped TCC, but report Keychain gaps"
reset_case
/bin/mkdir -p "${FIXTURE_HOME}/Library/Preferences"
leftover="${FIXTURE_HOME}/Library/Preferences/com.rudinyu.MacRemoteApp.Host.plist"
: >"${leftover}"
capture_input UNINSTALL
assert_status 1
assert_contains 'Keychain cleanup for Host is unverified'
assert_contains 'MacRemoteApp cleanup is PARTIAL'
[[ ! -e "${leftover}" ]] || fail "app-owned leftover was not removed"
assert_tcc_log

echo "Fixture ${case_number}: builds below 1003 are retained and never executed"
reset_case
/bin/mkdir -p "${FIXTURE_HOME}/Applications"
old_app="${FIXTURE_HOME}/Applications/MacRemoteApp-Host.app"
make_app "${FIXTURE_HOME}/Applications" MacRemoteApp-Host com.rudinyu.MacRemoteApp.Host 1002
capture_input UNINSTALL
assert_status 1
assert_contains 'cleanup CLI requires build 1003 or newer'
assert_contains 'so this app will be retained'
[[ -d "${old_app}" ]] || fail "unsupported app bundle was removed"
[[ ! -e "${FIXTURE_STATE}/helpers.log" ]] || fail "unsupported app helper was executed"
assert_tcc_log

echo "Fixture ${case_number}: supported Host and Viewer helpers clean both roles and move apps to Trash"
reset_case
/bin/mkdir -p "${FIXTURE_HOME}/Applications"
host_app="${FIXTURE_HOME}/Applications/MacRemoteApp-Host.app"
viewer_app="${system_apps}/MacRemoteApp-Viewer.app"
trash="${FIXTURE_HOME}/.Trash"
make_app "${FIXTURE_HOME}/Applications" MacRemoteApp-Host com.rudinyu.MacRemoteApp.Host 1003
make_app "${system_apps}" MacRemoteApp-Viewer com.rudinyu.MacRemoteApp.Viewer 1008
capture_input UNINSTALL
assert_status 0
assert_contains 'MacRemoteApp cleanup completed'
[[ ! -e "${host_app}" && ! -e "${viewer_app}" ]] || fail "supported apps were not moved"
[[ -d "${trash}/MacRemoteApp-Host.app" && -d "${trash}/MacRemoteApp-Viewer.app" ]] || fail "apps did not reach fixture Trash"
expected_helpers="$(/usr/bin/printf 'MacRemoteApp-Host --remove-all-data\nMacRemoteApp-Viewer --remove-all-data')"
[[ "$(/bin/cat "${FIXTURE_STATE}/helpers.log")" == "${expected_helpers}" ]] || fail "wrong cleanup helper calls"
assert_tcc_log

echo "Fixture ${case_number}: helper failure is reported and retains its app"
reset_case
/bin/mkdir -p "${FIXTURE_HOME}/Applications"
failed_app="${FIXTURE_HOME}/Applications/MacRemoteApp-Host.app"
make_app "${FIXTURE_HOME}/Applications" MacRemoteApp-Host com.rudinyu.MacRemoteApp.Host 1003
FIXTURE_HELPER_FAIL=MacRemoteApp-Host
capture_input UNINSTALL
assert_status 1
assert_contains 'Keychain cleanup failed'
assert_contains 'MacRemoteApp cleanup is PARTIAL'
[[ -d "${failed_app}" ]] || fail "failed helper app was removed"
assert_tcc_log

echo "Fixture ${case_number}: TCC failure is not reported as successful cleanup"
reset_case
FIXTURE_TCC_FAIL_ID=com.rudinyu.MacRemoteApp.Host
capture_input UNINSTALL
assert_status 1
assert_contains 'TCC reset failed for com.rudinyu.MacRemoteApp.Host'
assert_contains 'MacRemoteApp cleanup is PARTIAL'
assert_tcc_log

echo "Fixture ${case_number}: relaunch after confirmation aborts before any mutation"
reset_case
/bin/mkdir -p "${FIXTURE_HOME}/Applications"
make_app "${FIXTURE_HOME}/Applications" MacRemoteApp-Host com.rudinyu.MacRemoteApp.Host 1003
FIXTURE_LAUNCH_AT_CALL=3
FIXTURE_LAUNCH_ROLE=MacRemoteApp-Host
capture_input UNINSTALL
assert_status 1
assert_contains 'cleanup was not started'
assert_no_mutations

echo "Fixture ${case_number}: pgrep errors are unknown state and abort before mutations"
reset_case
/bin/mkdir -p "${FIXTURE_HOME}/Applications"
make_app "${FIXTURE_HOME}/Applications" MacRemoteApp-Host com.rudinyu.MacRemoteApp.Host 1003
FIXTURE_PGREP_ERROR_AT_CALL=1
capture_command --dry-run
assert_status 1
assert_contains 'no cleanup was started'
assert_no_mutations
: >"${FIXTURE_STATE}/pgrep-count"
FIXTURE_PGREP_ERROR_AT_CALL=3
capture_input UNINSTALL
assert_status 1
assert_contains 'process status before starting cleanup after confirmation'
assert_no_mutations

echo "Fixture ${case_number}: relaunch before data cleanup prevents deletion and TCC reset"
reset_case
/bin/mkdir -p "${FIXTURE_HOME}/Applications" "${FIXTURE_HOME}/Library/Preferences"
make_app "${FIXTURE_HOME}/Applications" MacRemoteApp-Host com.rudinyu.MacRemoteApp.Host 1003
make_app "${FIXTURE_HOME}/Applications" MacRemoteApp-Viewer com.rudinyu.MacRemoteApp.Viewer 1003
leftover="${FIXTURE_HOME}/Library/Preferences/com.rudinyu.MacRemoteApp.Host.plist"
: >"${leftover}"
FIXTURE_LAUNCH_AT_CALL=9
FIXTURE_LAUNCH_ROLE=MacRemoteApp-Host
capture_input UNINSTALL
assert_status 1
assert_contains 'cleanup stopped before removing current-user app data'
[[ -f "${leftover}" ]] || fail "data was removed after a role relaunched"
[[ ! -e "${FIXTURE_STATE}/tcc.log" ]] || fail "TCC reset ran after a role relaunched"
[[ ! -e "${FIXTURE_STATE}/actions.log" ]] || fail "filesystem mutation ran after a role relaunched"

echo "Fixture ${case_number}: relaunch before TCC reset prevents the reset"
reset_case
/bin/mkdir -p "${FIXTURE_HOME}/Applications"
make_app "${FIXTURE_HOME}/Applications" MacRemoteApp-Host com.rudinyu.MacRemoteApp.Host 1003
make_app "${FIXTURE_HOME}/Applications" MacRemoteApp-Viewer com.rudinyu.MacRemoteApp.Viewer 1003
FIXTURE_LAUNCH_AT_CALL=9
FIXTURE_LAUNCH_ROLE=MacRemoteApp-Host
capture_input UNINSTALL
assert_status 1
assert_contains 'cleanup stopped before resetting scoped TCC'
[[ ! -e "${FIXTURE_STATE}/tcc.log" ]] || fail "TCC reset ran after a role relaunched"

echo "Fixture ${case_number}: relaunch before app move keeps both bundles in place"
reset_case
/bin/mkdir -p "${FIXTURE_HOME}/Applications"
host_app="${FIXTURE_HOME}/Applications/MacRemoteApp-Host.app"
viewer_app="${FIXTURE_HOME}/Applications/MacRemoteApp-Viewer.app"
make_app "${FIXTURE_HOME}/Applications" MacRemoteApp-Host com.rudinyu.MacRemoteApp.Host 1003
make_app "${FIXTURE_HOME}/Applications" MacRemoteApp-Viewer com.rudinyu.MacRemoteApp.Viewer 1003
FIXTURE_LAUNCH_AT_CALL=15
FIXTURE_LAUNCH_ROLE=MacRemoteApp-Host
capture_input UNINSTALL
assert_status 1
assert_contains 'cleanup stopped before moving Host to your Trash'
[[ -d "${host_app}" && -d "${viewer_app}" ]] || fail "an app moved after a role relaunched"
if [[ -f "${FIXTURE_STATE}/actions.log" ]] && /usr/bin/grep -q '^mv ' "${FIXTURE_STATE}/actions.log"; then
    fail "app move ran after a role relaunched"
fi
assert_tcc_log

echo "PASS: uninstall helper fixture safety, compatibility, and partial-cleanup cases"
