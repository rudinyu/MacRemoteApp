import Foundation
import RemoteProtocol
import TransportCore

enum M10HostAuthorizationSource: String, Sendable {
    case connectionEstablishment = "connection_establishment"
    case windowSelection = "window_selection"
    case inputAuthorization = "input_authorization"
    case clipboardFallback = "clipboard_fallback"
}

#if DEBUG
import CoreFoundation
import os

enum M10DebugRole: String {
    case host
}

enum M10HostSessionState: String, Equatable, Sendable {
    case discovered
    case connecting
    case authenticated
    case pairingRequired = "pairing_required"
    case trusted
    case capabilitiesNegotiated = "capabilities_negotiated"
    case windowSelectionAuthorized = "window_selection_authorized"
    case streaming
    case stopping
    case reconnecting
    case failed
}

enum M10HostScreenRecordingPermission: String, Equatable, Sendable {
    case authorized
    case denied
}

enum M10HostDiscoveryOutcome: String, Equatable, Sendable {
    case eligibleWindows = "eligible_windows"
    case noCandidates = "no_candidates"
    case allCandidatesFiltered = "all_candidates_filtered"
    case permissionDenied = "permission_denied"
    case providerError = "provider_error"
}

enum M10HostVideoAuthorizationReason: String, Equatable, Sendable {
    case sessionUnauthorized = "session_unauthorized"
    case missingCapability = "missing_capability"
    case windowGenerationMismatch = "window_generation_mismatch"
    case authorizationChanged = "authorization_changed"
    case reconnectRequired = "reconnect_required"
    case other

    static func forSessionError(_ error: SessionError) -> Self? {
        switch error {
        case .authorizationChanged: .authorizationChanged
        case .reconnectRequired: .reconnectRequired
        default: nil
        }
    }
}

enum M10HostConnectionOutcome: String, Sendable {
    case connected
    case pairingDenied = "pairing_denied"
    case sessionFailure = "session_failure"
    case connectionFailure = "connection_failure"
}

enum M10HostPeerTerminalState: String, Sendable {
    case close
    case sessionStopping = "session_stopping"
    case sessionFailed = "session_failed"
}

enum M10HostWindowSelection: String, Sendable {
    case requested
    case accepted
    case rejected
}

enum M10HostInputReadiness: String, Equatable, Sendable {
    case ready
    case cleanupPending = "cleanup_pending"
    case sessionUnauthorized = "session_unauthorized"
    case selectionUnavailable = "selection_unavailable"
    case capabilityUnavailable = "capability_unavailable"
    case permissionUnavailable = "permission_unavailable"
    case focusUnavailable = "focus_unavailable"
}

enum M10HostInputEventKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case mouseMove = "mouse_move"
    case buttonDown = "button_down"
    case buttonUp = "button_up"
    case scroll
    case keyDown = "key_down"
    case keyUp = "key_up"
    case focusIntent = "focus_intent"
    case other

    static func forMessage(_ input: InputEventMessage) -> Self {
        switch input.kind {
        case .pointerMove: .mouseMove
        case .pointerButton:
            switch input.pressed {
            case true?: .buttonDown
            case false?: .buttonUp
            case nil: .other
            }
        case .scroll: .scroll
        case .keyDown: .keyDown
        case .keyUp: .keyUp
        case .focusIntent: .focusIntent
        }
    }
}

enum M10HostRunLoopPhase: String, Sendable {
    case beforeSources = "before_sources"
    case beforeWaiting = "before_waiting"
    case afterWaiting = "after_waiting"
    case exit
}

enum M10HostRunLoopStallPolicy {
    static let thresholdNanoseconds: UInt64 = 750_000_000

    static func detectsStall(
        from startPhase: M10HostRunLoopPhase,
        to endPhase: M10HostRunLoopPhase,
        elapsedNanoseconds: UInt64
    ) -> Bool {
        startPhase == .beforeSources
            && endPhase == .beforeWaiting
            && elapsedNanoseconds >= thresholdNanoseconds
    }
}

enum M10HostHeartbeatTiming {
    static func elapsedNanoseconds(now: UInt64, since timestamp: UInt64) -> UInt64? {
        guard now >= timestamp else { return nil }
        return now - timestamp
    }
}

struct M10HostSessionDiagnosticSnapshot: Equatable {
    let state: M10HostSessionState
    let authorized: Bool
    let windowAuthorized: Bool
    let videoCapability: Bool
    let mouseCapability: Bool
    let keyboardCapability: Bool
    let windowSelectionCapability: Bool
    let clipboardCapability: Bool
    let backgroundControlCapability: Bool
}

struct M10HostWindowCatalogDiagnosticSnapshot: Equatable {
    let permission: M10HostScreenRecordingPermission
    let outcome: M10HostDiscoveryOutcome
    let candidates: UInt64
    let eligible: UInt64
    let offScreen: UInt64
    let nonBaseLayer: UInt64
    let missingApplication: UInt64
    let helperApplication: UInt64
    let invalidWindow: UInt64
}

struct M10HostCapabilityDiagnosticFlags: Sendable {
    let count: UInt64
    let video: Bool
    let windowSelection: Bool
    let mouseInput: Bool
    let keyboardInput: Bool
    let clipboard: Bool
    let backgroundControl: Bool
    let inputSourceSync: Bool
    let keyframeRequest: Bool
    let receiverReport: Bool
    let pingPong: Bool

