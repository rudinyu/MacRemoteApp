import Foundation

/// The Host-side PostEvent permission fact used by the final input admission
/// check. Accessibility is a separate optional enhancement for local AX
/// inspection and focused-text operations; it is not represented by this
/// base event-posting state. `unknown` is intentionally not treated as
/// authorized.
public enum HostInputPermissionState: Equatable, Sendable {
    case authorized
    case missing
    case unknown
}

/// Foreground and process-target safety are distinct Host facts. A P6 target
/// may pass its process safety checks while inactive, but ordinary input is
/// admitted only while the selected application is foreground. Background
/// eligibility is retained only to decide whether cleanup releases are safe.
public enum HostInputFocusState: Equatable, Sendable {
    case eligible
    /// The selected process passes P6 safety checks, but is not frontmost.
    /// This state never admits ordinary input; it can support safe cleanup of
    /// state admitted while the target was foreground.
    case backgroundEligible
    case windowUnavailable
    case notForeground
    case lockedScreen
    case secureInput
    case unknown
}

public enum HostInputCapability: Equatable, Sendable {
    case mouse
    case keyboard
}

/// AppKit's device-independent modifier flags occupy the high 16 bits. The
/// Viewer already intersects its flags with this mask; the Host checks it
/// again before constructing a platform event.
public enum HostInputModifierMask {
    public static let allowedRawValue: UInt32 = 0xffff_0000
}

public struct InputWindowBounds: Equatable, Sendable {
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
        guard originX.isFinite, originY.isFinite,
              width.isFinite, height.isFinite,
              width > 0, height > 0 else {
            return false
        }
        let maxX = originX + width
        let maxY = originY + height
        return maxX.isFinite && maxY.isFinite &&
            maxX > originX && maxY > originY
    }

    fileprivate func map(_ coordinate: NormalizedInputCoordinate) -> InputScreenPoint? {
        guard isValid else { return nil }
        let maxX = (originX + width).nextDown
        let maxY = (originY + height).nextDown
        let x = min(
            originX + (Double(coordinate.x) / Double(UInt16.max)) * width,
            maxX
        )
        let y = min(
            originY + (Double(coordinate.y) / Double(UInt16.max)) * height,
            maxY
        )
        let point = InputScreenPoint(x: x, y: y)
        return point.isValid ? point : nil
    }
}

/// The Host's current selected-window identity. The generation is issued by
/// CaptureCore and must change whenever selection or window ownership changes.
public struct HostInputWindowSelection: Equatable, Sendable {
    public let windowIdentifier: UInt64
    public let processIdentifier: Int32
    public let applicationIdentifier: String
    public let generation: UInt64
    public let bounds: InputWindowBounds

    public init(
        windowIdentifier: UInt64,
        processIdentifier: Int32,
        applicationIdentifier: String,
        generation: UInt64,
        bounds: InputWindowBounds
    ) {
        self.windowIdentifier = windowIdentifier
        self.processIdentifier = processIdentifier
        self.applicationIdentifier = applicationIdentifier
        self.generation = generation
        self.bounds = bounds
    }
}

/// Session facts that the Host application supplies to the platform context
/// provider. SecurityCore/TransportCore own how these facts are established;
/// InputCore only requires the already-authorized result.
public struct HostInputSessionState: Equatable, Sendable {
    public let authorized: Bool
    public let authorizedWindowGeneration: UInt64?
    public let mouseInputEnabled: Bool
    public let keyboardInputEnabled: Bool
    public let processTargetingAuthorized: Bool

    public init(
        authorized: Bool,
        authorizedWindowGeneration: UInt64?,
        mouseInputEnabled: Bool,
        keyboardInputEnabled: Bool,
        processTargetingAuthorized: Bool = false
    ) {
        self.authorized = authorized
        self.authorizedWindowGeneration = authorizedWindowGeneration
        self.mouseInputEnabled = mouseInputEnabled
        self.keyboardInputEnabled = keyboardInputEnabled
        self.processTargetingAuthorized = processTargetingAuthorized
    }
}

