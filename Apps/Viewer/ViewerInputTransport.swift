import Foundation
import InputCore
import RemoteProtocol
import TransportCore

private final class ViewerInputAdmissionObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var wasAdmitted = false

    func record(admitted: Bool) {
        lock.lock()
        wasAdmitted = admitted
        lock.unlock()
    }

    var mayHaveWritten: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasAdmitted
    }
}

enum ViewerInputTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case inputNotReady
    case capabilityUnavailable
    case inputSourceRequestNotAdmitted
    case localPreflightRejected
    case deliveryUncertain
    case deliveryUncertainUnknownBoundary

    var failureCategory: ViewerInputFailureCategory {
        switch self {
        case .inputNotReady, .inputSourceRequestNotAdmitted:
            return .authorizationNotReady
        case .capabilityUnavailable:
            return .capabilityUnavailable
        case .localPreflightRejected:
            return .localPreflight
        case .deliveryUncertain, .deliveryUncertainUnknownBoundary:
            return .deliveryUncertain
        }
    }

    var failureBoundary: ViewerInputSendBoundary {
        switch self {
        case .deliveryUncertain:
            return .transportSendStarted
        case .deliveryUncertainUnknownBoundary:
            return .unknown
        case .inputNotReady, .capabilityUnavailable, .inputSourceRequestNotAdmitted, .localPreflightRejected:
            return .beforeTransportInvocation
        }
    }

    var description: String {
        switch self {
        case .inputNotReady:
            return "authenticated input is not ready"
        case .capabilityUnavailable:
            return "the negotiated session does not authorize this input kind"
        case .inputSourceRequestNotAdmitted:
            return "the input-source request is no longer current"
        case .localPreflightRejected:
            return "input failed local preflight"
        case .deliveryUncertain:
            return "input delivery status is uncertain"
        case .deliveryUncertainUnknownBoundary:
            return "input delivery status is uncertain"
        }
    }
}

/// App-level composition from the platform-neutral input record to the wire
/// message. Host-side mapping and injection are deliberately not present here.
@MainActor
final class ViewerInputTransport {
    private let session: SessionCoordinator
    private let limits: InputEventLimits

    init(session: SessionCoordinator, limits: InputEventLimits = .default) {
        self.session = session
        self.limits = limits
    }

    func send(
        _ record: InputEventRecord,
        expectedAuthorizationGeneration: UInt64? = nil,
        controlGeneration: UInt64? = nil
    ) async throws {
#if DEBUG
        M10ViewerDiagnosticRecorder.shared.recordViewerInputAttempt()
        var locallyAccepted = false
        defer {
            if locallyAccepted {
                M10ViewerDiagnosticRecorder.shared.recordViewerInputLocallyAccepted()
            } else {
                M10ViewerDiagnosticRecorder.shared.recordViewerInputSendFailure()
            }
        }
#endif
        let message: InputEventMessage
        do {
            try record.validate(limits: limits)
            guard record.estimatedEncodedPayloadBytes <= limits.maxEncodedPayloadBytes else {
                throw InputCoreError.eventTooLarge(
                    actual: record.estimatedEncodedPayloadBytes,
                    maximum: limits.maxEncodedPayloadBytes
                )
            }

            message = try Self.message(for: record, controlGeneration: controlGeneration)
            // Keep this explicit so a future schema extension cannot silently turn
            // an input event into an oversized control payload.
            let encoded = try message.encoded(using: .default)
            guard encoded.count <= limits.maxEncodedPayloadBytes else {
                throw InputCoreError.eventTooLarge(
                    actual: encoded.count,
                    maximum: limits.maxEncodedPayloadBytes
                )
            }
        } catch {
            throw ViewerInputTransportError.localPreflightRejected
        }

        let admission: SessionInputAdmissionToken
        do {
            admission = try await session.makeInputAdmission(
                for: message,
                expectedAuthorizationGeneration: expectedAuthorizationGeneration
            )
        } catch let error as SessionError {
            switch error {
            case .unauthorizedMessage(.inputEvent):
                let snapshot = await session.snapshot()
                if snapshot.authorized,
                   snapshot.authorizedWindowGeneration == record.windowGeneration {
                    throw ViewerInputTransportError.capabilityUnavailable
                }
                throw ViewerInputTransportError.inputNotReady
            case .authorizationChanged, .reconnectRequired:
                throw ViewerInputTransportError.inputNotReady
            default:
                // Admission is synchronous actor-side validation. No event has
                // entered the transport, so the live session can be rechecked.
                throw ViewerInputTransportError.inputNotReady
            }
        } catch {
            // This call only creates an admission token. Any non-session error
            // here is likewise known to precede transport delivery.
            throw ViewerInputTransportError.localPreflightRejected
        }

        let sendObservation = SessionInputSendObservation()
        do {
            try await session.sendInput(
                message,
                using: admission,
                observation: sendObservation
            )
#if DEBUG
            locallyAccepted = true
#endif
        } catch {
            // Only failures after the actual transport invocation are
            // ambiguous. Earlier session validation failures remain
            // recoverable and can be retried after authorization is ready.
            if sendObservation.state == .transportSendStarted {
                throw ViewerInputTransportError.deliveryUncertain
            }
            throw ViewerInputTransportError.inputNotReady
        }
    }