    init(_ capabilities: Set<Capability>) {
        count = UInt64(capabilities.count)
        video = capabilities.contains(.h264Video)
        windowSelection = capabilities.contains(.windowSelection)
        mouseInput = capabilities.contains(.mouseInput)
        keyboardInput = capabilities.contains(.keyboardInput)
        clipboard = capabilities.contains(.textClipboard)
        backgroundControl = capabilities.contains(.backgroundControl)
        inputSourceSync = capabilities.contains(.inputSourceSync)
        keyframeRequest = capabilities.contains(.keyframeRequest)
        receiverReport = capabilities.contains(.receiverReport)
        pingPong = capabilities.contains(.pingPong)
    }
}

struct M10HostAuthorizationDiagnosticTransition: Sendable {
    let previousAuthorizationGeneration: UInt64
    let authorizationGeneration: UInt64
    let reconnectGeneration: UInt64
    let receiveGeneration: UInt64

    init(_ transition: SessionAuthorizationTransition) {
        previousAuthorizationGeneration = transition.previousAuthorizationGeneration
        authorizationGeneration = transition.authorizationGeneration
        reconnectGeneration = transition.reconnectGeneration
        receiveGeneration = transition.receiveGeneration
    }

    init(
        previousAuthorizationGeneration: UInt64,
        authorizationGeneration: UInt64,
        reconnectGeneration: UInt64,
        receiveGeneration: UInt64
    ) {
        self.previousAuthorizationGeneration = previousAuthorizationGeneration
        self.authorizationGeneration = authorizationGeneration
        self.reconnectGeneration = reconnectGeneration
        self.receiveGeneration = receiveGeneration
    }
}

/// Fixed, redacted records written by the Debug Host. Event values are typed
/// so callers cannot add arbitrary strings or input payloads to this file.
enum M10HostDiagnosticEvent: Sendable {
    case startup
    case connectionStarted
    case connectionOutcome(M10HostConnectionOutcome)
    case sessionFailure(SessionFailureCategory)
    case transportTermination(TransportTerminationClass)
    case peerTerminal(M10HostPeerTerminalState)
    case mainActorStalled(durationMilliseconds: UInt64)
    case mainActorRecovered(durationMilliseconds: UInt64)
    case runLoopStalled(durationMilliseconds: UInt64, phase: M10HostRunLoopPhase)
    case runLoopRecovered(durationMilliseconds: UInt64, phase: M10HostRunLoopPhase)
    case sessionState(
        state: M10HostSessionState,
        authorized: Bool,
        windowAuthorized: Bool,
        videoCapability: Bool,
        mouseCapability: Bool,
        keyboardCapability: Bool,
        windowSelectionCapability: Bool,
        clipboardCapability: Bool,
        backgroundControlCapability: Bool
    )
    case screenRecordingPermission(M10HostScreenRecordingPermission)
    case windowCatalogPublished(eligibleCount: UInt64)
    case windowSelection(M10HostWindowSelection)
    case inputReadiness(M10HostInputReadiness)
    case windowCatalog(
        permission: M10HostScreenRecordingPermission,
        outcome: M10HostDiscoveryOutcome,
        candidates: UInt64,
        eligible: UInt64,
        offScreen: UInt64,
        nonBaseLayer: UInt64,
        missingApplication: UInt64,
        helperApplication: UInt64,
        invalidWindow: UInt64
    )
    case videoAuthorizationDenied(
        reason: M10HostVideoAuthorizationReason,
        recovered: Bool,
        capturedAuthorizationGeneration: UInt64,
        observedAuthorizationGeneration: UInt64,
        capturedReconnectGeneration: UInt64,
        observedReconnectGeneration: UInt64,
        capturedReceiveGeneration: UInt64,
        observedReceiveGeneration: UInt64
    )
    case authorizationAttempt(
        source: M10HostAuthorizationSource,
        succeeded: Bool,
        transition: M10HostAuthorizationDiagnosticTransition?,
        requestedWindowGeneration: UInt64?,
        requestedCapabilities: M10HostCapabilityDiagnosticFlags
    )
    case videoWindow(
        captured: UInt64,
        encoded: UInt64,
        encodeFailures: UInt64,
        sendQueued: UInt64,
        dropped: UInt64,
        sendFailures: UInt64,
        durationMilliseconds: UInt64
    )
    case inputTotals(
        received: UInt64,
        inputEventKinds: [M10HostInputEventKind: UInt64],
        admitted: UInt64,
        queued: UInt64,
        injected: UInt64,
        rejected: UInt64,
        selectionTransition: UInt64,
        authorization: UInt64,
        permission: UInt64,
        focus: UInt64,
        target: UInt64,
        invalidEvent: UInt64,
        cleanup: UInt64,
        other: UInt64,
        queueWaitSamples: UInt64,
        queueWaitTotalMilliseconds: UInt64,
        queueWaitMaximumMilliseconds: UInt64,
        handlerSamples: UInt64,
        handlerTotalMilliseconds: UInt64,
        handlerMaximumMilliseconds: UInt64
    )

    var startsConnection: Bool {
        if case .connectionStarted = self { return true }
        return false
    }