/// A complete snapshot used for one final, immediate admission check.
public struct HostInputContext: Equatable, Sendable {
    public let sessionAuthorized: Bool
    public let authorizedWindowGeneration: UInt64?
    public let selectedWindow: HostInputWindowSelection?
    public let currentWindowIdentifier: UInt64?
    public let currentProcessIdentifier: Int32?
    public let currentApplicationIdentifier: String?
    public let currentWindowBounds: InputWindowBounds?
    public let permission: HostInputPermissionState
    public let focus: HostInputFocusState
    public let mouseInputEnabled: Bool
    public let keyboardInputEnabled: Bool
    public let processTargetingAuthorized: Bool

    public init(
        sessionAuthorized: Bool,
        authorizedWindowGeneration: UInt64?,
        selectedWindow: HostInputWindowSelection?,
        currentWindowIdentifier: UInt64?,
        currentProcessIdentifier: Int32?,
        currentApplicationIdentifier: String? = nil,
        currentWindowBounds: InputWindowBounds?,
        permission: HostInputPermissionState,
        focus: HostInputFocusState,
        mouseInputEnabled: Bool,
        keyboardInputEnabled: Bool,
        processTargetingAuthorized: Bool = false
    ) {
        self.sessionAuthorized = sessionAuthorized
        self.authorizedWindowGeneration = authorizedWindowGeneration
        self.selectedWindow = selectedWindow
        self.currentWindowIdentifier = currentWindowIdentifier
        self.currentProcessIdentifier = currentProcessIdentifier
        self.currentApplicationIdentifier = currentApplicationIdentifier
        self.currentWindowBounds = currentWindowBounds
        self.permission = permission
        self.focus = focus
        self.mouseInputEnabled = mouseInputEnabled
        self.keyboardInputEnabled = keyboardInputEnabled
        self.processTargetingAuthorized = processTargetingAuthorized
    }
}

/// Identity facts that must remain stable while the Host has admitted pressed
/// input state. Geometry may change during a resize, but a different selected
/// window or selection generation must reset the controller before the next
/// event can be admitted.
public struct HostInputSelectionSnapshot: Equatable, Sendable {
    public let sessionAuthorized: Bool
    public let authorizedWindowGeneration: UInt64?
    public let selectedTarget: HostInputTarget?
    public let currentWindowIdentifier: UInt64?
    public let currentProcessIdentifier: Int32?

    public init(context: HostInputContext) {
        self.sessionAuthorized = context.sessionAuthorized
        self.authorizedWindowGeneration = context.authorizedWindowGeneration
        self.selectedTarget = context.selectedWindow.map(HostInputTarget.init(selection:))
        self.currentWindowIdentifier = context.currentWindowIdentifier
        self.currentProcessIdentifier = context.currentProcessIdentifier
    }

    /// Returns whether the selected target identity is unchanged. The current
    /// frontmost window/process are deliberately excluded: they describe
    /// focus state, not a CaptureCore selection replacement.
    public func hasSameSelectedTarget(as other: HostInputSelectionSnapshot) -> Bool {
        sessionAuthorized == other.sessionAuthorized &&
            authorizedWindowGeneration == other.authorizedWindowGeneration &&
            selectedTarget == other.selectedTarget
    }
}

public enum HostInputStatus: Equatable, Sendable {
    case ready
    case inputStateCleanupPending
    case sessionUnauthorized
    case selectionUnavailable
    case capabilityUnavailable
    case permissionUnavailable
    case focusUnavailable(HostInputFocusState)
}

