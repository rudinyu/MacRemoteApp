#if DEBUG
import Foundation
import XCTest
@testable import Viewer

final class M10ViewerDebugDiagnosticsTests: XCTestCase {
    func testRunLoopStallPolicyIgnoresIdleWait() {
        XCTAssertFalse(M10ViewerRunLoopStallPolicy.detectsStall(
            from: .beforeWaiting,
            to: .afterWaiting,
            elapsedNanoseconds: 5_000_000_000
        ))
    }

    func testRunLoopStallPolicyDetectsLongSourceExecution() {
        XCTAssertTrue(M10ViewerRunLoopStallPolicy.detectsStall(
            from: .beforeSources,
            to: .beforeWaiting,
            elapsedNanoseconds: M10ViewerRunLoopStallPolicy.thresholdNanoseconds
        ))
    }

    func testHeartbeatElapsedDoesNotUnderflowWhenHeartbeatAdvancesWhileWatchdogWaitsForLock() {
        let watchdogSampledBeforeLock: UInt64 = 5_000_000_000
        let heartbeatWrittenWhileWatchdogWaited = watchdogSampledBeforeLock + 1

        XCTAssertNil(M10ViewerHeartbeatTiming.elapsedNanoseconds(
            now: watchdogSampledBeforeLock,
            since: heartbeatWrittenWhileWatchdogWaited
        ))
        XCTAssertEqual(M10ViewerHeartbeatTiming.elapsedNanoseconds(
            now: heartbeatWrittenWhileWatchdogWaited,
            since: heartbeatWrittenWhileWatchdogWaited
        ), 0)
        XCTAssertEqual(M10ViewerHeartbeatTiming.elapsedNanoseconds(
            now: heartbeatWrittenWhileWatchdogWaited + 7,
            since: heartbeatWrittenWhileWatchdogWaited
        ), 7)
    }

    func testProductionLogURLIsInTheViewerLibraryLogsDirectory() {
        let expectedURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacRemoteApp/Viewer/m10-debug-viewer.log")
        XCTAssertEqual(M10ViewerDiagnosticFileLog.logFileURL, expectedURL)
    }

    func testLifecycleRecorderWritesSharedJSONLEnvelopeAndTypedEvents() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("m10-debug-viewer.log")
        let log = M10ViewerDiagnosticFileLog(fileURL: url)
        let recorder = M10ViewerDiagnosticRecorder(fileLog: log)
        recorder.start()
        recorder.recordConnectionStarted()
        let snapshot = M10ViewerSessionDiagnosticSnapshot(
            state: .streaming,
            authorized: true,
            windowAuthorized: true,
            videoCapability: true,
            mouseCapability: true,
            keyboardCapability: true,
            windowSelectionCapability: true,
            clipboardCapability: false,
            backgroundControlCapability: false
        )
        recorder.recordSessionState(snapshot)
        recorder.recordSessionState(snapshot)
        recorder.recordWindowCatalog(eligibleCount: 0, selected: false)
        recorder.recordWindowSelection(.requested)
        recorder.recordWindowSelection(.sent)
        recorder.recordWindowSelection(.hostAcknowledged)
        recorder.recordInputReadiness(.hostPermissionUnavailable, reason: .hostPermission, keyboardAvailable: false)
        recorder.recordInputReadiness(.hostPermissionUnavailable, reason: .hostPermission, keyboardAvailable: false)
        recorder.record(.videoWindow(received: 12, presented: 0, decodeFailures: 1, durationMilliseconds: 5_000))
        recorder.record(.runLoopStalled(durationMilliseconds: 1_900, phase: .beforeWaiting))
        recorder.waitForPendingWrites()