    func line(
        at date: Date,
        sequence: UInt64 = 1,
        connectionSequence: UInt64 = 0,
        runID: String = "00000000-0000-0000-0000-000000000000",
        monotonicProcessMilliseconds: UInt64 = 0,
        appVersion: String = "0.2",
        appBuild: String = "test"
    ) -> Data {
        let event: String
        var fields: [String: Any] = [:]
        switch self {
        case .startup:
            event = "startup"
        case .connectionStarted:
            event = "connection_started"
        case let .connectionOutcome(outcome):
            event = "connection_outcome"
            fields["state"] = outcome.rawValue
        case let .sessionFailure(category):
            event = "session_failure"
            fields["category"] = category.rawValue
        case let .transportTermination(terminationClass):
            event = "transport_termination"
            fields["class"] = terminationClass.rawValue
        case let .peerTerminal(state):
            event = "peer_terminal"
            fields["state"] = state.rawValue
        case let .mainActorStalled(durationMilliseconds):
            event = "main_actor_stalled"
            fields["duration_ms"] = durationMilliseconds
        case let .mainActorRecovered(durationMilliseconds):
            event = "main_actor_recovered"
            fields["duration_ms"] = durationMilliseconds
        case let .runLoopStalled(durationMilliseconds, phase):
            event = "run_loop_stalled"
            fields["duration_ms"] = durationMilliseconds
            fields["phase"] = phase.rawValue
        case let .runLoopRecovered(durationMilliseconds, phase):
            event = "run_loop_recovered"
            fields["duration_ms"] = durationMilliseconds
            fields["phase"] = phase.rawValue
        case let .sessionState(state, authorized, windowAuthorized, videoCapability, mouseCapability, keyboardCapability, windowSelectionCapability, clipboardCapability, backgroundControlCapability):
            event = "session_state"
            fields["state"] = state.rawValue
            fields["authorized"] = authorized
            fields["window_authorized"] = windowAuthorized
            fields["video_capability"] = videoCapability
            fields["mouse_capability"] = mouseCapability
            fields["keyboard_capability"] = keyboardCapability
            fields["window_selection_capability"] = windowSelectionCapability
            fields["clipboard_capability"] = clipboardCapability
            fields["background_control_capability"] = backgroundControlCapability
        case let .screenRecordingPermission(permission):
            event = "screen_recording_permission"
            fields["state"] = permission.rawValue
        case let .windowCatalogPublished(eligibleCount):
            event = "window_catalog_published"
            fields["eligible"] = eligibleCount
        case let .windowSelection(state):
            event = "window_selection"
            fields["state"] = state.rawValue
        case let .inputReadiness(state):
            event = "input_readiness"
            fields["state"] = state.rawValue
        case let .windowCatalog(
            permission,
            outcome,
            candidates,
            eligible,
            offScreen,
            nonBaseLayer,
            missingApplication,
            helperApplication,
            invalidWindow
        ):
            event = "window_catalog_discovery"
            fields["permission"] = permission.rawValue
            fields["outcome"] = outcome.rawValue
            fields["candidates"] = candidates
            fields["eligible"] = eligible
            fields["off_screen"] = offScreen
            fields["non_base_layer"] = nonBaseLayer
            fields["missing_application"] = missingApplication
            fields["helper_application"] = helperApplication
            fields["invalid_window"] = invalidWindow
        case let .videoAuthorizationDenied(
            reason,
            recovered,
            capturedAuthorizationGeneration,
            observedAuthorizationGeneration,
            capturedReconnectGeneration,
            observedReconnectGeneration,
            capturedReceiveGeneration,
            observedReceiveGeneration
        ):
            event = "video_authorization_denied"
            fields["reason"] = reason.rawValue
            fields["pipeline"] = recovered ? "recovered" : "stopped"
            fields["captured_authorization_generation"] = capturedAuthorizationGeneration
            fields["observed_authorization_generation"] = observedAuthorizationGeneration
            fields["captured_reconnect_generation"] = capturedReconnectGeneration
            fields["observed_reconnect_generation"] = observedReconnectGeneration
            fields["captured_receive_generation"] = capturedReceiveGeneration
            fields["observed_receive_generation"] = observedReceiveGeneration
        case let .authorizationAttempt(source, succeeded, transition, requestedWindowGeneration, requestedCapabilities):
            event = "authorization_attempt"
            fields["source"] = source.rawValue
            fields["succeeded"] = succeeded
            fields["requested_capability_count"] = requestedCapabilities.count
            fields["requested_video_capability"] = requestedCapabilities.video
            fields["requested_window_selection_capability"] = requestedCapabilities.windowSelection
            fields["requested_mouse_capability"] = requestedCapabilities.mouseInput
            fields["requested_keyboard_capability"] = requestedCapabilities.keyboardInput
            fields["requested_clipboard_capability"] = requestedCapabilities.clipboard
            fields["requested_background_control_capability"] = requestedCapabilities.backgroundControl
            fields["requested_input_source_sync_capability"] = requestedCapabilities.inputSourceSync
            fields["requested_keyframe_request_capability"] = requestedCapabilities.keyframeRequest
            fields["requested_receiver_report_capability"] = requestedCapabilities.receiverReport
            fields["requested_ping_pong_capability"] = requestedCapabilities.pingPong
            if let requestedWindowGeneration {
                fields["requested_window_generation"] = requestedWindowGeneration
            }
            if let transition {
                if let requestedWindowGeneration {
                    fields["authorized_window_generation"] = requestedWindowGeneration
                }
                fields["authorization_generation_before"] = transition.previousAuthorizationGeneration
                fields["authorization_generation_after"] = transition.authorizationGeneration
                fields["reconnect_generation"] = transition.reconnectGeneration
                fields["receive_generation"] = transition.receiveGeneration
            }
        case let .videoWindow(captured, encoded, encodeFailures, sendQueued, dropped, sendFailures, durationMilliseconds):
            event = "video_window"
            fields["captured"] = captured
            fields["encoded"] = encoded
            fields["encode_failures"] = encodeFailures
            fields["send_queued"] = sendQueued
            fields["dropped"] = dropped
            fields["send_failures"] = sendFailures
            fields["duration_ms"] = durationMilliseconds
        case let .inputTotals(
            received,
            inputEventKinds,
            admitted,
            queued,
            injected,
            rejected,
            selectionTransition,
            authorization,
            permission,
            focus,
            target,
            invalidEvent,
            cleanup,
            other,
            queueWaitSamples,
            queueWaitTotalMilliseconds,
            queueWaitMaximumMilliseconds,
            handlerSamples,
            handlerTotalMilliseconds,
            handlerMaximumMilliseconds
        ):
            event = "input_window"
            fields["received"] = received
            fields["input_event_kinds"] = Dictionary(uniqueKeysWithValues: M10HostInputEventKind.allCases.map {
                ($0.rawValue, inputEventKinds[$0, default: 0])
            })
            fields["admitted"] = admitted
            fields["queued"] = queued
            fields["injected"] = injected
            fields["rejected"] = rejected
            fields["selection_transition"] = selectionTransition
            fields["authorization"] = authorization
            fields["permission"] = permission
            fields["focus"] = focus
            fields["target"] = target
            fields["invalid_event"] = invalidEvent
            fields["cleanup"] = cleanup
            fields["other"] = other
            fields["queue_wait_samples"] = queueWaitSamples
            fields["queue_wait_total_ms"] = queueWaitTotalMilliseconds
            fields["queue_wait_max_ms"] = queueWaitMaximumMilliseconds
            fields["handler_samples"] = handlerSamples
            fields["handler_total_ms"] = handlerTotalMilliseconds
            fields["handler_max_ms"] = handlerMaximumMilliseconds
        }

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var record: [String: Any] = [
            "schema_version": 1,
            "role": M10DebugRole.host.rawValue,
            "run_id": Self.sanitizedRunID(runID),
            "app_version": Self.sanitizedMetadata(appVersion),
            "app_build": Self.sanitizedMetadata(appBuild),
            "timestamp_utc": formatter.string(from: date),
            "monotonic_process_ms": monotonicProcessMilliseconds,
            "run_sequence": sequence,
            "connection_sequence": connectionSequence,
            "event": event
        ]
        fields.forEach { record[$0.key] = $0.value }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else {
            return Data("{\"schema_version\":1,\"role\":\"host\",\"run_id\":\"00000000-0000-0000-0000-000000000000\",\"app_version\":\"unknown\",\"app_build\":\"unknown\",\"timestamp_utc\":\"1970-01-01T00:00:00Z\",\"monotonic_process_ms\":0,\"run_sequence\":1,\"connection_sequence\":0,\"event\":\"diagnostic_encoding_failed\"}\n".utf8)
        }
        return data + Data([0x0A])
    }