public enum HostInputError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidEvent
    case replayedEvent
    case rateLimited
    case sessionUnauthorized
    case windowGenerationMismatch
    case windowUnavailable
    case permissionUnavailable
    case focusUnavailable(HostInputFocusState)
    case capabilityUnavailable(HostInputCapability)
    case invalidModifierMask
    case unsupportedButton
    case invalidWindowGeometry
    case unmatchedStateRelease
    case inputStateCleanupPending

    public var description: String {
        switch self {
        case .invalidEvent:
            return "Host rejected an invalid input event"
        case .replayedEvent:
            return "Host rejected a replayed input event"
        case .rateLimited:
            return "Host input rate limit exceeded"
        case .sessionUnauthorized:
            return "Host input is disabled until the session is authorized"
        case .windowGenerationMismatch:
            return "Host rejected input for a stale window generation"
        case .windowUnavailable:
            return "Host selected window is unavailable"
        case .permissionUnavailable:
            return "Host PostEvent permission is unavailable"
        case let .focusUnavailable(state):
            return "Host input focus is unavailable: \(state.label)"
        case let .capabilityUnavailable(capability):
            return "Host input capability is unavailable: \(capability.label)"
        case .invalidModifierMask:
            return "Host rejected an invalid modifier mask"
        case .unsupportedButton:
            return "Host rejected an unsupported mouse button"
        case .invalidWindowGeometry:
            return "Host selected window geometry is invalid"
        case .unmatchedStateRelease:
            return "Host rejected a release for input state it did not admit"
        case .inputStateCleanupPending:
            return "Host is still cleaning up previously admitted input state"
        }
    }
}

extension HostInputFocusState {
    public var label: String {
        switch self {
        case .eligible: return "eligible"
        case .backgroundEligible: return "inactive target is safety-checked; ordinary input requires foreground"
        case .windowUnavailable: return "window unavailable"
        case .notForeground: return "selected window is not foreground"
        case .lockedScreen: return "screen is locked"
        case .secureInput: return "secure input is active"
        case .unknown: return "focus state unknown"
        }
    }
}

extension HostInputCapability {
    public var label: String {
        switch self {
        case .mouse: return "mouse"
        case .keyboard: return "keyboard"
        }
    }
}

public struct InputScreenPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    fileprivate var isValid: Bool {
        x.isFinite && y.isFinite
    }
}

/// Identity attached to every command so the OS adapter can repeat the
/// selected-window check immediately before posting a global event.
public struct HostInputTarget: Equatable, Sendable {
    public let windowIdentifier: UInt64
    public let processIdentifier: Int32
    public let applicationIdentifier: String
    public let windowGeneration: UInt64

    public init(
        windowIdentifier: UInt64,
        processIdentifier: Int32,
        applicationIdentifier: String,
        windowGeneration: UInt64
    ) {
        self.windowIdentifier = windowIdentifier
        self.processIdentifier = processIdentifier
        self.applicationIdentifier = applicationIdentifier
        self.windowGeneration = windowGeneration
    }

    fileprivate init(selection: HostInputWindowSelection) {
        self.init(
            windowIdentifier: selection.windowIdentifier,
            processIdentifier: selection.processIdentifier,
            applicationIdentifier: selection.applicationIdentifier,
            windowGeneration: selection.generation
        )
    }
}

/// A bounded, typed command. This is the only input representation accepted
/// by the OS-facing adapter; raw NSEvent/CGEvent archives are not supported.
public enum HostInputCommand: Equatable, Sendable {
    case pointerMove(target: HostInputTarget, location: InputScreenPoint)
    case pointerButton(target: HostInputTarget, location: InputScreenPoint, button: UInt8, pressed: Bool)
    case scroll(target: HostInputTarget, location: InputScreenPoint, deltaX: Int32, deltaY: Int32)
    case key(target: HostInputTarget, keyCode: UInt16, modifiers: UInt32, pressed: Bool)
    case focusIntent(target: HostInputTarget)
    /// Committed text composed by the Viewer's input method (ADR-0008).
    case text(target: HostInputTarget, text: String)
}

public struct HostInputInjectionReceipt: Equatable, Sendable {
    public let sequence: UInt64
    public let windowGeneration: UInt64
    public let kind: InputEventKind

