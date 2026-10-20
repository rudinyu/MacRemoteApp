#if DEBUG
import Foundation
import CoreFoundation
import os
import InputCore
import TransportCore

enum M10DebugRole: String {
    case viewer
}

enum M10ViewerSessionState: String, Equatable, Sendable {
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

enum M10ViewerConnectionOutcome: String, Sendable {
    case connected
    case pairingDenied = "pairing_denied"
    case sessionFailure = "session_failure"
    case connectionFailure = "connection_failure"
}

enum M10ViewerPeerTerminalState: String, Sendable {
    case close
    case sessionStopping = "session_stopping"
    case sessionFailed = "session_failed"
}

enum M10ViewerWindowSelection: String, Equatable, Sendable {
    case requested
    case rejectedLocally = "rejected_locally"
    case sent
    case hostAcknowledged = "host_acknowledged"
    case hostRejected = "host_rejected"
    case sendFailed = "send_failed"
    case cleared
}

enum M10ViewerRunLoopPhase: String, Sendable {
    case beforeSources = "before_sources"
    case beforeWaiting = "before_waiting"
    case afterWaiting = "after_waiting"
    case exit
}

enum M10ViewerRunLoopStallPolicy {
    static let thresholdNanoseconds: UInt64 = 750_000_000

    static func detectsStall(
        from startPhase: M10ViewerRunLoopPhase,
        to endPhase: M10ViewerRunLoopPhase,
        elapsedNanoseconds: UInt64
    ) -> Bool {
        startPhase == .beforeSources
            && endPhase == .beforeWaiting
            && elapsedNanoseconds >= thresholdNanoseconds
    }
}

enum M10ViewerHeartbeatTiming {
    static func elapsedNanoseconds(now: UInt64, since timestamp: UInt64) -> UInt64? {
        guard now >= timestamp else { return nil }
        return now - timestamp
    }
}

enum M10ViewerInputReadiness: String, Equatable, Sendable {
    case awaitingAuthentication = "awaiting_authentication"
    case awaitingAuthorization = "awaiting_authorization"
    case surfaceUnavailable = "surface_unavailable"
    case hostPermissionUnavailable = "host_permission_unavailable"
    case hostFocusUnavailable = "host_focus_unavailable"
    case hostStateUnavailable = "host_state_unavailable"
    case hostControlNegotiating = "host_control_negotiating"
    case hostControlUnavailable = "host_control_unavailable"
    case hostProcessTargetUnavailable = "host_process_target_unavailable"
    case ready
}

enum M10ViewerInputReason: String, Equatable, Sendable {
    case ready
    case awaitingAuthentication = "awaiting_authentication"
    case authorizationRequired = "authorization_required"
    case windowNotSelected = "window_not_selected"
    case surfaceUnavailable = "surface_unavailable"
    case hostPermission = "host_permission"
    case hostFocus = "host_focus"
    case hostInputState = "host_input_state"
    case controlSetupPending = "control_setup_pending"
    case controlConsentRequired = "control_consent_required"
    case controlPaused = "control_paused"
    case controlRevoked = "control_revoked"
    case controlPersistenceFailure = "control_persistence_failure"
    case controlUnsupported = "control_unsupported"
    case unsafeProcessTarget = "unsafe_process_target"
    case keyboardCapabilityUnavailable = "keyboard_capability_unavailable"
    case capabilityUnavailable = "capability_unavailable"
}

enum M10ViewerInputEventKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case mouseMove = "mouse_move"
    case buttonDown = "button_down"
    case buttonUp = "button_up"
    case scroll
    case keyDown = "key_down"
    case keyUp = "key_up"
    case focusIntent = "focus_intent"
    /// Viewer-composed text (ADR-0008). Only the count is recorded.
    case text
    case other

    static func forRecord(_ record: InputEventRecord) -> Self {
        switch record.kind {
        case .pointerMove: .mouseMove
        case .pointerButton:
            switch record.pressed {
            case true?: .buttonDown
            case false?: .buttonUp
            case nil: .other
            }
        case .scroll: .scroll
        case .keyDown: .keyDown
        case .keyUp: .keyUp
        case .focusIntent: .focusIntent
        case .text: .text
        }
    }
}