    private static func sanitizedMetadata(_ value: String) -> String {
        guard value.range(of: "^[0-9]{1,6}(\\.[0-9]{1,6}){0,3}$", options: .regularExpression) != nil else {
            return "unknown"
        }
        return value
    }

    private static func sanitizedRunID(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString.lowercased() ?? "00000000-0000-0000-0000-000000000000"
    }
}

/// Serializes low-frequency Debug Host records off the app's startup and
/// event-delivery threads. Retention is bounded to one current and one prior
/// file.
final class M10HostDiagnosticFileLog: @unchecked Sendable {
    static let logFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MacRemoteApp/Host/m10-debug-host.log")
    static let shared = M10HostDiagnosticFileLog(fileURL: logFileURL)

    static let maximumFileSizeBytes = 1_048_576
    static let schemaVersion = 1
    static let fileWriteFailureCode = "DIAG_FILE_WRITE_FAILED"

    private static let logger = Logger(
        subsystem: "com.rudinyu.MacRemoteApp",
        category: "m10-debug"
    )

    private let fileURL: URL
    private let previousFileURL: URL
    private let maximumFileSizeBytes: Int
    private let fileManager: FileManager
    private let processStartNanoseconds: UInt64
    private let appVersion: String
    private let appBuild: String
    private let runID = UUID().uuidString.lowercased()
    private let queue = DispatchQueue(
        label: "com.rudinyu.MacRemoteApp.m10-debug-file",
        qos: .utility
    )
    private var didReportFailure = false
    private var recordSequence: UInt64 = 0
    private var connectionSequence: UInt64 = 0
    private let connectionSequenceLock = NSLock()
    private let sessionConnectionLock = NSLock()
    private var sessionConnectionSequences: [ObjectIdentifier: UInt64] = [:]

