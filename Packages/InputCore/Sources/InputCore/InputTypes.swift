import Foundation

public enum InputCoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidSurface
    case outsideContentSurface
    case inputNotReady(InputReadiness)
    case invalidEvent
    case rateLimited
    case eventTooLarge(actual: Int, maximum: Int)
    case sequenceOverflow

    public var description: String {
        switch self {
        case .invalidSurface:
            return "remote content surface is invalid"
        case .outsideContentSurface:
            return "pointer location is outside the remote content surface"
        case let .inputNotReady(readiness):
            return "input is not ready: \(readiness.label)"
        case .invalidEvent:
            return "input event is invalid"
        case .rateLimited:
            return "input event rate limit exceeded"
        case let .eventTooLarge(actual, maximum):
            return "input event size \(actual) exceeds maximum \(maximum)"
        case .sequenceOverflow:
            return "input event sequence overflow"
        }
    }
}

public enum InputReadiness: Equatable, Sendable {
    case awaitingAuthentication
    case awaitingAuthorization
    case surfaceUnavailable
    case hostPermissionUnavailable
    case hostFocusUnavailable
    case hostStateUnavailable
    case hostControlNegotiating
    case hostControlUnavailable
    case hostProcessTargetUnavailable
    case ready(windowGeneration: UInt64)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .awaitingAuthentication:
            return "Input disabled: authenticating"
        case .awaitingAuthorization:
            return "Input disabled: authorization required"
        case .surfaceUnavailable:
            return "Input disabled: remote content unavailable"
        case .hostPermissionUnavailable:
            return "Input disabled: Host PostEvent permission unavailable"
        case .hostFocusUnavailable:
            return "Input disabled: Host window is not foreground-eligible"
        case .hostStateUnavailable:
            return "Input disabled: Host input status unavailable"
        case .hostControlNegotiating:
            return "Input disabled: Host control setup is pending"
        case .hostControlUnavailable:
            return "Input disabled: Host has not granted Viewer control"
        case .hostProcessTargetUnavailable:
            return "Input disabled: Host target is not currently safe for process control"
        case .ready:
            return "Input ready"
        }
    }
}

public struct InputPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct InputContentRect: Equatable, Sendable {
    public let originX: Double
    public let originY: Double
    public let width: Double
    public let height: Double

    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        originX.isFinite && originY.isFinite &&
            width.isFinite && height.isFinite &&
            width > 0 && height > 0
    }
}

public struct NormalizedInputCoordinate: Equatable, Sendable {
    public let x: UInt16
    public let y: UInt16

    public init(x: UInt16, y: UInt16) {
        self.x = x
        self.y = y
    }
}

public enum InputEventKind: UInt8, Equatable, Hashable, Sendable {
    case pointerMove = 1
    case pointerButton = 2
    case scroll = 3
    case keyDown = 4
    case keyUp = 5
    case focusIntent = 6
    /// Committed text from the Viewer's own input method (ADR-0008).
    case text = 7
}

public struct InputEventLimits: Equatable, Sendable {
    public static let `default` = InputEventLimits()

    public let maxEventsPerSecond: Int
    public let maxEncodedPayloadBytes: Int
    public let maxScrollDelta: Double
    public let maxButtonNumber: UInt8

    public init(
        maxEventsPerSecond: Int = 240,
        maxEncodedPayloadBytes: Int = 512,
        maxScrollDelta: Double = 10_000,
        maxButtonNumber: UInt8 = 31
    ) {
        self.maxEventsPerSecond = maxEventsPerSecond
        self.maxEncodedPayloadBytes = maxEncodedPayloadBytes
        self.maxScrollDelta = maxScrollDelta
        self.maxButtonNumber = maxButtonNumber
    }
}

public enum InputEventPriority: Equatable, Sendable {
    case regular
    case stateEnding
}

public enum InputStateKey: Hashable, Sendable {
    case pointerButton(UInt8)
    case key(UInt16)
}

public enum InputStateTransition: Sendable {
    case began(InputStateKey)
    case ended(InputStateKey)
}

/// Tracks only input state that has been admitted to the outgoing event
/// stream. The Viewer uses this to keep a pressed state alive until its
/// matching release has been emitted, including during a readiness transition.
public struct InputStateTracker: Sendable {
    public private(set) var activeKeys: Set<InputStateKey> = []

    public init() {}

    public var isEmpty: Bool { activeKeys.isEmpty }