    func sendInputSourceSelection(
        _ request: ViewerInputSourceSyncRequest,
        localAdmission: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        let message = InputSourceSelectionMessage(
            windowGeneration: request.scope.windowGeneration,
            requestID: request.requestID,
            kind: request.source.kind == .english ? .english : .chinese,
            sourceIdentifier: request.source.identifier,
            controlGeneration: request.scope.controlGeneration
        )
        let admissionObservation = ViewerInputAdmissionObservation()
        do {
            try await session.send(
                .inputSourceSelection(message),
                expectedAuthorizationGeneration: request.scope.authorizationGeneration,
                localAdmission: {
                    let admitted = localAdmission()
                    admissionObservation.record(admitted: admitted)
                    return admitted
                }
            )
        } catch SessionError.authorizationChanged, SessionError.reconnectRequired {
            if admissionObservation.mayHaveWritten {
                throw ViewerInputTransportError.deliveryUncertainUnknownBoundary
            }
            throw ViewerInputTransportError.inputSourceRequestNotAdmitted
        }
    }

    private static func message(
        for record: InputEventRecord,
        controlGeneration: UInt64?
    ) throws -> InputEventMessage {
        switch record.kind {
        case .pointerMove:
            guard let x = record.x, let y = record.y else { throw InputCoreError.invalidEvent }
            return InputEventMessage(
                kind: .pointerMove,
                windowGeneration: record.windowGeneration,
                x: x,
                y: y,
                controlGeneration: controlGeneration
            )
        case .pointerButton:
            guard let x = record.x, let y = record.y,
                  let button = record.button, let pressed = record.pressed else {
                throw InputCoreError.invalidEvent
            }
            return InputEventMessage(
                kind: .pointerButton,
                windowGeneration: record.windowGeneration,
                x: x,
                y: y,
                button: button,
                pressed: pressed,
                controlGeneration: controlGeneration
            )
        case .scroll:
            guard let x = record.x, let y = record.y,
                  let deltaX = record.deltaX, let deltaY = record.deltaY else {
                throw InputCoreError.invalidEvent
            }
            return InputEventMessage(
                kind: .scroll,
                windowGeneration: record.windowGeneration,
                x: x,
                y: y,
                deltaX: deltaX,
                deltaY: deltaY,
                controlGeneration: controlGeneration
            )
        case .keyDown:
            guard let keyCode = record.keyCode, let modifiers = record.modifiers else {
                throw InputCoreError.invalidEvent
            }
            return InputEventMessage(
                kind: .keyDown,
                windowGeneration: record.windowGeneration,
                keyCode: keyCode,
                modifiers: modifiers,
                controlGeneration: controlGeneration
            )
        case .keyUp:
            guard let keyCode = record.keyCode, let modifiers = record.modifiers else {
                throw InputCoreError.invalidEvent
            }
            return InputEventMessage(
                kind: .keyUp,
                windowGeneration: record.windowGeneration,
                keyCode: keyCode,
                modifiers: modifiers,
                controlGeneration: controlGeneration
            )
        case .focusIntent:
            return InputEventMessage(
                kind: .focusIntent,
                windowGeneration: record.windowGeneration,
                controlGeneration: controlGeneration
            )
        }
    }
}