    init(
        fileURL: URL,
        maximumFileSizeBytes: Int = M10HostDiagnosticFileLog.maximumFileSizeBytes,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.previousFileURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("m10-debug-host.previous.log")
        self.maximumFileSizeBytes = max(1, maximumFileSizeBytes)
        self.fileManager = fileManager
        processStartNanoseconds = DispatchTime.now().uptimeNanoseconds
        appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        appBuild = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"
    }

    func record(
        _ event: M10HostDiagnosticEvent,
        at date: Date = Date(),
        monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        connectionSequenceOverride: UInt64? = nil
    ) {
        if event.startsConnection {
            _ = recordConnectionStarted(at: date, monotonicNanoseconds: monotonicNanoseconds)
            return
        }
        if let connectionSequenceOverride {
            queue.async { [weak self] in
                self?.append(
                    event,
                    at: date,
                    monotonicNanoseconds: monotonicNanoseconds,
                    connectionSequenceOverride: connectionSequenceOverride
                )
            }
        } else {
            connectionSequenceLock.lock()
            let assignedConnectionSequence = connectionSequence
            queue.async { [weak self] in
                self?.append(
                    event,
                    at: date,
                    monotonicNanoseconds: monotonicNanoseconds,
                    connectionSequenceOverride: assignedConnectionSequence
                )
            }
            connectionSequenceLock.unlock()
        }
    }

    /// Allocates a sequence and enqueues its startup record in one short
    /// critical section, so later summaries keep this connection's sequence
    /// even when they flush after a reconnect.
    @discardableResult
    func recordConnectionStarted(
        at date: Date = Date(),
        monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> UInt64 {
        connectionSequenceLock.lock()
        connectionSequence &+= 1
        let assignedSequence = connectionSequence
        queue.async { [weak self] in
            self?.append(
                .connectionStarted,
                at: date,
                monotonicNanoseconds: monotonicNanoseconds,
                connectionSequenceOverride: assignedSequence
            )
        }
        connectionSequenceLock.unlock()
        return assignedSequence
    }

    func bind(_ session: SessionCoordinator, toConnectionSequence sequence: UInt64) {
        sessionConnectionLock.lock()
        sessionConnectionSequences[ObjectIdentifier(session)] = sequence
        sessionConnectionLock.unlock()
    }

    func connectionSequence(for session: SessionCoordinator) -> UInt64? {
        sessionConnectionLock.lock()
        defer { sessionConnectionLock.unlock() }
        return sessionConnectionSequences[ObjectIdentifier(session)]
    }

    func unbind(_ session: SessionCoordinator) {
        sessionConnectionLock.lock()
        sessionConnectionSequences.removeValue(forKey: ObjectIdentifier(session))
        sessionConnectionLock.unlock()
    }

    /// Used by the focused tests to wait for queued writes without exposing a
    /// synchronous write path to the running Host.
    func waitForPendingWrites() {
        queue.sync {}
    }

    var didFailForTesting: Bool {
        queue.sync { didReportFailure }
    }

    private func append(
        _ event: M10HostDiagnosticEvent,
        at date: Date,
        monotonicNanoseconds: UInt64,
        connectionSequenceOverride: UInt64
    ) {
        recordSequence &+= 1
        let elapsed = monotonicNanoseconds >= processStartNanoseconds
            ? monotonicNanoseconds - processStartNanoseconds
            : 0
        let data = event.line(
            at: date,
            sequence: recordSequence,
            connectionSequence: connectionSequenceOverride,
            runID: runID,
            monotonicProcessMilliseconds: elapsed / 1_000_000,
            appVersion: appVersion,
            appBuild: appBuild
        )
        guard data.count <= maximumFileSizeBytes else {
            reportFailureOnce()
            return
        }

        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )

            let currentSize = try currentFileSize()
            if let currentSize, currentSize > maximumFileSizeBytes - data.count {
                try rotateCurrentFile()
            }

            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(
                    atPath: fileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw M10HostDiagnosticFileLogError.cannotCreateFile
                }
            }

            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            didReportFailure = false
        } catch {
            reportFailureOnce()
        }
    }

    private func currentFileSize() throws -> Int? {
        try fileSize(at: fileURL)
    }

    private func fileSize(at url: URL) throws -> Int? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw M10HostDiagnosticFileLogError.invalidFileType
        }
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func rotateCurrentFile() throws {
        if fileManager.fileExists(atPath: previousFileURL.path) {
            try fileManager.removeItem(at: previousFileURL)
        }
        try fileManager.moveItem(at: fileURL, to: previousFileURL)
        if let previousSize = try fileSize(at: previousFileURL),
           previousSize > maximumFileSizeBytes {
            try fileManager.removeItem(at: previousFileURL)
            return
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: previousFileURL.path
        )
    }

    private func reportFailureOnce() {
        guard !didReportFailure else { return }
        didReportFailure = true
        Self.logger.error(
            "diagnostic_code=DIAG_FILE_WRITE_FAILED role=host"
        )
    }
}

private enum M10HostDiagnosticFileLogError: Error {
    case cannotCreateFile
    case invalidFileType
}