    public func contains(_ key: InputStateKey) -> Bool {
        activeKeys.contains(key)
    }

    @discardableResult
    public mutating func apply(_ transition: InputStateTransition) -> Bool {
        switch transition {
        case let .began(key):
            return activeKeys.insert(key).inserted
        case let .ended(key):
            return activeKeys.remove(key) != nil
        }
    }

    public mutating func reset() {
        activeKeys.removeAll(keepingCapacity: false)
    }
}

public enum ModifierKeyTransition: Equatable, Sendable {
    case pressed
    case released
}

/// Tracks physical modifier transitions from AppKit flagsChanged events.
///
/// AppKit's modifierFlags are an aggregate mask, so they cannot distinguish a
/// left-key release while the right key of the same modifier is still held.
/// The flagsChanged keyCode is therefore treated as a per-key toggle.  After
/// focus loss, the aggregate mask is used only to find an all-released point;
/// events observed while the physical state is unknown are discarded so a
/// stale release cannot become a new press.
public struct ModifierKeyTracker: Sendable {
    public private(set) var pressedKeyCodes: Set<UInt16> = []
    public private(set) var isResynchronizing = false

    public init() {}

    public mutating func beginResynchronization() {
        pressedKeyCodes.removeAll(keepingCapacity: false)
        isResynchronizing = true
    }

    /// Completes focus resynchronization once the aggregate modifier mask is
    /// observed clear. The event that clears the mask is consumed.
    @discardableResult
    public mutating func observeAggregateState(isPressed: Bool) -> Bool {
        guard isResynchronizing else { return true }
        guard !isPressed else { return false }
        pressedKeyCodes.removeAll(keepingCapacity: false)
        isResynchronizing = false
        return false
    }

    /// Applies one physical flagsChanged transition for the specified key.
    /// Returns nil while the tracker is waiting for a safe resynchronization
    /// point.
    @discardableResult
    public mutating func toggle(keyCode: UInt16) -> ModifierKeyTransition? {
        guard !isResynchronizing else { return nil }
        if pressedKeyCodes.insert(keyCode).inserted {
            return .pressed
        }
        pressedKeyCodes.remove(keyCode)
        return .released
    }

    @discardableResult
    public mutating func reconcile(keyCode: UInt16, isPressed: Bool) -> Bool {
        if isPressed {
            return pressedKeyCodes.insert(keyCode).inserted
        }
        return pressedKeyCodes.remove(keyCode) != nil
    }

    public mutating func reset() {
        pressedKeyCodes.removeAll(keepingCapacity: false)
        isResynchronizing = false
    }
}

/// A platform-neutral input record. Wire serialization remains in the app
/// composition layer so InputCore does not depend on RemoteProtocol.
public struct InputEventRecord: Equatable, Sendable {
    public let sequence: UInt64
    public let timestampNanoseconds: UInt64
    public let windowGeneration: UInt64
    public let kind: InputEventKind
    public let x: UInt16?
    public let y: UInt16?
    public let button: UInt8?
    public let pressed: Bool?
    public let deltaX: Int32?
    public let deltaY: Int32?
    public let keyCode: UInt16?
    public let modifiers: UInt32?
    /// Committed text for kind `text` only. Never logged.
    public let text: String?

    /// Matches the RemoteProtocol `InputEvent` text bound (ADR-0008).
    public static let maximumTextBytes = 256