enum M10ViewerInputFailureSubcategory: String, CaseIterable, Equatable, Hashable, Sendable {
    case expectedAuthorizationEpochMismatchBeforeAdmission = "expected_authorization_epoch_mismatch_before_admission"
    case inputAdmissionTokenMismatchBeforeTransport = "input_admission_token_mismatch_before_transport"
    case authorizationEpochChangedAfterAdmissionBeforeTransport = "authorization_epoch_changed_after_admission_before_transport"
    case authorizationChangedAfterAdmissionBeforeTransport = "authorization_changed_after_admission_before_transport"
    case reconnectOrReadinessRejected = "reconnect_or_readiness_rejected"
    case capabilityDenied = "capability_denied"
    case localPreflightRejected = "local_preflight_rejected"
    case transportDeliveryUncertain = "transport_delivery_uncertain"
    case otherPreTransportRejection = "other_pre_transport_rejection"
    case unclassified

    static func admissionFailure(
        _ error: SessionError,
        isAuthorizedForWindow: Bool
    ) -> Self {
        switch error {
        case .authorizationChanged:
            .expectedAuthorizationEpochMismatchBeforeAdmission
        case .unauthorizedMessage(.inputEvent):
            isAuthorizedForWindow ? .capabilityDenied : .reconnectOrReadinessRejected
        case .reconnectRequired:
            .reconnectOrReadinessRejected
        default:
            .reconnectOrReadinessRejected
        }
    }

    static func postAdmissionFailure(
        _ error: Error,
        transportSendStarted: Bool,
        preTransportRejection: SessionInputSendRejection? = nil
    ) -> Self {
        guard !transportSendStarted else { return .transportDeliveryUncertain }
        guard let error = error as? SessionError else { return .reconnectOrReadinessRejected }
        return switch error {
        case .authorizationChanged:
            switch preTransportRejection {
            case .admissionTokenMismatch:
                .inputAdmissionTokenMismatchBeforeTransport
            case .authorizationEpochChangedAfterAdmission:
                .authorizationEpochChangedAfterAdmissionBeforeTransport
            case nil:
                .authorizationChangedAfterAdmissionBeforeTransport
            }
        case .unauthorizedMessage(.inputEvent):
            .capabilityDenied
        case .reconnectRequired:
            .reconnectOrReadinessRejected
        default:
            .reconnectOrReadinessRejected
        }
    }
}

struct M10ViewerVideoWindowSummary: Equatable {
    let received: UInt64
    let presented: UInt64
    let decodeFailures: UInt64
    let durationMilliseconds: UInt64
}

/// A deterministic, fixed-count aggregate with no frame or payload storage.
struct M10ViewerVideoWindowAccumulator {
    static let intervalNanoseconds: UInt64 = 5_000_000_000

    private var startedAtNanoseconds: UInt64?
    private var received: UInt64 = 0
    private var presented: UInt64 = 0
    private var decodeFailures: UInt64 = 0

    mutating func begin(at nanoseconds: UInt64) {
        startedAtNanoseconds = nanoseconds
        received = 0
        presented = 0
        decodeFailures = 0
    }

    mutating func recordReceived() { received &+= 1 }
    mutating func recordPresented() { presented &+= 1 }
    mutating func recordDecodeFailure() { decodeFailures &+= 1 }

    mutating func takeSummaryIfDue(at nanoseconds: UInt64) -> M10ViewerVideoWindowSummary? {
        guard let startedAtNanoseconds,
              nanoseconds >= startedAtNanoseconds,
              nanoseconds - startedAtNanoseconds >= Self.intervalNanoseconds else { return nil }
        let summary = M10ViewerVideoWindowSummary(
            received: received,
            presented: presented,
            decodeFailures: decodeFailures,
            durationMilliseconds: (nanoseconds - startedAtNanoseconds) / 1_000_000
        )
        begin(at: nanoseconds)
        return summary
    }

    /// Ends the current stream window, returning one partial aggregate when it
    /// contains events. No per-frame data is retained or emitted.
    mutating func takePendingSummary(at nanoseconds: UInt64) -> M10ViewerVideoWindowSummary? {
        guard let startedAtNanoseconds else { return nil }
        let elapsed = nanoseconds >= startedAtNanoseconds ? nanoseconds - startedAtNanoseconds : 0
        let hasEvents = received > 0 || presented > 0 || decodeFailures > 0
        let summary = hasEvents
            ? M10ViewerVideoWindowSummary(
                received: received,
                presented: presented,
                decodeFailures: decodeFailures,
                durationMilliseconds: elapsed / 1_000_000
            )
            : nil
        self.startedAtNanoseconds = nil
        received = 0
        presented = 0
        decodeFailures = 0
        return summary
    }
}

