import Foundation
import InputCore
import RemoteProtocol

/// Host composition boundary from the authenticated wire message to the
/// platform-neutral M6 input record. The caller supplies the authenticated
/// envelope sequence and local monotonic arrival timestamp; no remote payload
/// is trusted as a Host timestamp or sequence.
final class HostInputMessageHandler: @unchecked Sendable {
    private let lock = NSLock()
    private let controller: HostInputController
    private var nextSequence: UInt64 = 0

    init(controller: HostInputController) {
        self.controller = controller
    }

    func handle(
        _ message: InputEventMessage,
        timestampNanoseconds: UInt64
    ) throws -> HostInputInjectionReceipt {
        lock.lock()
        defer { lock.unlock() }
        guard nextSequence < UInt64.max else {
            throw HostInputError.invalidEvent
        }
        let record = try Self.record(
            from: message,
            sequence: nextSequence,
            timestampNanoseconds: timestampNanoseconds
        )
        nextSequence += 1
        return try controller.inject(record)
    }

    /// The receive-time admission closure calls this synchronously. Never take
    /// `lock` on the background caller before hopping: the AppKit status path
    /// can be waiting on the main thread at the same time.
    func synchronizeInputSource(
        descriptor: InputSourceDescriptor,
        windowGeneration: UInt64
    ) -> InputSourceSelectionOutcome {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                controller.synchronizeInputSource(
                    descriptor: descriptor,
                    windowGeneration: windowGeneration,
                    provider: SystemInputSourceProvider()
                )
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                controller.synchronizeInputSource(
                    descriptor: descriptor,
                    windowGeneration: windowGeneration,
                    provider: SystemInputSourceProvider()
                )
            }
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        nextSequence = 0
        controller.resetInputState()
    }

    func reconcileInputState() {
        lock.lock()
        defer { lock.unlock() }
        controller.reconcileInputState()
    }

    func status() -> HostInputStatus {
        controller.status()
    }

    func selectionSnapshot() -> HostInputSelectionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return controller.selectionSnapshot()
    }

    func pendingInputTarget() -> HostInputTarget? {
        lock.lock()
        defer { lock.unlock() }
        return controller.pendingInputTarget()
    }

    private static func record(
        from message: InputEventMessage,
        sequence: UInt64,
        timestampNanoseconds: UInt64
    ) throws -> InputEventRecord {
        switch message.kind {
        case .pointerMove:
            guard let x = message.x, let y = message.y else {
                throw HostInputError.invalidEvent
            }
            return InputEventRecord(
                sequence: sequence,
                timestampNanoseconds: timestampNanoseconds,
                windowGeneration: message.windowGeneration,
                kind: .pointerMove,
                x: x,
                y: y
            )
        case .pointerButton:
            guard let x = message.x, let y = message.y,
                  let button = message.button, let pressed = message.pressed else {
                throw HostInputError.invalidEvent
            }
            return InputEventRecord(
                sequence: sequence,
                timestampNanoseconds: timestampNanoseconds,
                windowGeneration: message.windowGeneration,
                kind: .pointerButton,
                x: x,
                y: y,
                button: button,
                pressed: pressed
            )
        case .scroll:
            guard let x = message.x, let y = message.y,
                  let deltaX = message.deltaX, let deltaY = message.deltaY else {
                throw HostInputError.invalidEvent
            }
            return InputEventRecord(
                sequence: sequence,
                timestampNanoseconds: timestampNanoseconds,
                windowGeneration: message.windowGeneration,
                kind: .scroll,
                x: x,
                y: y,
                deltaX: deltaX,
                deltaY: deltaY
            )
        case .keyDown:
            guard let keyCode = message.keyCode, let modifiers = message.modifiers else {
                throw HostInputError.invalidEvent
            }
            return InputEventRecord(
                sequence: sequence,
                timestampNanoseconds: timestampNanoseconds,
                windowGeneration: message.windowGeneration,
                kind: .keyDown,
                keyCode: keyCode,
                modifiers: modifiers
            )
        case .keyUp:
            guard let keyCode = message.keyCode, let modifiers = message.modifiers else {
                throw HostInputError.invalidEvent
            }
            return InputEventRecord(
                sequence: sequence,
                timestampNanoseconds: timestampNanoseconds,
                windowGeneration: message.windowGeneration,
                kind: .keyUp,
                keyCode: keyCode,
                modifiers: modifiers
            )
        case .focusIntent:
            return InputEventRecord(
                sequence: sequence,
                timestampNanoseconds: timestampNanoseconds,
                windowGeneration: message.windowGeneration,
                kind: .focusIntent
            )
        }
    }
}