/// A low-frequency watchdog for delays on the AppKit/MainActor executor.
/// It records only elapsed time and a fixed app role.
final class M10MainActorStallMonitor: @unchecked Sendable {
    static let shared = M10MainActorStallMonitor()
    static let releaseAuditMarker = "MACREMOTEAPP_M10_DEBUG_DIAGNOSTICS"

    private static let stallThresholdNanoseconds = M10HostRunLoopStallPolicy.thresholdNanoseconds
    private static let repeatedReportIntervalNanoseconds: UInt64 = 5_000_000_000
    private static let logger = Logger(
        subsystem: "com.rudinyu.MacRemoteApp",
        category: "m10-debug"
    )

    private let lock = NSLock()
    private let watchdogQueue = DispatchQueue(label: "com.rudinyu.MacRemoteApp.m10-debug-watchdog", qos: .utility)
    private var started = false
    private var role = M10DebugRole.host.rawValue
    private var lastHeartbeatNanoseconds = DispatchTime.now().uptimeNanoseconds
    private var activeStallStartedAt: UInt64?
    private var lastStallReportNanoseconds: UInt64 = 0
    private var heartbeatTask: Task<Void, Never>?
    private var watchdogTimer: DispatchSourceTimer?
    private var runLoopObserver: CFRunLoopObserver?
    private var runLoopSourceStartedAtNanoseconds: UInt64?

    private init() {}

    func start(role: M10DebugRole) {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        self.role = role.rawValue
        lastHeartbeatNanoseconds = DispatchTime.now().uptimeNanoseconds
        lock.unlock()

        Self.logger.info(
            "\(Self.releaseAuditMarker, privacy: .public) enabled role=\(role.rawValue, privacy: .public)"
        )
        M10HostDiagnosticFileLog.shared.record(.startup)
        installRunLoopObserver()

        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.checkHeartbeat()
        }

        lock.lock()
        watchdogTimer = timer
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.recordHeartbeat()
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    return
                }
            }
        }
        lock.unlock()
        timer.resume()
    }

    private func installRunLoopObserver() {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.allActivities.rawValue,
            true,
            0
        ) { [weak self] _, activity in
            self?.recordRunLoopActivity(activity)
        }
        guard let observer else { return }
        runLoopObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
    }

    private func recordRunLoopActivity(_ activity: CFRunLoopActivity) {
        let now = DispatchTime.now().uptimeNanoseconds
        let sourceStartedAt: UInt64?
        lock.lock()
        if activity == .beforeSources {
            runLoopSourceStartedAtNanoseconds = now
            lock.unlock()
            return
        }
        guard activity == .beforeWaiting else {
            if activity == .exit {
                runLoopSourceStartedAtNanoseconds = nil
            }
            lock.unlock()
            return
        }
        sourceStartedAt = runLoopSourceStartedAtNanoseconds
        runLoopSourceStartedAtNanoseconds = nil
        lock.unlock()
        guard let sourceStartedAt, now >= sourceStartedAt else { return }
        let elapsed = now - sourceStartedAt
        guard M10HostRunLoopStallPolicy.detectsStall(
            from: .beforeSources,
            to: .beforeWaiting,
            elapsedNanoseconds: elapsed
        ) else { return }
        let duration = elapsed / 1_000_000
        M10HostDiagnosticFileLog.shared.record(.runLoopStalled(
            durationMilliseconds: duration,
            phase: .beforeSources
        ))
        M10HostDiagnosticFileLog.shared.record(.runLoopRecovered(
            durationMilliseconds: duration,
            phase: .beforeWaiting
        ))
    }

    private func recordHeartbeat() {
        let recovery: (role: String, durationNanoseconds: UInt64)?
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        lastHeartbeatNanoseconds = now
        if let startedAt = activeStallStartedAt {
            activeStallStartedAt = nil
            recovery = (
                role,
                M10HostHeartbeatTiming.elapsedNanoseconds(now: now, since: startedAt) ?? 0
            )
        } else {
            recovery = nil
        }
        lock.unlock()

        if let recovery {
            M10HostDiagnosticFileLog.shared.record(
                .mainActorRecovered(
                    durationMilliseconds: recovery.durationNanoseconds / 1_000_000
                )
            )
            Self.logger.notice(
                "M10 main actor recovered role=\(recovery.role, privacy: .public) durationMs=\(recovery.durationNanoseconds / 1_000_000, privacy: .public)"
            )
        }
    }

    private func checkHeartbeat() {
        let report: (role: String, durationNanoseconds: UInt64)?
        lock.lock()
        // Keep the sample in the same lock order as recordHeartbeat().
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = M10HostHeartbeatTiming.elapsedNanoseconds(
            now: now,
            since: lastHeartbeatNanoseconds
        )
        let timeSinceLastReport = M10HostHeartbeatTiming.elapsedNanoseconds(
            now: now,
            since: lastStallReportNanoseconds
        )
        if let elapsed,
           elapsed >= Self.stallThresholdNanoseconds,
           (lastStallReportNanoseconds == 0 ||
            timeSinceLastReport.map { $0 >= Self.repeatedReportIntervalNanoseconds } == true) {
            if activeStallStartedAt == nil {
                activeStallStartedAt = lastHeartbeatNanoseconds
            }
            lastStallReportNanoseconds = now
            report = (role, elapsed)
        } else {
            report = nil
        }
        lock.unlock()

        if let report {
            M10HostDiagnosticFileLog.shared.record(
                .mainActorStalled(
                    durationMilliseconds: report.durationNanoseconds / 1_000_000
                )
            )
            Self.logger.error(
                "M10 main actor stalled role=\(report.role, privacy: .public) durationMs=\(report.durationNanoseconds / 1_000_000, privacy: .public)"
            )
        }
    }
}