struct M10ViewerInputWindowSummary: Equatable {
    let attempted: UInt64
    let locallyAccepted: UInt64
    let sendFailures: UInt64
    let failureCategories: [ViewerInputFailureCategory: UInt64]
    let underlyingFailureCategories: [ViewerInputFailureCategory: UInt64]
    let failureBoundaries: [ViewerInputSendBoundary: UInt64]
    let underlyingFailureCategoriesByBoundary: [ViewerInputSendBoundary: [ViewerInputFailureCategory: UInt64]]
    let eventKinds: [M10ViewerInputEventKind: UInt64]
    let failureSubcategories: [M10ViewerInputFailureSubcategory: UInt64]
    let durationMilliseconds: UInt64
}

/// Aggregates counts at the Viewer send boundary without retaining event data.
struct M10ViewerInputWindowAccumulator {
    static let intervalNanoseconds: UInt64 = 5_000_000_000

    private var startedAtNanoseconds: UInt64?
    private var attempted: UInt64 = 0
    private var locallyAccepted: UInt64 = 0
    private var sendFailures: UInt64 = 0
    private var failureCategories: [ViewerInputFailureCategory: UInt64] = [:]
    private var underlyingFailureCategories: [ViewerInputFailureCategory: UInt64] = [:]
    private var failureBoundaries: [ViewerInputSendBoundary: UInt64] = [:]
    private var underlyingFailureCategoriesByBoundary: [ViewerInputSendBoundary: [ViewerInputFailureCategory: UInt64]] = [:]
    private var eventKinds: [M10ViewerInputEventKind: UInt64] = [:]
    private var failureSubcategories: [M10ViewerInputFailureSubcategory: UInt64] = [:]

    mutating func begin(at nanoseconds: UInt64) {
        startedAtNanoseconds = nanoseconds
        attempted = 0
        locallyAccepted = 0
        sendFailures = 0
        failureCategories.removeAll(keepingCapacity: true)
        underlyingFailureCategories.removeAll(keepingCapacity: true)
        failureBoundaries.removeAll(keepingCapacity: true)
        underlyingFailureCategoriesByBoundary.removeAll(keepingCapacity: true)
        eventKinds.removeAll(keepingCapacity: true)
        failureSubcategories.removeAll(keepingCapacity: true)
    }

    mutating func recordAttempt(kind: M10ViewerInputEventKind) {
        attempted &+= 1
        eventKinds[kind, default: 0] &+= 1
    }
    mutating func recordLocallyAccepted() { locallyAccepted &+= 1 }
    mutating func recordSendFailure() { sendFailures &+= 1 }
    mutating func recordFailureSubcategory(_ subcategory: M10ViewerInputFailureSubcategory) {
        failureSubcategories[subcategory, default: 0] &+= 1
    }
    mutating func recordFailureCategory(_ category: ViewerInputFailureCategory) {
        failureCategories[category, default: 0] &+= 1
    }
    mutating func recordFailureContext(
        underlyingCategory: ViewerInputFailureCategory,
        boundary: ViewerInputSendBoundary
    ) {
        underlyingFailureCategories[underlyingCategory, default: 0] &+= 1
        failureBoundaries[boundary, default: 0] &+= 1
        underlyingFailureCategoriesByBoundary[boundary, default: [:]][underlyingCategory, default: 0] &+= 1
    }