    public init(sequence: UInt64, windowGeneration: UInt64, kind: InputEventKind) {
        self.sequence = sequence
        self.windowGeneration = windowGeneration
        self.kind = kind
    }
}

public protocol HostInputContextProvider: Sendable {
    func currentContext() -> HostInputContext

    /// Returns a live context for a target that still owns admitted pressed
    /// state, even when CaptureCore has already published another selection.
    /// The default implementation keeps lightweight test providers and other
    /// providers that cannot safely identify an old target fail-closed.
    func currentReleaseContext(for target: HostInputTarget) -> HostInputContext?
}

public extension HostInputContextProvider {
    func currentReleaseContext(for target: HostInputTarget) -> HostInputContext? {
        nil
    }
}

public protocol HostInputInjectionAdapter: Sendable {
    func inject(_ command: HostInputCommand) throws
    /// Releases state previously admitted by `HostInputController` while the
    /// current target, permission, and focus remain safe. This path may be
    /// needed after session authorization has already been revoked.
    func release(_ command: HostInputCommand) throws
}

public extension HostInputInjectionAdapter {
    func release(_ command: HostInputCommand) throws {
        try inject(command)
    }
}

public enum HostInputAdapterError: Error, Equatable, Sendable, CustomStringConvertible {
    case permissionUnavailable
    case targetUnavailable
    case eventCreationFailed
    case unsupportedButton

    public var description: String {
        switch self {
        case .permissionUnavailable:
            return "Host PostEvent permission is unavailable"
        case .targetUnavailable:
            return "Host input target changed before the event was posted"
        case .eventCreationFailed:
            return "Host could not create the requested input event"
        case .unsupportedButton:
            return "Host adapter does not support this mouse button"
        }
    }
}

public enum HostInputMapper {
    public static func command(
        for record: InputEventRecord,
        in context: HostInputContext,
        limits: InputEventLimits = .default
    ) throws -> HostInputCommand {
        do {
            try record.validate(limits: limits)
        } catch {
            throw HostInputError.invalidEvent
        }

        guard context.sessionAuthorized else {
            throw HostInputError.sessionUnauthorized
        }
        guard let authorizedGeneration = context.authorizedWindowGeneration,
              authorizedGeneration == record.windowGeneration else {
            throw HostInputError.windowGenerationMismatch
        }
        guard let selection = context.selectedWindow else {
            throw HostInputError.windowUnavailable
        }
        guard selection.generation == record.windowGeneration else {
            throw HostInputError.windowGenerationMismatch
        }
        guard context.currentWindowIdentifier == selection.windowIdentifier,
              context.currentProcessIdentifier == selection.processIdentifier,
              context.currentApplicationIdentifier == selection.applicationIdentifier else {
            throw HostInputError.windowUnavailable
        }
        guard let currentBounds = context.currentWindowBounds,
              currentBounds.isValid else {
            throw HostInputError.invalidWindowGeometry
        }
        guard context.permission == .authorized else {
            throw HostInputError.permissionUnavailable
        }
        guard context.focus == .eligible else {
            throw HostInputError.focusUnavailable(context.focus)
        }

        switch record.kind {
        case .pointerMove:
            guard context.mouseInputEnabled else {
                throw HostInputError.capabilityUnavailable(.mouse)
            }
            return .pointerMove(
                target: HostInputTarget(selection: selection),
                location: try screenPoint(for: record, in: currentBounds)
            )
        case .pointerButton:
            guard context.mouseInputEnabled else {
                throw HostInputError.capabilityUnavailable(.mouse)
            }
            guard let button = record.button, button <= 2 else {
                throw HostInputError.unsupportedButton
            }
            return .pointerButton(
                target: HostInputTarget(selection: selection),
                location: try screenPoint(for: record, in: currentBounds),
                button: button,
                pressed: record.pressed ?? false
            )
        case .scroll:
            guard context.mouseInputEnabled else {
                throw HostInputError.capabilityUnavailable(.mouse)
            }
            guard let deltaX = record.deltaX, let deltaY = record.deltaY else {
                throw HostInputError.invalidEvent
            }
            return .scroll(
                target: HostInputTarget(selection: selection),
                location: try screenPoint(for: record, in: currentBounds),
                deltaX: deltaX,
                deltaY: deltaY
            )
        case .keyDown, .keyUp:
            guard context.keyboardInputEnabled else {
                throw HostInputError.capabilityUnavailable(.keyboard)
            }
            guard let keyCode = record.keyCode, let modifiers = record.modifiers else {
                throw HostInputError.invalidEvent
            }
            guard modifiers & ~HostInputModifierMask.allowedRawValue == 0 else {
                throw HostInputError.invalidModifierMask
            }
            return .key(
                target: HostInputTarget(selection: selection),
                keyCode: keyCode,
                modifiers: modifiers,
                pressed: record.kind == .keyDown
            )
        case .focusIntent:
            guard context.mouseInputEnabled else {
                throw HostInputError.capabilityUnavailable(.mouse)
            }
            return .focusIntent(target: HostInputTarget(selection: selection))
        case .text:
            guard context.keyboardInputEnabled else {
                throw HostInputError.capabilityUnavailable(.keyboard)
            }
            guard let text = record.text, InputEventRecord.isValidText(text) else {
                throw HostInputError.invalidEvent
            }
            return .text(target: HostInputTarget(selection: selection), text: text)
        }
    }