enum M10HostInputRejectionReason {
    case selectionTransition
    case authorization
    case permission
    case focus
    case target
    case invalidEvent
    case cleanup
    case other
}

/// Low-frequency fixed-count evidence for Host capture, encode, and send.
final class M10HostVideoDiagnostics: @unchecked Sendable {
    static let shared = M10HostVideoDiagnostics(fileLog: .shared)
    private static let flushIntervalNanoseconds: UInt64 = 5_000_000_000

    private struct Counts {
        var captured: UInt64 = 0
        var encoded: UInt64 = 0
        var encodeFailures: UInt64 = 0
        var sendQueued: UInt64 = 0
        var dropped: UInt64 = 0
        var sendFailures: UInt64 = 0

        var hasEvents: Bool {
            captured > 0 || encoded > 0 || encodeFailures > 0 || sendQueued > 0 || dropped > 0 || sendFailures > 0
        }
    }

    private let lock = NSLock()
    private let fileLog: M10HostDiagnosticFileLog
    private var counts = Counts()
    private var windowStartedAt = DispatchTime.now().uptimeNanoseconds

    init(fileLog: M10HostDiagnosticFileLog) {
        self.fileLog = fileLog
    }

    func beginWindow(at nanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock()
        counts = Counts()
        windowStartedAt = nanoseconds
        lock.unlock()
    }

    func recordCaptured() { update { $0.captured &+= 1 } }
    func recordEncoded() { update { $0.encoded &+= 1 } }
    func recordEncodeFailure() { update { $0.encodeFailures &+= 1 } }
    func recordSendQueued() { update { $0.sendQueued &+= 1 } }
    func recordDropped() { update { $0.dropped &+= 1 } }
    func recordSendFailure() { update { $0.sendFailures &+= 1 } }

    func flushIfDue(at nanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let snapshot: Counts
        let duration: UInt64
        lock.lock()
        guard nanoseconds >= windowStartedAt,
              nanoseconds - windowStartedAt >= Self.flushIntervalNanoseconds else {
            lock.unlock()
            return
        }
        snapshot = counts
        duration = (nanoseconds - windowStartedAt) / 1_000_000
        counts = Counts()
        windowStartedAt = nanoseconds
        lock.unlock()
        emit(snapshot, durationMilliseconds: duration)
    }

    /// Ends the current stream's window and emits its bounded partial summary
    /// before a selection or connection transition can change attribution.
    func flushPendingWindow(at nanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let snapshot: Counts
        let duration: UInt64
        lock.lock()
        let elapsed = nanoseconds >= windowStartedAt ? nanoseconds - windowStartedAt : 0
        snapshot = counts
        duration = elapsed / 1_000_000
        counts = Counts()
        windowStartedAt = nanoseconds
        lock.unlock()
        emit(snapshot, durationMilliseconds: duration)
    }

    private func emit(_ snapshot: Counts, durationMilliseconds: UInt64) {
        guard snapshot.hasEvents else { return }
        fileLog.record(
            .videoWindow(
                captured: snapshot.captured,
                encoded: snapshot.encoded,
                encodeFailures: snapshot.encodeFailures,
                sendQueued: snapshot.sendQueued,
                dropped: snapshot.dropped,
                sendFailures: snapshot.sendFailures,
                durationMilliseconds: durationMilliseconds
            )
        )
    }

    private func update(_ mutation: (inout Counts) -> Void) {
        lock.lock()
        mutation(&counts)
        lock.unlock()
    }
}

/// Aggregates Host input outcomes. It never retains event payloads or logs an
/// event-level value, and emits at most one summary per five-second window.
final class M10HostInputDiagnostics: @unchecked Sendable {
    static let shared = M10HostInputDiagnostics()

    private static let logger = Logger(
        subsystem: "com.rudinyu.MacRemoteApp",
        category: "m10-debug"
    )

    private struct Counts {
        var received: UInt64 = 0
        var inputEventKinds: [M10HostInputEventKind: UInt64] = [:]
        var admitted: UInt64 = 0
        var queued: UInt64 = 0
        var injected: UInt64 = 0
        var rejected: UInt64 = 0
        var selectionTransition: UInt64 = 0
        var authorization: UInt64 = 0
        var permission: UInt64 = 0
        var focus: UInt64 = 0
        var target: UInt64 = 0
        var invalidEvent: UInt64 = 0
        var cleanup: UInt64 = 0
        var other: UInt64 = 0
        var queueWaitSamples: UInt64 = 0
        var queueWaitTotalMilliseconds: UInt64 = 0
        var queueWaitMaximumMilliseconds: UInt64 = 0
        var handlerSamples: UInt64 = 0
        var handlerTotalMilliseconds: UInt64 = 0
        var handlerMaximumMilliseconds: UInt64 = 0

        var hasEvents: Bool {
            received > 0 || injected > 0 || rejected > 0
        }
    }

