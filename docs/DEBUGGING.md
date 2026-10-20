# MacRemoteApp How to Debug

Use the Debug Host and Debug Viewer for in-house reproduction. Both apps
automatically create a local, bounded JSON Lines (JSONL) diagnostic file when
they launch. No Terminal command, Console search, or separate log collector is
needed. Logs stay on their Mac; the apps do not upload them.

## Reproduce and collect

1. Launch the Debug Host and Debug Viewer as signed app bundles on their
   respective Macs. Confirm Host Screen Recording and PostEvent permissions;
   P6 foreground control follows the same global secure-input policy as legacy
   input, and accepted Host pairing is required. Target-process Accessibility
   inspection is used only for safe inactive-target cleanup. Explicitly select the target window so Host
   foregrounds its regular app; verify input stops if that app loses focus.
   Start from a fresh launch when a separate run boundary is
   useful.
2. Reproduce the issue once and note the approximate UTC time and which
   endpoint showed it. For connection, selection, blank-video, or input issues,
   collect both endpoint files.
3. Use Host's **Open Debug Log…** status-menu item or Viewer's
   **Open Debug Log…** application-menu item. Finder reveals that app's current
   log. If the app is unresponsive, use Finder's **Go to Folder**
   (`Command-Shift-G`) and open the role-specific path below.
4. Attach `m10-debug-host.log` and, if present, `m10-debug-host.previous.log` from Host,
   and `m10-debug-viewer.log` plus `m10-debug-viewer.previous.log` from Viewer when present.
   Say whether a copy was taken while the app was frozen.

The Host writes to:

`~/Library/Logs/MacRemoteApp/Host/m10-debug-host.log`

The Viewer writes to:

`~/Library/Logs/MacRemoteApp/Viewer/m10-debug-viewer.log`

Each file is capped at 1 MiB. Host retains `m10-debug-host.previous.log`; Viewer retains
`m10-debug-viewer.previous.log`. Rotation replaces the older previous file, so
the oldest records eventually rotate out. Copy both files soon after reproduction.
If Finder cannot copy a file while it is being written, retry after the app responds.

## Reading the evidence

Both roles use the same versioned JSONL envelope. Each record has a UTC
timestamp, a process-relative monotonic time, a random process `run_id`, a
per-run record sequence, and a local connection sequence. The run identifier
changes on each process launch; monotonic time and record sequence restart
within that run. UTC timestamps are the cross-Mac correlation point. There are
no shared wire identifiers in the logs.

Events connect Host Screen Recording permission and fixed candidate-filter
counts to catalog publication, then Viewer catalog count and selection request
to Host acceptance or rejection. Session authorization, capabilities, and
input readiness use fixed states. Five-second aggregates report Host video
capture/encode/send outcomes and Viewer receive/decode/presentation counts. A
Viewer `received` count with `presented: 0` is blank-display evidence. Host
input totals separate received, admitted, queued, injected, and rejected
events, with fixed rejection categories, bounded queue/handler timings, and
aggregate counts by fixed event kind. Viewer input windows count send attempts,
locally accepted sends, and failures; they also report aggregate counts by
fixed event kind and bounded failure subcategory. These fields identify only
event classes such as `button_down` or `key_up`, never their values.
MainActor scheduling gaps and AppKit main-run-loop stalls are recorded
separately, with durations and fixed run-loop phases only.

Host `foreground_restore` records trace each explicit request to bring the
selected app forward, including same-window Select. `stage` is one of
`same_window_request`, `coalesced`, `target_missing`, `not_permitted`,
`unhide`, `unminimize`, `cooperative_yield`, `accessibility_frontmost`,
`launch_services_activation`, or `finished`; `outcome` is one of `started`,
`ignored`, `rejected`, `accepted`, `refused`, `confirmed`, or `unconfirmed`;
and `accessibility_trusted` records whether the Host had Accessibility trust.
No app name, window title, or window identifier is recorded.

Host authorization records use the fixed `source` values
`connection_establishment`, `window_selection`, `input_authorization`, and
`clipboard_fallback`. `authorization_attempt` includes `succeeded`, requested
window generation when present, requested capability count and fixed
capability flags. A successful record also contains the exact
`authorization_generation_before` and `authorization_generation_after`, plus
`reconnect_generation`, `receive_generation`, and
`authorized_window_generation`. Failed attempts do not claim a generation
transition. These values are numeric metadata; no peer, window, or capability
name is included.

When Host video authorization is denied, `video_authorization_denied.reason`
distinguishes `authorization_changed` from `reconnect_required` and also
records captured and observed authorization, reconnect, and receive
generations. Host `input_window` aggregates are attributed by the
`connection_sequence` captured when that input loop starts. A delayed flush
keeps the originating connection sequence after a reconnect.

Viewer `input_window.input_event_kinds` counts fixed classes such as
`mouse_move`, `button_down`, `button_up`, `scroll`, `key_down`, and `key_up`.
`failure_subcategories` separates expected authorization-epoch mismatch before
admission, authorization change after admission but before transport,
reconnect/readiness rejection, capability denial, local preflight rejection,
uncertain transport delivery, other pre-transport rejection, and unclassified
failures. These are aggregate counts; values and coordinates are not recorded.
The event also contains effective `failure_categories` and the underlying
fixed `underlying_failure_categories`, so an
`authorization_not_ready` failure remains visible if held-state cleanup
escalates its effective result to `held_state_release_failure`. The
`failure_boundaries` values are `before_transport_invocation`,
`transport_send_started`, and `unknown`; the
`underlying_failure_categories_by_boundary` object preserves the count for
each category at each boundary. Unknown is used when the available observation
cannot prove whether transport was invoked. All are aggregate counts, not
per-input-event records.

For a disconnect, compare `session_failure.category`,
`transport_termination.class`, and `peer_terminal.state` across both files.
`session_failure` identifies the local coordinator's fixed failure category;
`transport_termination` distinguishes `end_of_stream` from `failure`, and
`peer_terminal` records a received `close`, `session_stopping`, or
`session_failed` signal. These fields help identify which endpoint declared
failure first without recording the underlying transport error text. Older
builds do not emit these fields.

Records are emitted on state changes or low-frequency aggregate windows; they
do not include per-frame or per-input-event payloads. The file writer runs on a
utility queue. If it cannot write, it reports the fixed diagnostic code
`DIAG_FILE_WRITE_FAILED` through Unified Logging; do not collect a full system
log unless a developer specifically requests a narrowly scoped item.

## Privacy and scope

The schema is fixed and privacy-whitelisted. It records only fixed event names
and enum values, counts, timings, booleans, app version/build, UTC time, and
local process/connection sequence values. It does not record hostnames, peer
identity, IP addresses, process or window IDs, app/window names, coordinates,
key/button/scroll values, clipboard content, credentials, frame data, or raw
errors and UI status text. Review the files before attaching them and do not
include unrelated logs or screenshots by default.

This workflow is for in-house Debug testing. Customer collection from Release
apps is a separate future opt-in workflow and is not enabled by these changes.
