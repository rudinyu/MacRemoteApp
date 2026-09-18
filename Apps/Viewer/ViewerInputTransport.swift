import InputCore
import RemoteProtocol
import TransportCore

enum ViewerInputTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case inputNotReady
    case capabilityUnavailable

    var description: String {
        switch self {
        case .inputNotReady:
            return "authenticated input is not ready"
        case .capabilityUnavailable:
            return "the negotiated session does not authorize this input kind"
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

    func send(_ record: InputEventRecord) async throws {
        try record.validate(limits: limits)
        guard record.estimatedEncodedPayloadBytes <= limits.maxEncodedPayloadBytes else {
            throw InputCoreError.eventTooLarge(
                actual: record.estimatedEncodedPayloadBytes,
                maximum: limits.maxEncodedPayloadBytes
            )
        }

        let message = try Self.message(for: record)
        // Keep this explicit so a future schema extension cannot silently turn
        // an input event into an oversized control payload.
        let encoded = try message.encoded(using: .default)
        guard encoded.count <= limits.maxEncodedPayloadBytes else {
            throw InputCoreError.eventTooLarge(
                actual: encoded.count,
                maximum: limits.maxEncodedPayloadBytes
            )
        }
        let admission: SessionInputAdmissionToken
        do {
            admission = try await session.makeInputAdmission(for: message)
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
                throw error
            }
        }

        do {
            try await session.sendInput(message, using: admission)
        } catch SessionError.authorizationChanged, SessionError.reconnectRequired {
            throw ViewerInputTransportError.inputNotReady
        }
    }

    private static func message(for record: InputEventRecord) throws -> InputEventMessage {
        switch record.kind {
        case .pointerMove:
            guard let x = record.x, let y = record.y else { throw InputCoreError.invalidEvent }
            return InputEventMessage(
                kind: .pointerMove,
                windowGeneration: record.windowGeneration,
                x: x,
                y: y
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
                pressed: pressed
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
                deltaY: deltaY
            )
        case .keyDown:
            guard let keyCode = record.keyCode, let modifiers = record.modifiers else {
                throw InputCoreError.invalidEvent
            }
            return InputEventMessage(
                kind: .keyDown,
                windowGeneration: record.windowGeneration,
                keyCode: keyCode,
                modifiers: modifiers
            )
        case .keyUp:
            guard let keyCode = record.keyCode, let modifiers = record.modifiers else {
                throw InputCoreError.invalidEvent
            }
            return InputEventMessage(
                kind: .keyUp,
                windowGeneration: record.windowGeneration,
                keyCode: keyCode,
                modifiers: modifiers
            )
        case .focusIntent:
            return InputEventMessage(
                kind: .focusIntent,
                windowGeneration: record.windowGeneration
            )
        }
    }
}