    /// Non-empty, at most `maximumTextBytes` UTF-8 bytes, no control
    /// characters. Control keys such as Return travel as key events.
    public static func isValidText(_ text: String) -> Bool {
        let byteCount = text.utf8.count
        guard byteCount > 0, byteCount <= maximumTextBytes else { return false }
        return !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    public init(
        sequence: UInt64,
        timestampNanoseconds: UInt64,
        windowGeneration: UInt64,
        kind: InputEventKind,
        x: UInt16? = nil,
        y: UInt16? = nil,
        button: UInt8? = nil,
        pressed: Bool? = nil,
        deltaX: Int32? = nil,
        deltaY: Int32? = nil,
        keyCode: UInt16? = nil,
        modifiers: UInt32? = nil,
        text: String? = nil
    ) {
        self.sequence = sequence
        self.timestampNanoseconds = timestampNanoseconds
        self.windowGeneration = windowGeneration
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.pressed = pressed
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.text = text
    }

    public func validate(limits: InputEventLimits = .default) throws {
        guard windowGeneration > 0 else { throw InputCoreError.invalidEvent }
        if kind == .text {
            guard let text, Self.isValidText(text) else { throw InputCoreError.invalidEvent }
        } else {
            guard text == nil else { throw InputCoreError.invalidEvent }
        }
        switch kind {
        case .pointerMove:
            guard x != nil, y != nil,
                  button == nil, pressed == nil,
                  deltaX == nil, deltaY == nil,
                  keyCode == nil, modifiers == nil else {
                throw InputCoreError.invalidEvent
            }
        case .pointerButton:
            guard x != nil, y != nil, let button, pressed != nil,
                  button <= limits.maxButtonNumber,
                  deltaX == nil, deltaY == nil,
                  keyCode == nil, modifiers == nil else {
                throw InputCoreError.invalidEvent
            }
        case .scroll:
            guard x != nil, y != nil, let deltaX, let deltaY,
                  Double(abs(Int64(deltaX))) <= limits.maxScrollDelta,
                  Double(abs(Int64(deltaY))) <= limits.maxScrollDelta,
                  button == nil, pressed == nil,
                  keyCode == nil, modifiers == nil else {
                throw InputCoreError.invalidEvent
            }
        case .keyDown, .keyUp:
            guard keyCode != nil, modifiers != nil,
                  x == nil, y == nil,
                  button == nil, pressed == nil,
                  deltaX == nil, deltaY == nil else {
                throw InputCoreError.invalidEvent
            }
        case .focusIntent, .text:
            guard x == nil, y == nil,
                  button == nil, pressed == nil,
                  deltaX == nil, deltaY == nil,
                  keyCode == nil, modifiers == nil else {
                throw InputCoreError.invalidEvent
            }
        }
        guard estimatedEncodedPayloadBytes <= limits.maxEncodedPayloadBytes else {
            throw InputCoreError.eventTooLarge(
                actual: estimatedEncodedPayloadBytes,
                maximum: limits.maxEncodedPayloadBytes
            )
        }
    }

    /// Exact size for the M1 schema's field framing, excluding the envelope.
    /// Keeping this estimate here lets the Viewer reject oversized records
    /// before constructing a wire message.
    public var estimatedEncodedPayloadBytes: Int {
        var size = 1 // schema version
        size += fieldSize(1, valueBytes: 1)
        size += fieldSize(2, valueBytes: 8)
        if x != nil { size += fieldSize(3, valueBytes: 2) }
        if y != nil { size += fieldSize(4, valueBytes: 2) }
        if button != nil { size += fieldSize(5, valueBytes: 1) }
        if pressed != nil { size += fieldSize(6, valueBytes: 1) }
        if deltaX != nil { size += fieldSize(7, valueBytes: 4) }
        if deltaY != nil { size += fieldSize(8, valueBytes: 4) }
        if keyCode != nil { size += fieldSize(9, valueBytes: 2) }
        if modifiers != nil { size += fieldSize(10, valueBytes: 4) }
        if let text { size += fieldSize(12, valueBytes: text.utf8.count) }
        return size
    }

    /// Splits a committed string into wire-sized pieces on character
    /// boundaries, dropping control characters (Return and Tab are sent as key
    /// events instead).
    public static func splitText(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for character in text {
            if character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                continue
            }
            if (current + String(character)).utf8.count > maximumTextBytes, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.filter(isValidText)
    }

    private func fieldSize(_ fieldID: UInt8, valueBytes: Int) -> Int {
        _ = fieldID
        return 1 + 1 + 4 + valueBytes
    }
}

public struct InputEventNormalizer: Sendable {
    public private(set) var contentRect: InputContentRect
    public private(set) var readiness: InputReadiness
    public let limits: InputEventLimits

    private var nextSequence: UInt64 = 0
    private var activeButtons: Set<UInt8> = []
    private var lastValidCoordinate: NormalizedInputCoordinate?
    private var pendingScrollDeltaX = 0.0
    private var pendingScrollDeltaY = 0.0

    public init(
        contentRect: InputContentRect,
        readiness: InputReadiness,
        limits: InputEventLimits = .default
    ) {
        self.contentRect = contentRect
        self.readiness = readiness
        self.limits = limits
    }

    public mutating func update(
        contentRect: InputContentRect,
        readiness: InputReadiness
    ) {
        if readiness != self.readiness {
            activeButtons.removeAll(keepingCapacity: false)
            lastValidCoordinate = nil
            pendingScrollDeltaX = 0
            pendingScrollDeltaY = 0
        }
        self.contentRect = contentRect
        self.readiness = readiness
    }