    private static func screenPoint(
        for record: InputEventRecord,
        in bounds: InputWindowBounds
    ) throws -> InputScreenPoint {
        guard let x = record.x, let y = record.y,
              let point = bounds.map(NormalizedInputCoordinate(x: x, y: y)) else {
            throw HostInputError.invalidWindowGeometry
        }
        return point
    }
}

/// Serializes Host admission and injection so a permission/focus snapshot and
/// its corresponding OS event cannot be interleaved with another event. The
/// platform provider is queried for every event; `resetInputState()` is called
/// on disconnect, authorization loss, or selected-window change.
public final class HostInputController: @unchecked Sendable {
    private let lock = NSLock()
    private let contextProvider: any HostInputContextProvider
    private let injectionAdapter: any HostInputInjectionAdapter
    private let limits: InputEventLimits
    private var lastSequence: UInt64?
    private var rateLimiter: InputEventRateLimiter
    private var activeInputState = InputStateTracker()
    private var activePointerLocations: [UInt8: InputScreenPoint] = [:]
    private var activeInputTarget: HostInputTarget?
    private var inputStateCleanupPending = false

    public init(
        contextProvider: any HostInputContextProvider,
        injectionAdapter: any HostInputInjectionAdapter,
        limits: InputEventLimits = .default
    ) {
        self.contextProvider = contextProvider
        self.injectionAdapter = injectionAdapter
        self.limits = limits
        self.rateLimiter = InputEventRateLimiter(limits: limits)
    }

    public func status() -> HostInputStatus {
        lock.lock()
        defer { lock.unlock() }
        if inputStateCleanupPending {
            return .inputStateCleanupPending
        }
        let context = contextProvider.currentContext()
        guard context.sessionAuthorized else { return .sessionUnauthorized }
        guard let selectedWindow = context.selectedWindow,
              let authorizedGeneration = context.authorizedWindowGeneration,
              authorizedGeneration == selectedWindow.generation else {
            return .selectionUnavailable
        }
        guard context.mouseInputEnabled || context.keyboardInputEnabled else {
            return .capabilityUnavailable
        }
        guard context.permission == .authorized else {
            return .permissionUnavailable
        }
        guard context.focus == .eligible else {
            return .focusUnavailable(context.focus)
        }
        guard context.currentWindowIdentifier == selectedWindow.windowIdentifier,
              context.currentProcessIdentifier == selectedWindow.processIdentifier,
              context.currentApplicationIdentifier == selectedWindow.applicationIdentifier else {
            return .focusUnavailable(.notForeground)
        }
        guard let currentBounds = context.currentWindowBounds,
              currentBounds.isValid else {
            return .selectionUnavailable
        }
        return .ready
    }

