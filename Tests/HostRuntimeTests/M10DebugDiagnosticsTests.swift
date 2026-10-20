#if DEBUG
import Foundation
import XCTest
import RemoteProtocol
@testable import Host

final class M10DebugDiagnosticsTests: XCTestCase {
    func testRunLoopStallPolicyIgnoresIdleWait() {
        XCTAssertFalse(M10HostRunLoopStallPolicy.detectsStall(
            from: .beforeWaiting,
            to: .afterWaiting,
            elapsedNanoseconds: 5_000_000_000
        ))
    }

    func testRunLoopStallPolicyDetectsLongSourceExecution() {
        XCTAssertTrue(M10HostRunLoopStallPolicy.detectsStall(
            from: .beforeSources,
            to: .beforeWaiting,
            elapsedNanoseconds: M10HostRunLoopStallPolicy.thresholdNanoseconds
        ))
    }

    func testHeartbeatElapsedDoesNotUnderflowWhenHeartbeatAdvancesWhileWatchdogWaitsForLock() {
        let watchdogSampledBeforeLock: UInt64 = 5_000_000_000
        let heartbeatWrittenWhileWatchdogWaited = watchdogSampledBeforeLock + 1

        XCTAssertNil(M10HostHeartbeatTiming.elapsedNanoseconds(
            now: watchdogSampledBeforeLock,
            since: heartbeatWrittenWhileWatchdogWaited
        ))
        XCTAssertEqual(M10HostHeartbeatTiming.elapsedNanoseconds(
            now: heartbeatWrittenWhileWatchdogWaited,
            since: heartbeatWrittenWhileWatchdogWaited
        ), 0)
        XCTAssertEqual(M10HostHeartbeatTiming.elapsedNanoseconds(
            now: heartbeatWrittenWhileWatchdogWaited + 7,
            since: heartbeatWrittenWhileWatchdogWaited
        ), 7)
    }

    func testFailureAndPeerTerminationDiagnosticsUseOnlyFixedValues() throws {
        let commonKeys: Set<String> = [
            "schema_version", "role", "run_id", "app_version", "app_build", "timestamp_utc",
            "monotonic_process_ms", "run_sequence", "connection_sequence", "event"
        ]
        let cases: [(M10HostDiagnosticEvent, String, String, String)] = [
            (.sessionFailure(.heartbeatTimeout), "session_failure", "category", "heartbeat_timeout"),
            (.sessionFailure(.transportFailure), "session_failure", "category", "transport_failure"),
            (.transportTermination(.endOfStream), "transport_termination", "class", "end_of_stream"),
            (.transportTermination(.failure), "transport_termination", "class", "failure"),
            (.peerTerminal(.close), "peer_terminal", "state", "close"),
            (.peerTerminal(.sessionStopping), "peer_terminal", "state", "session_stopping"),
            (.peerTerminal(.sessionFailed), "peer_terminal", "state", "session_failed")
        ]

        for (event, expectedEvent, field, value) in cases {
            let data = event.line(at: Date(timeIntervalSince1970: 1_797_000_000))
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(record["event"] as? String, expectedEvent)
            XCTAssertEqual(record[field] as? String, value)
            XCTAssertEqual(Set(record.keys), commonKeys.union([field]))
            let text = String(data: data, encoding: .utf8)!
            XCTAssertFalse(text.contains("clipboard contents"))
            XCTAssertFalse(text.contains("window title"))
            XCTAssertFalse(text.contains("coordinates"))
        }
    }

    func testVideoSessionErrorsKeepAuthorizationAndReconnectReasonsDistinct() {
        XCTAssertEqual(
            M10HostVideoAuthorizationReason.forSessionError(.authorizationChanged),
            .authorizationChanged
        )
        XCTAssertEqual(
            M10HostVideoAuthorizationReason.forSessionError(.reconnectRequired),
            .reconnectRequired
        )
        XCTAssertNil(M10HostVideoAuthorizationReason.forSessionError(.transportEOF))
    }