    public mutating func pointerMove(
        at point: InputPoint,
        timestampNanoseconds: UInt64
    ) throws -> InputEventRecord {
        let coordinate = try coordinate(for: point)
        let record = try makeRecord(
            timestampNanoseconds: timestampNanoseconds,
            kind: .pointerMove,
            x: coordinate.x,
            y: coordinate.y
        )
        lastValidCoordinate = coordinate
        return record
    }

    public mutating func pointerButton(
        at point: InputPoint,
        button: UInt8,
        pressed: Bool,
        timestampNanoseconds: UInt64
    ) throws -> InputEventRecord {
        let normalizedCoordinate: NormalizedInputCoordinate
        if !pressed, activeButtons.contains(button), let lastValidCoordinate {
            normalizedCoordinate = lastValidCoordinate
        } else {
            normalizedCoordinate = try coordinate(for: point)
        }
        let record = try makeRecord(
            timestampNanoseconds: timestampNanoseconds,
            kind: .pointerButton,
            x: normalizedCoordinate.x,
            y: normalizedCoordinate.y,
            button: button,
            pressed: pressed
        )
        if pressed {
            activeButtons.insert(button)
        } else {
            activeButtons.remove(button)
        }
        lastValidCoordinate = normalizedCoordinate
        return record
    }

    public mutating func scroll(
        at point: InputPoint,
        deltaX: Double,
        deltaY: Double,
        timestampNanoseconds: UInt64
    ) throws -> InputEventRecord {
        let coordinate = try coordinate(for: point)
        guard deltaX.isFinite, deltaY.isFinite,
              abs(deltaX) <= limits.maxScrollDelta,
              abs(deltaY) <= limits.maxScrollDelta else {
            throw InputCoreError.invalidEvent
        }
        let (normalizedDeltaX, nextPendingDeltaX) = try quantizedScrollDelta(
            deltaX,
            pendingDelta: pendingScrollDeltaX
        )
        let (normalizedDeltaY, nextPendingDeltaY) = try quantizedScrollDelta(
            deltaY,
            pendingDelta: pendingScrollDeltaY
        )
        let record = try makeRecord(
            timestampNanoseconds: timestampNanoseconds,
            kind: .scroll,
            x: coordinate.x,
            y: coordinate.y,
            deltaX: normalizedDeltaX,
            deltaY: normalizedDeltaY
        )
        pendingScrollDeltaX = nextPendingDeltaX
        pendingScrollDeltaY = nextPendingDeltaY
        lastValidCoordinate = coordinate
        return record
    }

    public mutating func key(
        keyCode: UInt16,
        modifiers: UInt32,
        pressed: Bool,
        timestampNanoseconds: UInt64
    ) throws -> InputEventRecord {
        try makeRecord(
            timestampNanoseconds: timestampNanoseconds,
            kind: pressed ? .keyDown : .keyUp,
            keyCode: keyCode,
            modifiers: modifiers
        )
    }

    public mutating func focusIntent(timestampNanoseconds: UInt64) throws -> InputEventRecord {
        try makeRecord(timestampNanoseconds: timestampNanoseconds, kind: .focusIntent)
    }

    /// Committed text from the Viewer's input method. Callers split longer
    /// commits with `InputEventRecord.splitText(_:)`.
    public mutating func text(_ text: String, timestampNanoseconds: UInt64) throws -> InputEventRecord {
        try makeRecord(timestampNanoseconds: timestampNanoseconds, kind: .text, text: text)
    }

    private func coordinate(for point: InputPoint) throws -> NormalizedInputCoordinate {
        guard contentRect.isValid else { throw InputCoreError.invalidSurface }
        guard point.x.isFinite, point.y.isFinite else {
            throw InputCoreError.outsideContentSurface
        }
        let localX = point.x - contentRect.originX
        let localY = point.y - contentRect.originY
        guard localX >= 0, localY >= 0,
              localX <= contentRect.width, localY <= contentRect.height else {
            throw InputCoreError.outsideContentSurface
        }
        let normalizedX = min(65_535, max(0, (localX / contentRect.width * 65_535).rounded()))
        let normalizedY = min(65_535, max(0, (localY / contentRect.height * 65_535).rounded()))
        return NormalizedInputCoordinate(x: UInt16(normalizedX), y: UInt16(normalizedY))
    }