    mutating func takeSummaryIfDue(
        at nanoseconds: UInt64,
        includingPending: Bool = false
    ) -> M10ViewerInputWindowSummary? {
        guard let startedAtNanoseconds,
              nanoseconds >= startedAtNanoseconds else { return nil }
        let isDue = nanoseconds - startedAtNanoseconds >= Self.intervalNanoseconds
        let hasPendingEvents = attempted > 0 || locallyAccepted > 0 || sendFailures > 0 ||
            !failureCategories.isEmpty || !underlyingFailureCategories.isEmpty ||
            !failureBoundaries.isEmpty || !underlyingFailureCategoriesByBoundary.isEmpty ||
            !eventKinds.isEmpty || !failureSubcategories.isEmpty
        guard isDue || (includingPending && hasPendingEvents) else { return nil }
        let summary = M10ViewerInputWindowSummary(
            attempted: attempted,
            locallyAccepted: locallyAccepted,
            sendFailures: sendFailures,
            failureCategories: Dictionary(uniqueKeysWithValues: ViewerInputFailureCategory.allCases.map {
                ($0, failureCategories[$0, default: 0])
            }),
            underlyingFailureCategories: Dictionary(uniqueKeysWithValues: ViewerInputFailureCategory.allCases.map {
                ($0, underlyingFailureCategories[$0, default: 0])
            }),
            failureBoundaries: Dictionary(uniqueKeysWithValues: ViewerInputSendBoundary.allCases.map {
                ($0, failureBoundaries[$0, default: 0])
            }),
            underlyingFailureCategoriesByBoundary: Dictionary(uniqueKeysWithValues: ViewerInputSendBoundary.allCases.map {
                let values = underlyingFailureCategoriesByBoundary[$0, default: [:]]
                return ($0, Dictionary(uniqueKeysWithValues: ViewerInputFailureCategory.allCases.map {
                    ($0, values[$0, default: 0])
                }))
            }),
            eventKinds: Dictionary(uniqueKeysWithValues: M10ViewerInputEventKind.allCases.map {
                ($0, eventKinds[$0, default: 0])
            }),
            failureSubcategories: Dictionary(uniqueKeysWithValues: M10ViewerInputFailureSubcategory.allCases.map {
                ($0, failureSubcategories[$0, default: 0])
            }),
            durationMilliseconds: (nanoseconds - startedAtNanoseconds) / 1_000_000
        )
        begin(at: nanoseconds)
        return summary
    }
}

struct M10ViewerSessionDiagnosticSnapshot: Equatable {
    let state: M10ViewerSessionState
    let authorized: Bool
    let windowAuthorized: Bool
    let videoCapability: Bool
    let mouseCapability: Bool
    let keyboardCapability: Bool
    let windowSelectionCapability: Bool
    let clipboardCapability: Bool
    let backgroundControlCapability: Bool
}