    func testAuthorizationAttemptUsesFixedSourceAndExactTransitionReceipt() throws {
        let transition = M10HostAuthorizationDiagnosticTransition(
            previousAuthorizationGeneration: 8,
            authorizationGeneration: 9,
            reconnectGeneration: 4,
            receiveGeneration: 6
        )
        let capabilities = M10HostCapabilityDiagnosticFlags([.h264Video, .mouseInput, .textClipboard])
        let data = M10HostDiagnosticEvent.authorizationAttempt(
            source: .windowSelection,
            succeeded: true,
            transition: transition,
            requestedWindowGeneration: 72,
            requestedCapabilities: capabilities
        ).line(at: Date(timeIntervalSince1970: 1_797_000_000))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allowed: Set<String> = [
            "schema_version", "role", "run_id", "app_version", "app_build", "timestamp_utc",
            "monotonic_process_ms", "run_sequence", "connection_sequence", "event", "source", "succeeded",
            "authorization_generation_before", "authorization_generation_after", "reconnect_generation",
            "receive_generation", "requested_window_generation", "authorized_window_generation",
            "requested_capability_count", "requested_video_capability",
            "requested_window_selection_capability", "requested_mouse_capability", "requested_keyboard_capability",
            "requested_clipboard_capability", "requested_background_control_capability",
            "requested_input_source_sync_capability", "requested_keyframe_request_capability",
            "requested_receiver_report_capability", "requested_ping_pong_capability"
        ]
        XCTAssertEqual(record["event"] as? String, "authorization_attempt")
        XCTAssertEqual(record["source"] as? String, "window_selection")
        XCTAssertEqual(record["succeeded"] as? Bool, true)
        XCTAssertEqual(record["authorization_generation_before"] as? Int, 8)
        XCTAssertEqual(record["authorization_generation_after"] as? Int, 9)
        XCTAssertEqual(record["reconnect_generation"] as? Int, 4)
        XCTAssertEqual(record["receive_generation"] as? Int, 6)
        XCTAssertEqual(record["requested_window_generation"] as? Int, 72)
        XCTAssertEqual(record["authorized_window_generation"] as? Int, 72)
        XCTAssertEqual(record["requested_capability_count"] as? Int, 3)
        XCTAssertEqual(record["requested_video_capability"] as? Bool, true)
        XCTAssertEqual(record["requested_mouse_capability"] as? Bool, true)
        XCTAssertEqual(record["requested_clipboard_capability"] as? Bool, true)
        XCTAssertTrue(Set(record.keys).isSubset(of: allowed))
        let encoded = String(data: data, encoding: .utf8)!
        for prohibited in ["peer", "window_title", "authorization_token", "clipboard_content", "error"] {
            XCTAssertFalse(encoded.contains(prohibited), "Unexpected diagnostic detail: \(prohibited)")
        }

        let failed = M10HostDiagnosticEvent.authorizationAttempt(
            source: .inputAuthorization,
            succeeded: false,
            transition: nil,
            requestedWindowGeneration: nil,
            requestedCapabilities: M10HostCapabilityDiagnosticFlags([])
        ).line(at: Date(timeIntervalSince1970: 1_797_000_000))
        let failedRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: failed) as? [String: Any])
        XCTAssertEqual(failedRecord["source"] as? String, "input_authorization")
        XCTAssertEqual(failedRecord["succeeded"] as? Bool, false)
        XCTAssertNil(failedRecord["authorization_generation_before"])
        XCTAssertNil(failedRecord["authorization_generation_after"])
    }

    func testProductionLogURLIsInTheHostLibraryLogsDirectory() {
        let expectedURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacRemoteApp/Host/m10-debug-host.log")
        XCTAssertEqual(M10HostDiagnosticFileLog.logFileURL, expectedURL)
    }

    func testForegroundRestoreStepsUseOnlyFixedValues() throws {
        let directoryURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let logURL = directoryURL.appendingPathComponent("m10-debug-host.log")
        let writer = M10HostDiagnosticFileLog(fileURL: logURL)
        let date = Date(timeIntervalSince1970: 1_797_000_000)

        writer.record(.foregroundRestore(stage: .sameWindowRequest, outcome: .started, accessibilityTrusted: false), at: date)
        writer.record(.foregroundRestore(stage: .unminimize, outcome: .refused, accessibilityTrusted: true), at: date)
        writer.record(.foregroundRestore(stage: .accessibilityFrontmost, outcome: .unconfirmed, accessibilityTrusted: true), at: date)
        writer.record(.foregroundRestore(stage: .finished, outcome: .confirmed, accessibilityTrusted: true), at: date)
        writer.waitForPendingWrites()

        let records = try readJSONLines(at: logURL).filter { $0["event"] as? String == "foreground_restore" }
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(records.map { $0["stage"] as? String }, [
            "same_window_request", "unminimize", "accessibility_frontmost", "finished"
        ])
        XCTAssertEqual(records.map { $0["outcome"] as? String }, [
            "started", "refused", "unconfirmed", "confirmed"
        ])
        XCTAssertEqual(records.first?["accessibility_trusted"] as? Bool, false)
        for record in records {
            XCTAssertNil(record["title"], "No window title may be recorded.")
            XCTAssertNil(record["application"], "No app name may be recorded.")
        }
    }

    func testWritesVersionedJSONLEnvelopeAndLifecycleAggregates() throws {
        let directoryURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let logURL = directoryURL.appendingPathComponent("m10-debug-host.log")
        let writer = M10HostDiagnosticFileLog(fileURL: logURL)
        let date = Date(timeIntervalSince1970: 1_797_000_000)

        writer.record(.startup, at: date)
        writer.record(.connectionStarted, at: date)
        writer.record(.connectionOutcome(.connected), at: date)
        writer.record(.mainActorStalled(durationMilliseconds: 812), at: date)
        writer.record(.mainActorRecovered(durationMilliseconds: 1_240), at: date)
        writer.record(.runLoopStalled(durationMilliseconds: 900, phase: .beforeWaiting), at: date)
        writer.record(.runLoopRecovered(durationMilliseconds: 900, phase: .afterWaiting), at: date)
        writer.record(.screenRecordingPermission(.authorized), at: date)
        writer.record(.windowCatalog(
            permission: .authorized,
            outcome: .allCandidatesFiltered,
            candidates: 7,
            eligible: 0,
            offScreen: 2,
            nonBaseLayer: 1,
            missingApplication: 1,
            helperApplication: 2,
            invalidWindow: 1
        ), at: date)
        writer.record(.windowSelection(.requested), at: date)
        writer.record(.videoAuthorizationDenied(
            reason: .windowGenerationMismatch,
            recovered: false,
            capturedAuthorizationGeneration: 6,
            observedAuthorizationGeneration: 7,
            capturedReconnectGeneration: 2,
            observedReconnectGeneration: 2,
            capturedReceiveGeneration: 5,
            observedReceiveGeneration: 5
        ), at: date)
        writer.record(.inputTotals(
            received: 8,
            inputEventKinds: [
                .mouseMove: 3,
                .buttonDown: 2,
                .buttonUp: 1,
                .scroll: 1,
                .keyDown: 1
            ],
            admitted: 5,
            queued: 2,
            injected: 4,
            rejected: 3,
            selectionTransition: 1,
            authorization: 1,
            permission: 0,
            focus: 0,
            target: 0,
            invalidEvent: 1,
            cleanup: 0,
            other: 0,
            queueWaitSamples: 5,
            queueWaitTotalMilliseconds: 13,
            queueWaitMaximumMilliseconds: 7,
            handlerSamples: 5,
            handlerTotalMilliseconds: 6,
            handlerMaximumMilliseconds: 3
        ), at: date)
        writer.waitForPendingWrites()

        let records = try readJSONLines(at: logURL)
        XCTAssertEqual(records.count, 12)
        XCTAssertEqual(records.first?["schema_version"] as? Int, 1)
        XCTAssertEqual(records.first?["role"] as? String, "host")
        XCTAssertNotNil(records.first?["run_id"] as? String)
        XCTAssertNotNil(records.first?["app_version"] as? String)
        XCTAssertNotNil(records.first?["app_build"] as? String)
        XCTAssertEqual(records.first?["timestamp_utc"] as? String, "2026-12-11T14:40:00.000Z")
        XCTAssertEqual(records[1]["event"] as? String, "connection_started")
        XCTAssertEqual(records[1]["connection_sequence"] as? Int, 1)
        XCTAssertEqual(records[2]["connection_sequence"] as? Int, 1)
        XCTAssertEqual(records[3]["event"] as? String, "main_actor_stalled")
        XCTAssertEqual(records[5]["phase"] as? String, "before_waiting")
        XCTAssertEqual(records[8]["event"] as? String, "window_catalog_discovery")
        XCTAssertEqual(records[8]["candidates"] as? Int, 7)
        XCTAssertEqual(records[8]["helper_application"] as? Int, 2)
        XCTAssertEqual(records[10]["reason"] as? String, "window_generation_mismatch")
        XCTAssertEqual(records[10]["pipeline"] as? String, "stopped")
        XCTAssertEqual(records[10]["captured_authorization_generation"] as? Int, 6)
        XCTAssertEqual(records[10]["observed_authorization_generation"] as? Int, 7)
        XCTAssertEqual(records[10]["captured_reconnect_generation"] as? Int, 2)
        XCTAssertEqual(records[10]["captured_receive_generation"] as? Int, 5)
        XCTAssertEqual(records[10]["observed_receive_generation"] as? Int, 5)
        XCTAssertEqual(records[11]["event"] as? String, "input_window")
        XCTAssertEqual(records[11]["received"] as? Int, 8)
        let hostInputKinds = try XCTUnwrap(records[11]["input_event_kinds"] as? [String: Int])
        XCTAssertEqual(Set(hostInputKinds.keys), Set(M10HostInputEventKind.allCases.map(\.rawValue)))
        XCTAssertEqual(hostInputKinds[M10HostInputEventKind.mouseMove.rawValue], 3)
        XCTAssertEqual(hostInputKinds[M10HostInputEventKind.buttonDown.rawValue], 2)
        XCTAssertEqual(hostInputKinds[M10HostInputEventKind.buttonUp.rawValue], 1)
        XCTAssertEqual(records[11]["admitted"] as? Int, 5)
        XCTAssertEqual(records[11]["queued"] as? Int, 2)
        XCTAssertEqual(records[11]["queue_wait_max_ms"] as? Int, 7)
        let inputAllowedKeys: Set<String> = [
            "schema_version", "role", "run_id", "app_version", "app_build", "timestamp_utc",
            "monotonic_process_ms", "run_sequence", "connection_sequence", "event", "received",
            "input_event_kinds", "admitted", "queued", "injected", "rejected", "selection_transition",
            "authorization", "permission", "focus", "target", "invalid_event", "cleanup", "other",
            "queue_wait_samples", "queue_wait_total_ms", "queue_wait_max_ms", "handler_samples",
            "handler_total_ms", "handler_max_ms"
        ]
        XCTAssertTrue(Set(records[11].keys).isSubset(of: inputAllowedKeys))
        let inputText = String(data: try Data(contentsOf: logURL), encoding: .utf8)!
        for prohibited in ["key_code", "coordinates", "button_value", "clipboard_content", "window_title", "process_name"] {
            XCTAssertFalse(inputText.contains(prohibited), "Unexpected private input detail: \(prohibited)")
        }
    }

    func testEventSchemaHasOnlyWhitelistedFieldsAndSanitizesMetadata() throws {
        let data = M10HostDiagnosticEvent.sessionState(
            state: .streaming,
            authorized: true,
            windowAuthorized: true,
            videoCapability: true,
            mouseCapability: true,
            keyboardCapability: false,
            windowSelectionCapability: true,
            clipboardCapability: false,
            backgroundControlCapability: false
        ).line(
            at: Date(timeIntervalSince1970: 1_797_000_000),
            appVersion: "private-host-name.local",
            appBuild: "build/secret"
        )
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allowed: Set<String> = [
            "schema_version", "role", "run_id", "app_version", "app_build", "timestamp_utc",
            "monotonic_process_ms", "run_sequence", "connection_sequence", "event",
            "state", "authorized", "window_authorized", "video_capability", "mouse_capability",
            "keyboard_capability", "window_selection_capability", "clipboard_capability",
            "background_control_capability"
        ]
        XCTAssertTrue(Set(record.keys).isSubset(of: allowed))
        XCTAssertEqual(record["app_version"] as? String, "unknown")
        XCTAssertEqual(record["app_build"] as? String, "unknown")
        XCTAssertNil(record["error"])
        XCTAssertNil(record["window_id"])
        XCTAssertNil(record["hostname"])
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("private-host-name"))
        for prohibited in ["process_id", "coordinates", "key_value", "button_value", "clipboard_content", "peer_identity"] {
            XCTAssertNil(record[prohibited], "Unexpected field: \(prohibited)")
        }
    }

    func testSeparateLaunchWritersAppendWithoutOverwritingAndStartNewRunSequence() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("m10-debug-host.log")
        let firstWriter = M10HostDiagnosticFileLog(fileURL: url)
        firstWriter.record(.startup)
        firstWriter.waitForPendingWrites()
        let first = try XCTUnwrap(readJSONLines(at: url).first)

        let secondWriter = M10HostDiagnosticFileLog(fileURL: url)
        secondWriter.record(.startup)
        secondWriter.waitForPendingWrites()
        let records = try readJSONLines(at: url)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["event"] as? String, "startup")
        XCTAssertEqual(records[1]["event"] as? String, "startup")
        XCTAssertEqual(records[0]["run_sequence"] as? Int, 1)
        XCTAssertEqual(records[1]["run_sequence"] as? Int, 1)
        XCTAssertNotEqual(records[0]["run_id"] as? String, records[1]["run_id"] as? String)
        XCTAssertNotNil(records[0]["monotonic_process_ms"] as? Int)
        XCTAssertNotNil(records[1]["monotonic_process_ms"] as? Int)
        XCTAssertNotEqual(first["run_id"] as? String, records[1]["run_id"] as? String)
    }

    func testVideoAggregateCountersEmitOneBoundedWindowSummary() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("m10-debug-host.log")
        let writer = M10HostDiagnosticFileLog(fileURL: url)
        let video = M10HostVideoDiagnostics(fileLog: writer)
        let start: UInt64 = 10_000_000_000
        video.beginWindow(at: start)
        video.recordCaptured()
        video.recordCaptured()
        video.recordEncoded()
        video.recordSendQueued()
        video.recordDropped()
        video.flushIfDue(at: start + 4_999_000_000)
        writer.waitForPendingWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        video.flushIfDue(at: start + 5_000_000_000)
        writer.waitForPendingWrites()
        let records = try readJSONLines(at: url)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["event"] as? String, "video_window")
        XCTAssertEqual(records[0]["captured"] as? Int, 2)
        XCTAssertEqual(records[0]["encoded"] as? Int, 1)
        XCTAssertEqual(records[0]["send_queued"] as? Int, 1)
        XCTAssertEqual(records[0]["dropped"] as? Int, 1)
        XCTAssertEqual(records[0]["duration_ms"] as? Int, 5_000)
    }

    func testVideoAggregateCountersFlushPartialWindowAtTransition() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("m10-debug-host.log")
        let writer = M10HostDiagnosticFileLog(fileURL: url)
        let video = M10HostVideoDiagnostics(fileLog: writer)
        let start: UInt64 = 20_000_000_000
        video.beginWindow(at: start)
        video.recordCaptured()
        video.recordEncoded()

        video.flushPendingWindow(at: start + 1_250_000_000)
        video.flushIfDue(at: start + 6_249_000_000)
        writer.waitForPendingWrites()

        let records = try readJSONLines(at: url)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["event"] as? String, "video_window")
        XCTAssertEqual(records[0]["captured"] as? Int, 1)
        XCTAssertEqual(records[0]["encoded"] as? Int, 1)
        XCTAssertEqual(records[0]["duration_ms"] as? Int, 1_250)
    }

    func testPartialVideoSummaryPrecedesNextConnectionAndKeepsOldSequence() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("m10-debug-host.log")
        let writer = M10HostDiagnosticFileLog(fileURL: url)
        let video = M10HostVideoDiagnostics(fileLog: writer)
        let start: UInt64 = 30_000_000_000
        let date = Date(timeIntervalSince1970: 1_797_000_000)
        writer.record(.connectionStarted, at: date, monotonicNanoseconds: start)
        video.beginWindow(at: start)
        video.recordSendQueued()

        video.flushPendingWindow(at: start + 2_000_000_000)
        writer.record(
            .connectionStarted,
            at: date,
            monotonicNanoseconds: start + 2_000_000_000
        )
        writer.waitForPendingWrites()

        let records = try readJSONLines(at: url)
        XCTAssertEqual(records.map { $0["event"] as? String }, [
            "connection_started", "video_window", "connection_started"
        ])
        XCTAssertEqual(records[0]["connection_sequence"] as? Int, 1)
        XCTAssertEqual(records[1]["connection_sequence"] as? Int, 1)
        XCTAssertEqual(records[1]["duration_ms"] as? Int, 2_000)
        XCTAssertEqual(records[2]["connection_sequence"] as? Int, 2)
    }

    func testInputSummaryRemainsBoundToItsConnectionAfterReconnectStarts() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("m10-debug-host.log")
        let writer = M10HostDiagnosticFileLog(fileURL: url)
        let diagnostics = M10HostInputDiagnostics(fileLog: writer)
        let firstSequence = writer.recordConnectionStarted()
        diagnostics.recordReceived(kind: .mouseMove, connectionSequence: firstSequence)
        diagnostics.recordRejected(.permission, connectionSequence: firstSequence)

        let secondSequence = writer.recordConnectionStarted()
        diagnostics.recordReceived(kind: .buttonDown, connectionSequence: secondSequence)
        diagnostics.recordInjected(connectionSequence: secondSequence)
        diagnostics.finishConnection(connectionSequence: firstSequence)
        diagnostics.finishConnection(connectionSequence: secondSequence)
        writer.waitForPendingWrites()

        let records = try readJSONLines(at: url)
        let summaries = records.filter { $0["event"] as? String == "input_window" }
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries[0]["connection_sequence"] as? Int, 1)
        XCTAssertEqual(summaries[0]["received"] as? Int, 1)
        XCTAssertEqual(
            try XCTUnwrap(summaries[0]["input_event_kinds"] as? [String: Int])[M10HostInputEventKind.mouseMove.rawValue],
            1
        )
        XCTAssertEqual(summaries[0]["permission"] as? Int, 1)
        XCTAssertEqual(summaries[0]["injected"] as? Int, 0)
        XCTAssertEqual(summaries[1]["connection_sequence"] as? Int, 2)
        XCTAssertEqual(summaries[1]["received"] as? Int, 1)
        XCTAssertEqual(
            try XCTUnwrap(summaries[1]["input_event_kinds"] as? [String: Int])[M10HostInputEventKind.buttonDown.rawValue],
            1
        )
        XCTAssertEqual(summaries[1]["permission"] as? Int, 0)
        XCTAssertEqual(summaries[1]["injected"] as? Int, 1)
    }

    func testHostInputEventKindsClassifyOnlyFixedInputKinds() {
        let messages = [
            InputEventMessage(kind: .pointerMove, windowGeneration: 1, x: 10, y: 20),
            InputEventMessage(kind: .pointerButton, windowGeneration: 1, x: 10, y: 20, button: 2, pressed: true),
            InputEventMessage(kind: .pointerButton, windowGeneration: 1, x: 10, y: 20, button: 2, pressed: false),
            InputEventMessage(kind: .scroll, windowGeneration: 1, deltaX: 12, deltaY: -4),
            InputEventMessage(kind: .keyDown, windowGeneration: 1, keyCode: 42),
            InputEventMessage(kind: .keyUp, windowGeneration: 1, keyCode: 42)
        ]

        XCTAssertEqual(messages.map(M10HostInputEventKind.forMessage), [
            .mouseMove, .buttonDown, .buttonUp, .scroll, .keyDown, .keyUp
        ])
        XCTAssertEqual(Set(M10HostInputEventKind.allCases.map(\.rawValue)), [
            "mouse_move", "button_down", "button_up", "scroll", "key_down", "key_up", "focus_intent", "other"
        ])
    }

    func testRotatesWithinOneCurrentAndOnePreviousFile() throws {
        let directoryURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let logURL = directoryURL.appendingPathComponent("m10-debug-host.log")
        let previousURL = directoryURL.appendingPathComponent("m10-debug-host.previous.log")
        let maximumSize = 512
        let writer = M10HostDiagnosticFileLog(fileURL: logURL, maximumFileSizeBytes: maximumSize)
        for count in 0..<20 {
            writer.record(.mainActorStalled(durationMilliseconds: UInt64(count)))
        }
        writer.waitForPendingWrites()

        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previousURL.path))
        XCTAssertLessThanOrEqual(try fileSize(at: logURL), maximumSize)
        XCTAssertLessThanOrEqual(try fileSize(at: previousURL), maximumSize)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("m10-debug-host.previous.1.log").path))
    }

    func testCreatesPrivateHostDirectoryAndLogFile() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let directoryURL = rootURL.appendingPathComponent("Logs/MacRemoteApp/Host", isDirectory: true)
        let logURL = directoryURL.appendingPathComponent("m10-debug-host.log")
        let writer = M10HostDiagnosticFileLog(fileURL: logURL)
        writer.record(.startup)
        writer.waitForPendingWrites()
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directoryURL.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testWriterFailureIsContainedAndHasFixedDiagnosticCode() throws {
        let rootURL = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let blockerURL = rootURL.appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(atPath: blockerURL.path, contents: Data()))
        let logURL = blockerURL.appendingPathComponent("m10-debug-host.log")
        let writer = M10HostDiagnosticFileLog(fileURL: logURL)
        writer.record(.startup)
        writer.waitForPendingWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertTrue(writer.didFailForTesting)
        XCTAssertEqual(M10HostDiagnosticFileLog.fileWriteFailureCode, "DIAG_FILE_WRITE_FAILED")
    }

    private func readJSONLines(at url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        let lines = try XCTUnwrap(String(data: data, encoding: .utf8)).split(separator: "\n")
        return try lines.map { line in
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let required: Set<String> = [
                "schema_version", "role", "run_id", "app_version", "app_build", "timestamp_utc",
                "monotonic_process_ms", "run_sequence", "connection_sequence", "event"
            ]
            XCTAssertTrue(required.isSubset(of: Set(record.keys)))
            return record
        }
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("M10DebugDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}
#endif