    private mutating func makeRecord(
        timestampNanoseconds: UInt64,
        kind: InputEventKind,
        x: UInt16? = nil,
        y: UInt16? = nil,
        button: UInt8? = nil,
        pressed: Bool? = nil,
        deltaX: Int32? = nil,
        deltaY: Int32? = nil,
        keyCode: UInt16? = nil,
        modifiers: UInt32? = nil,
        text: String? = nil
    ) throws -> InputEventRecord {
        guard case let .ready(windowGeneration) = readiness else {
            throw InputCoreError.inputNotReady(readiness)
        }
        guard contentRect.isValid else { throw InputCoreError.invalidSurface }
        guard nextSequence < UInt64.max else {
            throw InputCoreError.sequenceOverflow
        }
        let record = InputEventRecord(
            sequence: nextSequence,
            timestampNanoseconds: timestampNanoseconds,
            windowGeneration: windowGeneration,
            kind: kind,
            x: x,
            y: y,
            button: button,
            pressed: pressed,
            deltaX: deltaX,
            deltaY: deltaY,
            keyCode: keyCode,
            modifiers: modifiers,
            text: text
        )
        try record.validate(limits: limits)
        guard record.estimatedEncodedPayloadBytes <= limits.maxEncodedPayloadBytes else {
            throw InputCoreError.eventTooLarge(
                actual: record.estimatedEncodedPayloadBytes,
                maximum: limits.maxEncodedPayloadBytes
            )
        }
        nextSequence += 1
        return record
    }

    private func boundedInt32(_ value: Double) throws -> Int32 {
        guard value.isFinite else {
            throw InputCoreError.invalidEvent
        }
        let rounded = value.rounded()
        guard rounded >= Double(Int32.min),
              rounded <= Double(Int32.max) else {
            throw InputCoreError.invalidEvent
        }
        return Int32(rounded)
    }

    private func quantizedScrollDelta(
        _ delta: Double,
        pendingDelta: Double
    ) throws -> (value: Int32, pendingDelta: Double) {
        let accumulated = pendingDelta + delta
        let rounded = accumulated.rounded()
        if rounded.isFinite,
           rounded >= Double(Int32.min),
           rounded <= Double(Int32.max),
           abs(rounded) <= limits.maxScrollDelta {
            return (Int32(rounded), accumulated - rounded)
        }

        // Preserve the pre-accumulator behavior at the configured event or
        // Int32 boundary instead of letting fractional carry make an
        // otherwise valid individual scroll event fail.
        return (try boundedInt32(delta), 0)
    }
}

public struct InputEventRateLimiter: Sendable {
    public let limits: InputEventLimits

    private var timestamps: [UInt64] = []
    private var lastTimestamp: UInt64?
    private var reservedStateEndingEvents = 0

    public init(limits: InputEventLimits = .default) {
        self.limits = limits
    }

    /// Reserves one bounded safety-lane admission for a state-ending event
    /// corresponding to an already admitted press.
    public mutating func reserveStateEndingEvent() {
        guard limits.maxEventsPerSecond > reservedStateEndingEvents else { return }
        reservedStateEndingEvents += 1
    }

    public mutating func admit(
        timestampNanoseconds: UInt64,
        priority: InputEventPriority = .regular
    ) throws {
        guard limits.maxEventsPerSecond > 0 else {
            throw InputCoreError.rateLimited
        }
        if let lastTimestamp, timestampNanoseconds < lastTimestamp {
            throw InputCoreError.invalidEvent
        }
        lastTimestamp = timestampNanoseconds
        let window = UInt64(1_000_000_000)
        let cutoff = timestampNanoseconds > window ? timestampNanoseconds - window : 0
        timestamps.removeAll { $0 < cutoff }
        if priority == .stateEnding, reservedStateEndingEvents > 0 {
            reservedStateEndingEvents -= 1
            if timestamps.count < limits.maxEventsPerSecond {
                timestamps.append(timestampNanoseconds)
            }
            // A release closes state that was already admitted. When the
            // regular event budget is full it uses the reserved safety lane
            // without evicting an earlier event from the accounting window.
            return
        }
        guard timestamps.count < limits.maxEventsPerSecond else {
            throw InputCoreError.rateLimited
        }
        timestamps.append(timestampNanoseconds)
    }

    public mutating func reset() {
        timestamps.removeAll(keepingCapacity: false)
        lastTimestamp = nil
        reservedStateEndingEvents = 0
    }
}