    private let lock = NSLock()
    private let fileLog: M10HostDiagnosticFileLog
    private var countsByConnection: [UInt64: Counts] = [:]
    private var scheduledFlushes: Set<UInt64> = []

    init(fileLog: M10HostDiagnosticFileLog = .shared) {
        self.fileLog = fileLog
    }

    func recordReceived(kind: M10HostInputEventKind, connectionSequence: UInt64?) {
        update(connectionSequence: connectionSequence) { counts in
            counts.received &+= 1
            counts.inputEventKinds[kind, default: 0] &+= 1
        }
    }

    func recordInjected(connectionSequence: UInt64?) {
        update(connectionSequence: connectionSequence) { $0.injected &+= 1 }
    }

    func recordAdmitted(queueWaitNanoseconds: UInt64, connectionSequence: UInt64?) {
        let milliseconds = queueWaitNanoseconds / 1_000_000
        update(connectionSequence: connectionSequence) { counts in
            counts.admitted &+= 1
            counts.queueWaitSamples &+= 1
            counts.queueWaitTotalMilliseconds &+= milliseconds
            counts.queueWaitMaximumMilliseconds = max(counts.queueWaitMaximumMilliseconds, milliseconds)
            if queueWaitNanoseconds >= 5_000_000 { counts.queued &+= 1 }
        }
    }

    func recordHandlerDuration(_ nanoseconds: UInt64, connectionSequence: UInt64?) {
        let milliseconds = nanoseconds / 1_000_000
        update(connectionSequence: connectionSequence) { counts in
            counts.handlerSamples &+= 1
            counts.handlerTotalMilliseconds &+= milliseconds
            counts.handlerMaximumMilliseconds = max(counts.handlerMaximumMilliseconds, milliseconds)
        }
    }

    func recordRejected(_ reason: M10HostInputRejectionReason, connectionSequence: UInt64?) {
        update(connectionSequence: connectionSequence) { counts in
            counts.rejected &+= 1
            switch reason {
            case .selectionTransition: counts.selectionTransition &+= 1
            case .authorization: counts.authorization &+= 1
            case .permission: counts.permission &+= 1
            case .focus: counts.focus &+= 1
            case .target: counts.target &+= 1
            case .invalidEvent: counts.invalidEvent &+= 1
            case .cleanup: counts.cleanup &+= 1
            case .other: counts.other &+= 1
            }
        }
    }

    /// Emits a session's partial window at stream termination. The sequence is
    /// captured by the input loop, so a delayed timer can never relabel these
    /// counts with a later connection's sequence.
    func finishConnection(connectionSequence: UInt64?) {
        guard let connectionSequence else { return }
        flush(connectionSequence: connectionSequence)
    }

    private func update(
        connectionSequence: UInt64?,
        _ mutation: (inout Counts) -> Void
    ) {
        guard let connectionSequence else { return }
        lock.lock()
        var counts = countsByConnection[connectionSequence] ?? Counts()
        mutation(&counts)
        countsByConnection[connectionSequence] = counts
        let shouldScheduleFlush = scheduledFlushes.insert(connectionSequence).inserted
        lock.unlock()

        guard shouldScheduleFlush else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(5)) { [weak self] in
            self?.flush(connectionSequence: connectionSequence)
        }
    }

    private func flush(connectionSequence: UInt64) {
        lock.lock()
        let snapshot = countsByConnection.removeValue(forKey: connectionSequence) ?? Counts()
        scheduledFlushes.remove(connectionSequence)
        lock.unlock()

        emit(snapshot, connectionSequence: connectionSequence)
    }

    private func emit(_ snapshot: Counts, connectionSequence: UInt64) {
        guard snapshot.hasEvents else { return }
        fileLog.record(
            .inputTotals(
                received: snapshot.received,
                inputEventKinds: Dictionary(uniqueKeysWithValues: M10HostInputEventKind.allCases.map {
                    ($0, snapshot.inputEventKinds[$0, default: 0])
                }),
                admitted: snapshot.admitted,
                queued: snapshot.queued,
                injected: snapshot.injected,
                rejected: snapshot.rejected,
                selectionTransition: snapshot.selectionTransition,
                authorization: snapshot.authorization,
                permission: snapshot.permission,
                focus: snapshot.focus,
                target: snapshot.target,
                invalidEvent: snapshot.invalidEvent,
                cleanup: snapshot.cleanup,
                other: snapshot.other,
                queueWaitSamples: snapshot.queueWaitSamples,
                queueWaitTotalMilliseconds: snapshot.queueWaitTotalMilliseconds,
                queueWaitMaximumMilliseconds: snapshot.queueWaitMaximumMilliseconds,
                handlerSamples: snapshot.handlerSamples,
                handlerTotalMilliseconds: snapshot.handlerTotalMilliseconds,
                handlerMaximumMilliseconds: snapshot.handlerMaximumMilliseconds
            ),
            connectionSequenceOverride: connectionSequence
        )
        Self.logger.notice(
            "M10 Host input totals received=\(snapshot.received, privacy: .public) admitted=\(snapshot.admitted, privacy: .public) queued=\(snapshot.queued, privacy: .public) injected=\(snapshot.injected, privacy: .public) rejected=\(snapshot.rejected, privacy: .public)"
        )
    }
}

#endif
