# M10 Debug log collection

This is the in-house Debug workflow. Debug Host and Debug Viewer each create a
shareable local JSONL file automatically at app launch. They do not upload
logs, and Viewer collection does not require Console.

1. Launch the signed Debug Host and Viewer app bundles on their respective
   Macs, then reproduce the issue once. Note its approximate UTC time and
   whether it appeared on Host, Viewer, or both.
2. For connection, authorization, selection, input, or blank-video failures,
   collect both endpoint logs. For an endpoint-only UI stall, collect that
   endpoint's log and the other one if it was connected.
3. Use the app's own Debug action when responsive: Host's **Open Debug Log…**
   status-menu item, or Viewer's **Open Debug Log…** application-menu item.
   Finder reveals the current file.
4. If an app is stuck and its menu cannot open, in Finder press
   **Command-Shift-G** and open the path for that role below. Copy the current
   log and its previous file if present. If the current file is busy, retry
   after the app responds.
5. Attach the role-specific current and previous files for each relevant endpoint.
   Mention whether the copy was taken while an app was still frozen.

The exact paths are:

- Host: `~/Library/Logs/MacRemoteApp/Host/m10-debug-host.log`
- Viewer: `~/Library/Logs/MacRemoteApp/Viewer/m10-debug-viewer.log`

The Host previous file is `m10-debug-host.previous.log`; the Viewer previous file
is `m10-debug-viewer.previous.log`. Each file is capped at 1 MiB; one previous
file is retained per role. Rotation replaces that role's older previous file,
so the oldest records eventually rotate out. Collect the files soon after reproduction.

## What is recorded

Both apps write the same versioned JSONL envelope. Records include UTC time, a
random per-process `run_id`, process-relative monotonic time, a per-run record
sequence, a local connection sequence, and app version/build. A new app launch
starts a new `run_id`; record sequence and monotonic time begin again within
that process. UTC time is used to correlate the two Macs. There are no shared
wire identifiers.

Fixed events and bounded aggregates record discovery permission and candidate
filter counts, catalog publication and Viewer eligible-window count, Viewer
selection sent and Host selection accepted/rejected, session authorization
and capabilities, input readiness, Host input totals and bounded queue/handler
timings, Host capture/encode/send totals, and Viewer receive/decode/presentation
totals. Host video authorization denial uses a fixed reason and whether the
pipeline recovered or stopped. MainActor scheduling gaps and AppKit run-loop
stalls are separate events. Five-second Viewer input windows count send
attempts, local acceptance, and failures by fixed event kind and fixed failure
subcategory. Event kinds distinguish classes such as `button_down` and
`key_up`, but do not record their values. Events are emitted on transitions or
low-frequency windows, never for every frame or input event.

Host `authorization_attempt.source` is one of
`connection_establishment`, `window_selection`, `input_authorization`, or
`clipboard_fallback`. The event includes success, requested window generation
when supplied, requested capability count, and fixed capability flags. On
success it also records the exact authorization generations before and after
the transition, plus reconnect, receive, and authorized-window generations.
Failed attempts have no transition fields. Host video denial records a fixed
reason; stale `authorization_changed` and `reconnect_required` are distinct,
with captured and observed authorization, reconnect, and receive generations.
Host input aggregates use the `connection_sequence` captured by the input
loop, including when a partial window flushes after a reconnect.

Viewer `input_window.input_event_kinds` counts fixed event classes such as
`mouse_move`, `button_down`, `button_up`, `scroll`, `key_down`, and `key_up`.
`failure_subcategories` distinguishes authorization-epoch mismatch before
admission, authorization change after admission but before transport,
reconnect/readiness rejection, capability denial, local preflight rejection,
uncertain transport delivery, other pre-transport rejection, and unclassified
failures. These are aggregate counts and contain no event payload.

Viewer `input_window.failure_categories` records the effective category, while
`underlying_failure_categories` retains the original fixed category when
held-state cleanup escalates an otherwise recoverable failure to
`held_state_release_failure`. The aggregate also includes
`failure_boundaries` (`before_transport_invocation`, `transport_send_started`,
or `unknown`) and `underlying_failure_categories_by_boundary`, a complete
category-by-boundary count matrix. Categories are `local_preflight`,
`capability_unavailable`, `authorization_not_ready`, `delivery_uncertain`,
`queue_overflow`, `held_state_release_failure`, and `unexpected`. The unknown
boundary is used when the available observation cannot prove whether
transport was invoked. These are counts only; there is no per-event payload,
raw error, coordinate, or key data.

When investigating a disconnect, compare `session_failure.category`,
`transport_termination.class`, and `peer_terminal.state` in the Host and Viewer
files. The first records the local coordinator's fixed failure category; the
second distinguishes `end_of_stream` from `failure`; the third records a peer
`close`, `session_stopping`, or `session_failed` signal. Together they show
which endpoint declared failure first while omitting raw transport error text.
These fields are available in Debug diagnostic builds starting with Build
1019.

The schema does not contain hostnames, peer identity, IP addresses, process or
window IDs, app/window names, coordinates, key/button/scroll values, clipboard
content, credentials, frame data, raw errors, or raw UI status text. If the
writer cannot append to the file, the app emits the fixed code
`DIAG_FILE_WRITE_FAILED`. The directory is private to the current user and the
file is created with restrictive permissions where supported.

Review the files before attaching them. Do not attach screenshots, clipboard
data, credentials, unrelated system logs, or a full Unified Logging export by
default. Release customer diagnostics are a separate future opt-in workflow;
this in-house Debug feature does not enable customer collection.