enum M10ViewerDiagnosticEvent: Sendable {
    case startup
    case connectionStarted
    case mainActorStalled(durationMilliseconds: UInt64)
    case mainActorRecovered(durationMilliseconds: UInt64)
    case runLoopStalled(durationMilliseconds: UInt64, phase: M10ViewerRunLoopPhase)
    case runLoopRecovered(durationMilliseconds: UInt64, phase: M10ViewerRunLoopPhase)
    case connectionOutcome(M10ViewerConnectionOutcome)
    case sessionFailure(SessionFailureCategory)
    case transportTermination(TransportTerminationClass)
    case peerTerminal(M10ViewerPeerTerminalState)
    case sessionState(
        state: M10ViewerSessionState,
        authorized: Bool,
        windowAuthorized: Bool,
        videoCapability: Bool,
        mouseCapability: Bool,
        keyboardCapability: Bool,
        windowSelectionCapability: Bool,
        clipboardCapability: Bool,
        backgroundControlCapability: Bool
    )
    case windowCatalog(eligibleCount: UInt64, selected: Bool)
    case windowSelection(M10ViewerWindowSelection)
    case inputReadiness(
        readiness: M10ViewerInputReadiness,
        reason: M10ViewerInputReason,
        keyboardAvailable: Bool
    )
    case videoWindow(
        received: UInt64,
        presented: UInt64,
        decodeFailures: UInt64,
        durationMilliseconds: UInt64
    )
    case inputWindow(
        attempted: UInt64,
        locallyAccepted: UInt64,
        sendFailures: UInt64,
        failureCategories: [ViewerInputFailureCategory: UInt64],
        underlyingFailureCategories: [ViewerInputFailureCategory: UInt64],
        failureBoundaries: [ViewerInputSendBoundary: UInt64],
        underlyingFailureCategoriesByBoundary: [ViewerInputSendBoundary: [ViewerInputFailureCategory: UInt64]],
        eventKinds: [M10ViewerInputEventKind: UInt64],
        failureSubcategories: [M10ViewerInputFailureSubcategory: UInt64],
        durationMilliseconds: UInt64
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
        case let .windowCatalog(eligibleCount, selected):
            event = "window_catalog"
            fields["eligible"] = eligibleCount
            fields["selected"] = selected
        case let .windowSelection(state):
            event = "window_selection"
            fields["state"] = state.rawValue
        case let .inputReadiness(readiness, reason, keyboardAvailable):
            event = "input_readiness"
            fields["readiness"] = readiness.rawValue
            fields["reason"] = reason.rawValue
            fields["keyboard_available"] = keyboardAvailable
        case let .videoWindow(received, presented, decodeFailures, durationMilliseconds):
            event = "video_window"
            fields["received"] = received
            fields["presented"] = presented
            fields["decode_failures"] = decodeFailures
            fields["duration_ms"] = durationMilliseconds
        case let .inputWindow(
            attempted,
            locallyAccepted,
            sendFailures,
            failureCategories,
            underlyingFailureCategories,
            failureBoundaries,
            underlyingFailureCategoriesByBoundary,
            eventKinds,
            failureSubcategories,
            durationMilliseconds
        ):
            event = "input_window"
            fields["attempted"] = attempted
            fields["locally_accepted"] = locallyAccepted
            fields["send_failures"] = sendFailures
            fields["failure_categories"] = Dictionary(uniqueKeysWithValues: ViewerInputFailureCategory.allCases.map {
                ($0.rawValue, failureCategories[$0, default: 0])
            })
            fields["underlying_failure_categories"] = Dictionary(uniqueKeysWithValues: ViewerInputFailureCategory.allCases.map {
                ($0.rawValue, underlyingFailureCategories[$0, default: 0])
            })
            fields["failure_boundaries"] = Dictionary(uniqueKeysWithValues: ViewerInputSendBoundary.allCases.map {
                ($0.rawValue, failureBoundaries[$0, default: 0])
            })
            fields["underlying_failure_categories_by_boundary"] = Dictionary(
                uniqueKeysWithValues: ViewerInputSendBoundary.allCases.map { boundary in
                    let values = underlyingFailureCategoriesByBoundary[boundary, default: [:]]
                    return (boundary.rawValue, Dictionary(uniqueKeysWithValues: ViewerInputFailureCategory.allCases.map {
                        ($0.rawValue, values[$0, default: 0])
                    }))
                }
            )
            fields["input_event_kinds"] = Dictionary(uniqueKeysWithValues: M10ViewerInputEventKind.allCases.map {
                ($0.rawValue, eventKinds[$0, default: 0])
            })
            fields["failure_subcategories"] = Dictionary(uniqueKeysWithValues: M10ViewerInputFailureSubcategory.allCases.map {
                ($0.rawValue, failureSubcategories[$0, default: 0])
            })
            fields["duration_ms"] = durationMilliseconds
        }

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var record: [String: Any] = [
            "schema_version": 1,
            "role": M10DebugRole.viewer.rawValue,
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
            return Data("{\"schema_version\":1,\"role\":\"viewer\",\"run_id\":\"00000000-0000-0000-0000-000000000000\",\"app_version\":\"unknown\",\"app_build\":\"unknown\",\"timestamp_utc\":\"1970-01-01T00:00:00Z\",\"monotonic_process_ms\":0,\"run_sequence\":1,\"connection_sequence\":0,\"event\":\"diagnostic_encoding_failed\"}\n".utf8)
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

/// Writes bounded, fixed-field diagnostics away from the Viewer UI thread.
final class M10ViewerDiagnosticFileLog: @unchecked Sendable {
    static let logFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MacRemoteApp/Viewer/m10-debug-viewer.log")
    static let shared = M10ViewerDiagnosticFileLog(fileURL: logFileURL)
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
        label: "com.rudinyu.MacRemoteApp.viewer-m10-debug-file",
        qos: .utility
    )
    private var didReportFailure = false
    private var recordSequence: UInt64 = 0
    private var connectionSequence: UInt64 = 0

    init(
        fileURL: URL,
        maximumFileSizeBytes: Int = M10ViewerDiagnosticFileLog.maximumFileSizeBytes,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        previousFileURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("m10-debug-viewer.previous.log")
        self.maximumFileSizeBytes = max(1, maximumFileSizeBytes)
        self.fileManager = fileManager
        processStartNanoseconds = DispatchTime.now().uptimeNanoseconds
        appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        appBuild = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"
    }

    func record(_ event: M10ViewerDiagnosticEvent, at date: Date = Date()) {
        queue.async { [weak self] in
            self?.append(event, at: date)
        }
    }

    func waitForPendingWrites() {
        queue.sync {}
    }

    var didFailForTesting: Bool {
        queue.sync { didReportFailure }
    }

    private func append(_ event: M10ViewerDiagnosticEvent, at date: Date) {
        recordSequence &+= 1
        if event.startsConnection { connectionSequence &+= 1 }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= processStartNanoseconds ? now - processStartNanoseconds : 0
        let data = event.line(
            at: date,
            sequence: recordSequence,
            connectionSequence: connectionSequence,
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
            if let size = try fileSize(at: fileURL), size > maximumFileSizeBytes - data.count {
                try rotateCurrentFile()
            }
            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(
                    atPath: fileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw M10ViewerDiagnosticFileLogError.cannotCreateFile
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

    private func fileSize(at url: URL) throws -> Int? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw M10ViewerDiagnosticFileLogError.invalidFileType
        }
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func rotateCurrentFile() throws {
        if fileManager.fileExists(atPath: previousFileURL.path) {
            try fileManager.removeItem(at: previousFileURL)
        }
        try fileManager.moveItem(at: fileURL, to: previousFileURL)
        if let size = try fileSize(at: previousFileURL), size > maximumFileSizeBytes {
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
        Self.logger.error("diagnostic_code=DIAG_FILE_WRITE_FAILED role=viewer")
    }
}

private enum M10ViewerDiagnosticFileLogError: Error {
    case cannotCreateFile
    case invalidFileType
}

/// Deduplicates state events while retaining an asynchronous writer. All
/// externally supplied status text is deliberately excluded from this API.
final class M10ViewerDiagnosticRecorder: @unchecked Sendable {
    static let shared = M10ViewerDiagnosticRecorder(fileLog: .shared)

    private let fileLog: M10ViewerDiagnosticFileLog
    private let lock = NSLock()
    private var lastSessionState: M10ViewerSessionDiagnosticSnapshot?
    private var lastWindowCatalog: (UInt64, Bool)?
    private var lastWindowSelection: M10ViewerWindowSelection?
    private var lastInputReadiness: (M10ViewerInputReadiness, M10ViewerInputReason, Bool)?
    private var inputWindow = M10ViewerInputWindowAccumulator()

    init(fileLog: M10ViewerDiagnosticFileLog) {
        self.fileLog = fileLog
    }

    func start() {
        fileLog.record(.startup)
    }

    func recordConnectionStarted(
        atUptimeNanoseconds nanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        flushInputWindowIfDue(atUptimeNanoseconds: nanoseconds, includingPending: true)
        fileLog.record(.connectionStarted)
        lock.lock()
        inputWindow.begin(at: nanoseconds)
        lock.unlock()
    }

    func recordViewerInputAttempt(kind: M10ViewerInputEventKind = .other) {
        lock.lock()
        inputWindow.recordAttempt(kind: kind)
        lock.unlock()
    }

    func recordViewerInputLocallyAccepted() {
        lock.lock()
        inputWindow.recordLocallyAccepted()
        lock.unlock()
    }

    func recordViewerInputSendFailure() {
        lock.lock()
        inputWindow.recordSendFailure()
        lock.unlock()
    }

    func recordViewerInputFailureSubcategory(_ subcategory: M10ViewerInputFailureSubcategory) {
        lock.lock()
        inputWindow.recordFailureSubcategory(subcategory)
        lock.unlock()
    }

    func recordViewerInputFailureCategory(_ category: ViewerInputFailureCategory) {
        lock.lock()
        inputWindow.recordFailureCategory(category)
        lock.unlock()
    }

    func recordViewerInputFailureContext(
        underlyingCategory: ViewerInputFailureCategory,
        boundary: ViewerInputSendBoundary
    ) {
        lock.lock()
        inputWindow.recordFailureContext(
            underlyingCategory: underlyingCategory,
            boundary: boundary
        )
        lock.unlock()
    }

    func recordVideoWindowSummary(_ summary: M10ViewerVideoWindowSummary) {
        fileLog.record(.videoWindow(
            received: summary.received,
            presented: summary.presented,
            decodeFailures: summary.decodeFailures,
            durationMilliseconds: summary.durationMilliseconds
        ))
    }

    func flushInputWindowIfDue(
        atUptimeNanoseconds nanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        includingPending: Bool = false
    ) {
        lock.lock()
        let summary = inputWindow.takeSummaryIfDue(at: nanoseconds, includingPending: includingPending)
        lock.unlock()
        guard let summary else { return }
        fileLog.record(.inputWindow(
            attempted: summary.attempted,
            locallyAccepted: summary.locallyAccepted,
            sendFailures: summary.sendFailures,
            failureCategories: summary.failureCategories,
            underlyingFailureCategories: summary.underlyingFailureCategories,
            failureBoundaries: summary.failureBoundaries,
            underlyingFailureCategoriesByBoundary: summary.underlyingFailureCategoriesByBoundary,
            eventKinds: summary.eventKinds,
            failureSubcategories: summary.failureSubcategories,
            durationMilliseconds: summary.durationMilliseconds
        ))
    }

    func recordSessionState(_ snapshot: M10ViewerSessionDiagnosticSnapshot) {
        lock.lock()
        let duplicate = lastSessionState == snapshot
        if !duplicate { lastSessionState = snapshot }
        lock.unlock()
        guard !duplicate else { return }
        fileLog.record(.sessionState(
            state: snapshot.state,
            authorized: snapshot.authorized,
            windowAuthorized: snapshot.windowAuthorized,
            videoCapability: snapshot.videoCapability,
            mouseCapability: snapshot.mouseCapability,
            keyboardCapability: snapshot.keyboardCapability,
            windowSelectionCapability: snapshot.windowSelectionCapability,
            clipboardCapability: snapshot.clipboardCapability,
            backgroundControlCapability: snapshot.backgroundControlCapability
        ))
    }

    func recordSessionState(
        _ state: M10ViewerSessionState,
        authorized: Bool,
        windowAuthorized: Bool
    ) {
        lock.lock()
        let snapshot = M10ViewerSessionDiagnosticSnapshot(
            state: state,
            authorized: authorized,
            windowAuthorized: windowAuthorized,
            videoCapability: false,
            mouseCapability: false,
            keyboardCapability: false,
            windowSelectionCapability: false,
            clipboardCapability: false,
            backgroundControlCapability: false
        )
        let duplicate = lastSessionState == snapshot
        if !duplicate { lastSessionState = snapshot }
        lock.unlock()
        guard !duplicate else { return }
        fileLog.record(.sessionState(
            state: state,
            authorized: authorized,
            windowAuthorized: windowAuthorized,
            videoCapability: false,
            mouseCapability: false,
            keyboardCapability: false,
            windowSelectionCapability: false,
            clipboardCapability: false,
            backgroundControlCapability: false
        ))
    }

    func recordWindowCatalog(eligibleCount: UInt64, selected: Bool) {
        lock.lock()
        let duplicate = lastWindowCatalog?.0 == eligibleCount && lastWindowCatalog?.1 == selected
        if !duplicate { lastWindowCatalog = (eligibleCount, selected) }
        lock.unlock()
        guard !duplicate else { return }
        fileLog.record(.windowCatalog(eligibleCount: eligibleCount, selected: selected))
    }

    func recordWindowSelection(_ state: M10ViewerWindowSelection) {
        lock.lock()
        let duplicate = lastWindowSelection == state
        if !duplicate { lastWindowSelection = state }
        lock.unlock()
        guard !duplicate else { return }
        fileLog.record(.windowSelection(state))
    }

    func recordInputReadiness(
        _ readiness: M10ViewerInputReadiness,
        reason: M10ViewerInputReason,
        keyboardAvailable: Bool
    ) {
        lock.lock()
        let duplicate = lastInputReadiness?.0 == readiness &&
            lastInputReadiness?.1 == reason &&
            lastInputReadiness?.2 == keyboardAvailable
        if !duplicate { lastInputReadiness = (readiness, reason, keyboardAvailable) }
        lock.unlock()
        guard !duplicate else { return }
        fileLog.record(.inputReadiness(
            readiness: readiness,
            reason: reason,
            keyboardAvailable: keyboardAvailable
        ))
    }

    func recordConnectionOutcome(_ outcome: M10ViewerConnectionOutcome) {
        fileLog.record(.connectionOutcome(outcome))
    }

    func record(_ event: M10ViewerDiagnosticEvent) {
        fileLog.record(event)
    }

    func waitForPendingWrites() {
        fileLog.waitForPendingWrites()
    }
}

/// A low-frequency watchdog for delays on the AppKit/MainActor executor.
final class M10MainActorStallMonitor: @unchecked Sendable {
    static let shared = M10MainActorStallMonitor()
    static let releaseAuditMarker = "MACREMOTEAPP_M10_DEBUG_DIAGNOSTICS"

    private static let stallThresholdNanoseconds = M10ViewerRunLoopStallPolicy.thresholdNanoseconds
    private static let repeatedReportIntervalNanoseconds: UInt64 = 5_000_000_000
    private static let logger = Logger(
        subsystem: "com.rudinyu.MacRemoteApp",
        category: "m10-debug"
    )

    private let lock = NSLock()
    private let watchdogQueue = DispatchQueue(label: "com.rudinyu.MacRemoteApp.m10-debug-watchdog", qos: .utility)
    private var started = false
    private var role = M10DebugRole.viewer.rawValue
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
        M10ViewerDiagnosticRecorder.shared.start()
        installRunLoopObserver()

        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.checkHeartbeat() }

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
        guard M10ViewerRunLoopStallPolicy.detectsStall(
            from: .beforeSources,
            to: .beforeWaiting,
            elapsedNanoseconds: elapsed
        ) else { return }
        let duration = elapsed / 1_000_000
        M10ViewerDiagnosticRecorder.shared.record(.runLoopStalled(
            durationMilliseconds: duration,
            phase: .beforeSources
        ))
        M10ViewerDiagnosticRecorder.shared.record(.runLoopRecovered(
            durationMilliseconds: duration,
            phase: .beforeWaiting
        ))
    }

    private func recordHeartbeat() {
        let recovery: (role: String, durationNanoseconds: UInt64)?
        lock.lock()
        // Sample inside the lock so this timestamp follows the same ordering as
        // watchdog checks of `lastHeartbeatNanoseconds`.
        let now = DispatchTime.now().uptimeNanoseconds
        lastHeartbeatNanoseconds = now
        if let startedAt = activeStallStartedAt {
            activeStallStartedAt = nil
            recovery = (
                role,
                M10ViewerHeartbeatTiming.elapsedNanoseconds(now: now, since: startedAt) ?? 0
            )
        } else {
            recovery = nil
        }
        lock.unlock()

        if let recovery {
            M10ViewerDiagnosticRecorder.shared.record(
                .mainActorRecovered(durationMilliseconds: recovery.durationNanoseconds / 1_000_000)
            )
            Self.logger.notice(
                "M10 main actor recovered role=\(recovery.role, privacy: .public) durationMs=\(recovery.durationNanoseconds / 1_000_000, privacy: .public)"
            )
        }
    }

    private func checkHeartbeat() {
        let report: (role: String, durationNanoseconds: UInt64)?
        lock.lock()
        // Sampling before locking can leave `now` older than a heartbeat that
        // was written while this watchdog waited, making UInt64 subtraction
        // trap. Keep the sample and comparisons in the heartbeat's lock order.
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = M10ViewerHeartbeatTiming.elapsedNanoseconds(
            now: now,
            since: lastHeartbeatNanoseconds
        )
        let timeSinceLastReport = M10ViewerHeartbeatTiming.elapsedNanoseconds(
            now: now,
            since: lastStallReportNanoseconds
        )
        if let elapsed,
           elapsed >= Self.stallThresholdNanoseconds,
           (lastStallReportNanoseconds == 0 ||
            timeSinceLastReport.map { $0 >= Self.repeatedReportIntervalNanoseconds } == true) {
            if activeStallStartedAt == nil { activeStallStartedAt = lastHeartbeatNanoseconds }
            lastStallReportNanoseconds = now
            report = (role, elapsed)
        } else {
            report = nil
        }
        lock.unlock()

        if let report {
            M10ViewerDiagnosticRecorder.shared.record(
                .mainActorStalled(durationMilliseconds: report.durationNanoseconds / 1_000_000)
            )
            Self.logger.error(
                "M10 main actor stalled role=\(report.role, privacy: .public) durationMs=\(report.durationNanoseconds / 1_000_000, privacy: .public)"
            )
        }
    }
}
#endif