        let records = try readJSONLines(at: url)
        XCTAssertEqual(records.map { $0["event"] as? String }, [
            "startup", "connection_started", "session_state", "window_catalog",
            "window_selection", "window_selection", "window_selection", "input_readiness",
            "video_window", "run_loop_stalled"
        ])
        XCTAssertEqual(records[0]["schema_version"] as? Int, 1)
        XCTAssertEqual(records[0]["role"] as? String, "viewer")
        XCTAssertNotNil(records[0]["run_id"] as? String)
        XCTAssertNotNil(records[0]["app_version"] as? String)
        XCTAssertNotNil(records[0]["app_build"] as? String)
        XCTAssertNotNil(records[0]["timestamp_utc"] as? String)
        XCTAssertNotNil(records[0]["monotonic_process_ms"] as? Int)
        XCTAssertEqual(records[0]["connection_sequence"] as? Int, 0)
        XCTAssertEqual(records[1]["connection_sequence"] as? Int, 1)
        XCTAssertEqual(records[2]["video_capability"] as? Bool, true)
        XCTAssertEqual(records[3]["eligible"] as? Int, 0)
        XCTAssertEqual(records[6]["state"] as? String, "host_acknowledged")
        XCTAssertEqual(records[7]["reason"] as? String, "host_permission")
        XCTAssertEqual(records[8]["received"] as? Int, 12)
        XCTAssertEqual(records[8]["presented"] as? Int, 0)
        XCTAssertEqual(records[9]["phase"] as? String, "before_waiting")
        for record in records {
            XCTAssertNotNil(record["app_version"])
            XCTAssertNotNil(record["app_build"])
            XCTAssertNotNil(record["timestamp_utc"])
            XCTAssertNotNil(record["monotonic_process_ms"])
            XCTAssertNotNil(record["run_sequence"])
            XCTAssertFalse(record.keys.contains("error"))
            XCTAssertFalse(record.keys.contains("hostname"))
            XCTAssertFalse(record.keys.contains("window_id"))
        }
    }

    func testPrivacyWhitelistAndMetadataSanitization() throws {
        let data = M10ViewerDiagnosticEvent.inputReadiness(
            readiness: .hostFocusUnavailable,
            reason: .hostFocus,
            keyboardAvailable: false
        ).line(
            at: Date(timeIntervalSince1970: 1_797_000_000),
            sequence: 42,
            connectionSequence: 3,
            monotonicProcessMilliseconds: 900,
            appVersion: "private-host-name.local",
            appBuild: "token/secret"
        )
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allowed: Set<String> = [
            "schema_version", "role", "run_id", "app_version", "app_build", "timestamp_utc",
            "monotonic_process_ms", "run_sequence", "connection_sequence", "event",
            "readiness", "reason", "keyboard_available"
        ]
        XCTAssertTrue(Set(record.keys).isSubset(of: allowed))
        XCTAssertEqual(record["app_version"] as? String, "unknown")
        XCTAssertEqual(record["app_build"] as? String, "unknown")
        XCTAssertNil(record["error"])
        XCTAssertNil(record["peer"])
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("private-host-name"))
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("token/secret"))
        for prohibited in ["process_id", "coordinates", "key_value", "button_value", "clipboard_content", "peer_identity"] {
            XCTAssertNil(record[prohibited], "Unexpected field: \(prohibited)")
        }
    }

    func testFailureAndPeerTerminationDiagnosticsUseOnlyFixedValues() throws {
        let commonKeys: Set<String> = [
            "schema_version", "role", "run_id", "app_version", "app_build", "timestamp_utc",
            "monotonic_process_ms", "run_sequence", "connection_sequence", "event"
        ]
        let cases: [(M10ViewerDiagnosticEvent, String, String, String)] = [
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

    func testVideoWindowAccumulatorCountsAndEmitsBlankPresentationEvidence() {
        var accumulator = M10ViewerVideoWindowAccumulator()
        let start: UInt64 = 50_000_000_000
        accumulator.begin(at: start)
        (0..<12).forEach { _ in accumulator.recordReceived() }
        accumulator.recordDecodeFailure()
        XCTAssertNil(accumulator.takeSummaryIfDue(at: start + 4_999_000_000))

        let summary = accumulator.takeSummaryIfDue(at: start + 5_000_000_000)
        XCTAssertEqual(summary, M10ViewerVideoWindowSummary(
            received: 12,
            presented: 0,
            decodeFailures: 1,
            durationMilliseconds: 5_000
        ))
        XCTAssertEqual(
            accumulator.takeSummaryIfDue(at: start + 10_000_000_000),
            M10ViewerVideoWindowSummary(
                received: 0,
                presented: 0,
                decodeFailures: 0,
                durationMilliseconds: 5_000
            )
        )
    }

    func testVideoWindowAccumulatorFlushesPartialStreamSummary() {
        var accumulator = M10ViewerVideoWindowAccumulator()
        let start: UInt64 = 60_000_000_000
        accumulator.begin(at: start)
        accumulator.recordReceived()
        accumulator.recordPresented()
        accumulator.recordDecodeFailure()

        XCTAssertEqual(
            accumulator.takePendingSummary(at: start + 1_750_000_000),
            M10ViewerVideoWindowSummary(
                received: 1,
                presented: 1,
                decodeFailures: 1,
                durationMilliseconds: 1_750
            )
        )
        XCTAssertNil(accumulator.takeSummaryIfDue(at: start + 6_750_000_000))
    }

    func testPartialVideoSummaryPrecedesNextConnectionAndKeepsOldSequence() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("m10-debug-viewer.log")
        let writer = M10ViewerDiagnosticFileLog(fileURL: url)
        let recorder = M10ViewerDiagnosticRecorder(fileLog: writer)
        recorder.start()
        let start: UInt64 = 120_000_000_000
        recorder.recordConnectionStarted(atUptimeNanoseconds: start)
        var accumulator = M10ViewerVideoWindowAccumulator()
        accumulator.begin(at: start)
        accumulator.recordReceived()
        accumulator.recordPresented()

        let summary = try XCTUnwrap(accumulator.takePendingSummary(at: start + 2_500_000_000))
        recorder.recordVideoWindowSummary(summary)
        recorder.recordConnectionStarted(atUptimeNanoseconds: start + 2_500_000_000)
        recorder.waitForPendingWrites()

        let records = try readJSONLines(at: url)
        XCTAssertEqual(records.map { $0["event"] as? String }, [
            "startup", "connection_started", "video_window", "connection_started"
        ])
        XCTAssertEqual(records[1]["connection_sequence"] as? Int, 1)
        XCTAssertEqual(records[2]["connection_sequence"] as? Int, 1)
        XCTAssertEqual(records[2]["received"] as? Int, 1)
        XCTAssertEqual(records[2]["duration_ms"] as? Int, 2_500)
        XCTAssertEqual(records[3]["connection_sequence"] as? Int, 2)
    }

    func testViewerInputWindowEmitsLocalSendOutcomeCountsWithoutPayload() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("m10-debug-viewer.log")
        let writer = M10ViewerDiagnosticFileLog(fileURL: url)
        let recorder = M10ViewerDiagnosticRecorder(fileLog: writer)
        recorder.start()
        let start: UInt64 = 80_000_000_000
        recorder.recordConnectionStarted(atUptimeNanoseconds: start)
        recorder.recordViewerInputAttempt()
        recorder.recordViewerInputLocallyAccepted()
        recorder.recordViewerInputAttempt()
        recorder.recordViewerInputSendFailure()
        recorder.recordViewerInputFailureCategory(.deliveryUncertain)
        recorder.recordViewerInputFailureContext(
            underlyingCategory: .deliveryUncertain,
            boundary: .transportSendStarted
        )
        recorder.recordViewerInputAttempt()
        recorder.recordViewerInputSendFailure()
        recorder.recordViewerInputFailureCategory(.heldStateReleaseFailure)
        recorder.recordViewerInputFailureContext(
            underlyingCategory: .authorizationNotReady,
            boundary: .beforeTransportInvocation
        )
        recorder.flushInputWindowIfDue(atUptimeNanoseconds: start + 4_999_000_000)
        writer.waitForPendingWrites()
        XCTAssertEqual(try readJSONLines(at: url).map { $0["event"] as? String }, [
            "startup", "connection_started"
        ])

        recorder.flushInputWindowIfDue(atUptimeNanoseconds: start + 5_000_000_000)
        recorder.flushInputWindowIfDue(atUptimeNanoseconds: start + 10_000_000_000)
        writer.waitForPendingWrites()
        let records = try readJSONLines(at: url)
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(records[2]["event"] as? String, "input_window")
        XCTAssertEqual(records[2]["attempted"] as? Int, 3)
        XCTAssertEqual(records[2]["locally_accepted"] as? Int, 1)
        XCTAssertEqual(records[2]["send_failures"] as? Int, 2)
        let failureCategories = try XCTUnwrap(records[2]["failure_categories"] as? [String: Int])
        XCTAssertEqual(Set(failureCategories.keys), Set(ViewerInputFailureCategory.allCases.map(\.rawValue)))
        XCTAssertEqual(failureCategories[ViewerInputFailureCategory.deliveryUncertain.rawValue], 1)
        XCTAssertEqual(failureCategories[ViewerInputFailureCategory.heldStateReleaseFailure.rawValue], 1)
        XCTAssertEqual(failureCategories[ViewerInputFailureCategory.localPreflight.rawValue], 0)
        let underlyingCategories = try XCTUnwrap(records[2]["underlying_failure_categories"] as? [String: Int])
        XCTAssertEqual(Set(underlyingCategories.keys), Set(ViewerInputFailureCategory.allCases.map(\.rawValue)))
        XCTAssertEqual(underlyingCategories[ViewerInputFailureCategory.authorizationNotReady.rawValue], 1)
        XCTAssertEqual(underlyingCategories[ViewerInputFailureCategory.heldStateReleaseFailure.rawValue], 0)
        let boundaries = try XCTUnwrap(records[2]["failure_boundaries"] as? [String: Int])
        XCTAssertEqual(Set(boundaries.keys), Set(ViewerInputSendBoundary.allCases.map(\.rawValue)))
        XCTAssertEqual(boundaries[ViewerInputSendBoundary.beforeTransportInvocation.rawValue], 1)
        XCTAssertEqual(boundaries[ViewerInputSendBoundary.transportSendStarted.rawValue], 1)
        XCTAssertEqual(boundaries[ViewerInputSendBoundary.unknown.rawValue], 0)
        let categoriesByBoundary = try XCTUnwrap(
            records[2]["underlying_failure_categories_by_boundary"] as? [String: [String: Int]]
        )
        XCTAssertEqual(Set(categoriesByBoundary.keys), Set(ViewerInputSendBoundary.allCases.map(\.rawValue)))
        let preTransportCategories = try XCTUnwrap(
            categoriesByBoundary[ViewerInputSendBoundary.beforeTransportInvocation.rawValue]
        )
        let postTransportCategories = try XCTUnwrap(
            categoriesByBoundary[ViewerInputSendBoundary.transportSendStarted.rawValue]
        )
        XCTAssertEqual(Set(preTransportCategories.keys), Set(ViewerInputFailureCategory.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(postTransportCategories.keys), Set(ViewerInputFailureCategory.allCases.map(\.rawValue)))
        XCTAssertEqual(preTransportCategories[ViewerInputFailureCategory.authorizationNotReady.rawValue], 1)
        XCTAssertEqual(postTransportCategories[ViewerInputFailureCategory.deliveryUncertain.rawValue], 1)
        XCTAssertEqual(preTransportCategories[ViewerInputFailureCategory.heldStateReleaseFailure.rawValue], 0)
        XCTAssertNil(records[2]["error"])
        XCTAssertEqual(records[2]["duration_ms"] as? Int, 5_000)
        XCTAssertEqual(records[3]["event"] as? String, "input_window")
        XCTAssertEqual(records[3]["attempted"] as? Int, 0)
        XCTAssertEqual(records[3]["locally_accepted"] as? Int, 0)
        XCTAssertEqual(records[3]["send_failures"] as? Int, 0)
        XCTAssertEqual(
            try XCTUnwrap(records[3]["underlying_failure_categories"] as? [String: Int])[
                ViewerInputFailureCategory.authorizationNotReady.rawValue
            ],
            0
        )
        XCTAssertEqual(
            try XCTUnwrap(records[3]["failure_boundaries"] as? [String: Int])[
                ViewerInputSendBoundary.transportSendStarted.rawValue
            ],
            0
        )
        let allowed: Set<String> = [
            "schema_version", "role", "run_id", "app_version", "app_build", "timestamp_utc",
            "monotonic_process_ms", "run_sequence", "connection_sequence", "event",
            "attempted", "locally_accepted", "send_failures", "failure_categories",
            "underlying_failure_categories", "failure_boundaries",
            "underlying_failure_categories_by_boundary", "duration_ms"
        ]
        XCTAssertTrue(Set(records[2].keys).isSubset(of: allowed))
        XCTAssertFalse(String(data: try Data(contentsOf: url), encoding: .utf8)!.contains("key_code"))
        XCTAssertFalse(String(data: try Data(contentsOf: url), encoding: .utf8)!.contains("coordinates"))
    }

    func testPendingInputSummaryKeepsItsPriorConnectionSequence() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("m10-debug-viewer.log")
        let writer = M10ViewerDiagnosticFileLog(fileURL: url)
        let recorder = M10ViewerDiagnosticRecorder(fileLog: writer)
        recorder.start()
        let start: UInt64 = 100_000_000_000
        recorder.recordConnectionStarted(atUptimeNanoseconds: start)
        recorder.recordViewerInputAttempt()
        recorder.recordViewerInputLocallyAccepted()

        recorder.recordConnectionStarted(atUptimeNanoseconds: start + 2_000_000_000)
        writer.waitForPendingWrites()

        let records = try readJSONLines(at: url)
        XCTAssertEqual(records.map { $0["event"] as? String }, [
            "startup", "connection_started", "input_window", "connection_started"
        ])
        XCTAssertEqual(records[2]["connection_sequence"] as? Int, 1)
        XCTAssertEqual(records[2]["duration_ms"] as? Int, 2_000)
        XCTAssertEqual(records[3]["connection_sequence"] as? Int, 2)
    }

    func testSeparateLaunchWritersAppendWithoutOverwritingAndStartNewRunSequence() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("m10-debug-viewer.log")
        let firstWriter = M10ViewerDiagnosticFileLog(fileURL: url)
        firstWriter.record(.startup)
        firstWriter.waitForPendingWrites()
        let first = try XCTUnwrap(readJSONLines(at: url).first)

        let secondWriter = M10ViewerDiagnosticFileLog(fileURL: url)
        secondWriter.record(.startup)
        secondWriter.waitForPendingWrites()
        let records = try readJSONLines(at: url)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["run_sequence"] as? Int, 1)
        XCTAssertEqual(records[1]["run_sequence"] as? Int, 1)
        XCTAssertNotEqual(records[0]["run_id"] as? String, records[1]["run_id"] as? String)
        XCTAssertNotEqual(first["run_id"] as? String, records[1]["run_id"] as? String)
        XCTAssertEqual(records.map { $0["event"] as? String }, ["startup", "startup"])
    }

    func testRotatesWithinOneCurrentAndOnePreviousFile() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("m10-debug-viewer.log")
        let previous = directory.appendingPathComponent("m10-debug-viewer.previous.log")
        let maximumSize = 512
        let writer = M10ViewerDiagnosticFileLog(fileURL: current, maximumFileSizeBytes: maximumSize)
        for value in 0..<20 {
            writer.record(.mainActorStalled(durationMilliseconds: UInt64(value)))
        }
        writer.waitForPendingWrites()
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertLessThanOrEqual(try size(at: current), maximumSize)
        XCTAssertLessThanOrEqual(try size(at: previous), maximumSize)
    }

    func testWriterFailureIsContainedAndHasFixedDiagnosticCode() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
        let writer = M10ViewerDiagnosticFileLog(fileURL: blocker.appendingPathComponent("m10-debug-viewer.log"))
        writer.record(.startup)
        writer.waitForPendingWrites()
        XCTAssertTrue(writer.didFailForTesting)
        XCTAssertEqual(M10ViewerDiagnosticFileLog.fileWriteFailureCode, "DIAG_FILE_WRITE_FAILED")
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
            .appendingPathComponent("M10ViewerDebugDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func size(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}
#endif