    /// Returns the selection identity used by the lifecycle owner to detect a
    /// local CaptureCore selection transition even when both old and new
    /// contexts are otherwise `.ready`.
    public func selectionSnapshot() -> HostInputSelectionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return HostInputSelectionSnapshot(context: contextProvider.currentContext())
    }

    /// Returns the exact target that still owns admitted pressed state, if any.
    /// Lifecycle cleanup uses this only to stop retrying after the selected
    /// window has changed; it never authorizes a stale target for injection.
    public func pendingInputTarget() -> HostInputTarget? {
        lock.lock()
        defer { lock.unlock() }
        return activeInputTarget
    }

    /// Follows an exact Viewer input-source request while holding the same
    /// serialization lock as keyboard injection. TIS is main-thread-only for
    /// UI applications, so this operation is main-actor isolated and repeats
    /// all keyboard authorization, target, permission, and focus checks just
    /// before a platform source change. The caller must run this synchronous
    /// operation inside the existing session admission fence on the main actor;
    /// do not hold a background admission/controller lock while hopping here.
    @MainActor
    public func synchronizeInputSource(
        descriptor requested: InputSourceDescriptor,
        windowGeneration: UInt64,
        provider: any InputSourceProvider
    ) -> InputSourceSelectionOutcome {
        lock.lock()
        defer { lock.unlock() }

        guard !inputStateCleanupPending else { return .denied }
        let initialContext = contextProvider.currentContext()
        guard Self.inputSourceContextIsEligible(
            initialContext,
            windowGeneration: windowGeneration,
            expectedTarget: nil
        ), let initialSelection = initialContext.selectedWindow else {
            return .denied
        }
        let expectedTarget = HostInputTarget(selection: initialSelection)

        let plan = InputSourceSelectionPolicy.plan(
            requested: requested,
            current: provider.currentInputSource(),
            enabled: provider.enabledInputSources()
        )
        switch plan {
        case .alreadyMatches:
            let finalContext = contextProvider.currentContext()
            guard Self.inputSourceContextIsEligible(
                finalContext,
                windowGeneration: windowGeneration,
                expectedTarget: expectedTarget
            ) else {
                return .denied
            }
            return .applied
        case .unavailable:
            return .unavailable
        case let .select(target):
            return provider.selectInputSource(
                target,
                validatingImmediatelyBeforeSelection: {
                    let finalContext = self.contextProvider.currentContext()
                    return Self.inputSourceContextIsEligible(
                        finalContext,
                        windowGeneration: windowGeneration,
                        expectedTarget: expectedTarget
                    )
                }
            )
        }
    }

    private static func inputSourceContextIsEligible(
        _ context: HostInputContext,
        windowGeneration: UInt64,
        expectedTarget: HostInputTarget?
    ) -> Bool {
        guard context.sessionAuthorized,
              context.authorizedWindowGeneration == windowGeneration,
              let selection = context.selectedWindow,
              selection.generation == windowGeneration,
              context.currentWindowIdentifier == selection.windowIdentifier,
              context.currentProcessIdentifier == selection.processIdentifier,
              context.currentApplicationIdentifier == selection.applicationIdentifier,
              let currentBounds = context.currentWindowBounds,
              currentBounds.isValid,
              context.permission == .authorized,
              context.focus == .eligible,
              context.keyboardInputEnabled else {
            return false
        }
        guard let expectedTarget else { return true }
        return HostInputTarget(selection: selection) == expectedTarget
    }

    public func inject(_ record: InputEventRecord) throws -> HostInputInjectionReceipt {
        lock.lock()
        defer { lock.unlock() }

        if inputStateCleanupPending {
            guard releaseActiveInputState() else {
                throw HostInputError.inputStateCleanupPending
            }
            inputStateCleanupPending = false
        }

        do {
            try record.validate(limits: limits)
        } catch {
            throw HostInputError.invalidEvent
        }
        if let lastSequence, record.sequence <= lastSequence {
            throw HostInputError.replayedEvent
        }
        let context = contextProvider.currentContext()
        if let activeInputTarget,
           activeInputTarget != context.selectedWindow.map(HostInputTarget.init(selection:)) {
            // Never combine pressed state from one selected window with an
            // event for another. The lifecycle poll will reset the old state;
            // until then, fail closed instead of admitting a mixed target.
            throw HostInputError.windowGenerationMismatch
        }
        let command = try HostInputMapper.command(for: record, in: context, limits: limits)
        let stateKey = Self.stateKey(for: record)
        let isStateEnding = Self.isStateEnding(record)
        if isStateEnding {
            guard let stateKey, activeInputState.contains(stateKey) else {
                throw HostInputError.unmatchedStateRelease
            }
        }

        do {
            try rateLimiter.admit(
                timestampNanoseconds: record.timestampNanoseconds,
                priority: isStateEnding ? .stateEnding : .regular
            )
        } catch InputCoreError.rateLimited {
            throw HostInputError.rateLimited
        } catch {
            throw HostInputError.invalidEvent
        }

        // Consume the sequence before the adapter call. A rejected platform
        // operation cannot be replayed after a permission or focus transition.
        lastSequence = record.sequence
        try injectionAdapter.inject(command)
        if case let .pointerMove(_, location) = command {
            for stateKey in activeInputState.activeKeys {
                guard case let .pointerButton(button) = stateKey else { continue }
                activePointerLocations[button] = location
            }
        }
        if let stateKey {
            if Self.isStateBeginning(record) {
                if activeInputState.apply(.began(stateKey)) {
                    rateLimiter.reserveStateEndingEvent()
                    if case let .pointerMove(target, _) = command {
                        activeInputTarget = target
                    } else if case let .pointerButton(target, _, _, _) = command {
                        activeInputTarget = target
                    } else if case let .key(target, _, _, _) = command {
                        activeInputTarget = target
                    }
                }
                if case let .pointerButton(_, location, _, true) = command {
                    if case let .pointerButton(button) = stateKey {
                        activePointerLocations[button] = location
                    }
                }
            } else if Self.isStateEnding(record) {
                _ = activeInputState.apply(.ended(stateKey))
                if case let .pointerButton(button) = stateKey {
                    activePointerLocations.removeValue(forKey: button)
                }
                if activeInputState.isEmpty {
                    activeInputTarget = nil
                }
            }
        }
        return HostInputInjectionReceipt(
            sequence: record.sequence,
            windowGeneration: record.windowGeneration,
            kind: record.kind
        )
    }

    public func resetInputState() {
        lock.lock()
        defer { lock.unlock() }
        let released = releaseActiveInputState()
        lastSequence = nil
        rateLimiter.reset()
        inputStateCleanupPending = !released && !activeInputState.isEmpty
        if released {
            clearInputStateTracking()
        }
    }

    /// Retries cleanup after a focus or permission transition. The runtime
    /// calls this when the Host becomes eligible again; normal input remains
    /// blocked while cleanup is pending.
    public func reconcileInputState() {
        lock.lock()
        defer { lock.unlock() }
        guard inputStateCleanupPending else { return }
        guard !activeInputState.isEmpty else {
            inputStateCleanupPending = false
            clearInputStateTracking()
            return
        }
        if releaseActiveInputState() {
            inputStateCleanupPending = false
            clearInputStateTracking()
        }
    }

    private func releaseActiveInputState() -> Bool {
        guard !activeInputState.isEmpty else { return true }
        guard let target = activeInputTarget else {
            return false
        }

        var context = contextProvider.currentContext()
        if !context.selectedTargetMatches(target) {
            guard let releaseContext = contextProvider.currentReleaseContext(for: target) else {
                return false
            }
            context = releaseContext
        }

        guard context.permission == .authorized,
              context.selectedTargetMatches(target),
              let currentBounds = context.currentWindowBounds,
              currentBounds.isValid,
              context.focus == .eligible || context.focus == .notForeground ||
                (context.focus == .backgroundEligible && context.processTargetingAuthorized) else {
            return false
        }
        if context.focus == .eligible || context.focus == .backgroundEligible,
           (context.currentWindowIdentifier != target.windowIdentifier ||
            context.currentProcessIdentifier != target.processIdentifier ||
            context.currentApplicationIdentifier != target.applicationIdentifier) {
            return false
        }

        let buttons = activeInputState.activeKeys.compactMap { key -> UInt8? in
            guard case let .pointerButton(button) = key else { return nil }
            return button
        }.sorted()
        for button in buttons {
            let location = Self.cleanupLocation(
                activePointerLocations[button],
                in: currentBounds
            )
            do {
                try injectionAdapter.release(
                    .pointerButton(
                        target: target,
                        location: location,
                        button: button,
                        pressed: false
                    )
                )
                _ = activeInputState.apply(.ended(.pointerButton(button)))
                activePointerLocations.removeValue(forKey: button)
            } catch {
                continue
            }
        }

        let keys = activeInputState.activeKeys.compactMap { key -> UInt16? in
            guard case let .key(keyCode) = key else { return nil }
            return keyCode
        }.sorted()
        for keyCode in keys {
            do {
                try injectionAdapter.release(
                    .key(
                        target: target,
                        keyCode: keyCode,
                        modifiers: 0,
                        pressed: false
                    )
                )
                _ = activeInputState.apply(.ended(.key(keyCode)))
            } catch {
                continue
            }
        }
        if activeInputState.isEmpty {
            activeInputTarget = nil
        }
        return activeInputState.isEmpty
    }

    private func clearInputStateTracking() {
        activeInputState.reset()
        activePointerLocations.removeAll(keepingCapacity: false)
        activeInputTarget = nil
    }

    private static func cleanupLocation(
        _ location: InputScreenPoint?,
        in bounds: InputWindowBounds
    ) -> InputScreenPoint {
        let fallbackX = bounds.originX + bounds.width / 2
        let fallbackY = bounds.originY + bounds.height / 2
        let x: Double
        if let location, location.x.isFinite {
            x = location.x
        } else {
            x = fallbackX
        }
        let y: Double
        if let location, location.y.isFinite {
            y = location.y
        } else {
            y = fallbackY
        }
        return InputScreenPoint(
            x: min(max(x, bounds.originX), (bounds.originX + bounds.width).nextDown),
            y: min(max(y, bounds.originY), (bounds.originY + bounds.height).nextDown)
        )
    }

    private static func stateKey(for record: InputEventRecord) -> InputStateKey? {
        switch record.kind {
        case .pointerButton:
            return record.button.map(InputStateKey.pointerButton)
        case .keyDown, .keyUp:
            return record.keyCode.map(InputStateKey.key)
        default:
            return nil
        }
    }

    private static func isStateBeginning(_ record: InputEventRecord) -> Bool {
        switch record.kind {
        case .pointerButton:
            return record.pressed == true
        case .keyDown:
            return true
        default:
            return false
        }
    }

    private static func isStateEnding(_ record: InputEventRecord) -> Bool {
        switch record.kind {
        case .pointerButton:
            return record.pressed == false
        case .keyUp:
            return true
        default:
            return false
        }
    }
}

private extension HostInputContext {
    func selectedTargetMatches(_ target: HostInputTarget) -> Bool {
        guard let selectedWindow else { return false }
        return selectedWindow.windowIdentifier == target.windowIdentifier &&
            selectedWindow.processIdentifier == target.processIdentifier &&
            selectedWindow.applicationIdentifier == target.applicationIdentifier &&
            selectedWindow.generation == target.windowGeneration
    }
}
