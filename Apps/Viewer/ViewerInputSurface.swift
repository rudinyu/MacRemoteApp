import AppKit
import InputCore

struct ViewerInputCapabilities: Equatable {
    let mouseInputEnabled: Bool
    let keyboardInputEnabled: Bool

    static let none = ViewerInputCapabilities(
        mouseInputEnabled: false,
        keyboardInputEnabled: false
    )

    var anyInputEnabled: Bool {
        mouseInputEnabled || keyboardInputEnabled
    }
}

/// A remote-content-only event surface. It emits typed records and never
/// injects or archives platform events.
@MainActor
final class ViewerInputSurface: NSView {
    // AppKit's default NSView coordinate system starts at the lower-left,
    // while the Host's CGWindow/CGEvent screen coordinates start at the
    // upper-left. Keep the Viewer surface in the same top-left convention as
    // the normalized wire coordinates so Host mapping does not mirror Y.
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    private var trackingArea: NSTrackingArea?
    private var windowFocusObserver: NSObjectProtocol?
    private var windowBecomeKeyObserver: NSObjectProtocol?
    private var normalizer: InputEventNormalizer
    private var rateLimiter: InputEventRateLimiter
    private var inputState = InputStateTracker()
    private var modifierKeyTracker = ModifierKeyTracker()
    private var admittedModifierKeyCodes: Set<UInt16> = []
    private(set) var inputCapabilities: ViewerInputCapabilities

    private(set) var inputReadiness: InputReadiness {
        didSet {
            toolTip = inputReadiness.label
            setAccessibilityValue(inputReadiness.label)
            needsDisplay = true
        }
    }

    var onInputEvent: (@MainActor (InputEventRecord) -> Void)?
    var onInputRejected: (@MainActor (InputCoreError) -> Void)?

    var inputReady: Bool {
        inputReadiness.isReady &&
            inputCapabilities.anyInputEnabled &&
            normalizer.contentRect.isValid
    }

    init(
        frame frameRect: NSRect,
        contentRect: InputContentRect,
        readiness: InputReadiness = .surfaceUnavailable,
        capabilities: ViewerInputCapabilities = .none,
        limits: InputEventLimits = .default
    ) {
        self.normalizer = InputEventNormalizer(
            contentRect: contentRect,
            readiness: readiness,
            limits: limits
        )
        self.rateLimiter = InputEventRateLimiter(limits: limits)
        self.inputReadiness = readiness
        self.inputCapabilities = capabilities
        super.init(frame: frameRect)
        configureSurface()
    }

    required init?(coder: NSCoder) {
        let readiness: InputReadiness = .surfaceUnavailable
        self.normalizer = InputEventNormalizer(
            contentRect: InputContentRect(originX: 0, originY: 0, width: 0, height: 0),
            readiness: readiness
        )
        self.rateLimiter = InputEventRateLimiter()
        self.inputReadiness = readiness
        self.inputCapabilities = .none
        super.init(coder: coder)
        configureSurface()
    }

    func updateInputState(
        contentRect: InputContentRect,
        readiness: InputReadiness,
        capabilities: ViewerInputCapabilities = .none
    ) {
        let readinessChanged = inputReadiness != readiness
        let capabilitiesChanged = inputCapabilities != capabilities
        let wasReady = inputReady
        let willBeReady = readiness.isReady && capabilities.anyInputEnabled && contentRect.isValid
        if !inputState.isEmpty && (readinessChanged || capabilitiesChanged || wasReady != willBeReady) {
            // Keep the old readiness and normalizer generation in place while
            // synthetic releases are admitted. Clearing state first would
            // leave the Host believing a key or button is still pressed.
            releasePressedState()
        } else if readinessChanged || capabilitiesChanged || wasReady != willBeReady {
            beginModifierResynchronization()
            admittedModifierKeyCodes.removeAll(keepingCapacity: false)
            rateLimiter.reset()
        }
        normalizer.update(contentRect: contentRect, readiness: readiness)
        inputReadiness = readiness
        inputCapabilities = capabilities
        rateLimiter.reset()
        if !readinessChanged && wasReady == willBeReady {
            for _ in inputState.activeKeys {
                rateLimiter.reserveStateEndingEvent()
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let windowFocusObserver {
            NotificationCenter.default.removeObserver(windowFocusObserver)
            self.windowFocusObserver = nil
        }
        if let windowBecomeKeyObserver {
            NotificationCenter.default.removeObserver(windowBecomeKeyObserver)
            self.windowBecomeKeyObserver = nil
        }
        releasePressedState()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        windowFocusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.releasePressedState()
            }
        }
        windowBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.beginModifierResynchronization()
            }
        }
        if window.isKeyWindow {
            beginModifierResynchronization()
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            releasePressedState()
        }
        return resigned
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            beginModifierResynchronization()
        }
        return became
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        let borderColor = inputReady ? NSColor.systemGreen : NSColor.systemOrange
        borderColor.setStroke()
        let border = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(rect: border)
        path.lineWidth = 2
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if !inputCapabilities.mouseInputEnabled {
            // A keyboard-only session still needs a way to return focus to the
            // remote surface after a picker or clipboard control was used.
            // Consume the local click without admitting a mouse event.
            guard inputCapabilities.keyboardInputEnabled else { return }
            _ = window?.makeFirstResponder(self)
            return
        }
        emitButtonDown(event, button: 0)
    }

    override func mouseUp(with event: NSEvent) {
        guard inputCapabilities.mouseInputEnabled else { return }
        emit(
            priority: priority(for: .pointerButton(0), pressed: false),
            stateTransition: .ended(.pointerButton(0))
        ) {
            try normalizer.pointerButton(
                at: point(for: event),
                button: 0,
                pressed: false,
                timestampNanoseconds: now()
            )
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        emitButtonDown(event, button: 1)
    }

    override func rightMouseUp(with event: NSEvent) {
        emitButton(event, button: 1, pressed: false)
    }

    override func otherMouseDown(with event: NSEvent) {
        emitButtonDown(event, button: UInt8(clamping: event.buttonNumber))
    }

    override func otherMouseUp(with event: NSEvent) {
        emitButton(event, button: UInt8(clamping: event.buttonNumber), pressed: false)
    }

    override func mouseMoved(with event: NSEvent) {
        guard inputCapabilities.mouseInputEnabled else { return }
        emit(throttleMovementWhenRateLimited: true) {
            try normalizer.pointerMove(at: point(for: event), timestampNanoseconds: now())
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard inputCapabilities.mouseInputEnabled else { return }
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard inputCapabilities.mouseInputEnabled else { return }
        mouseMoved(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard inputCapabilities.mouseInputEnabled else { return }
        mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard inputCapabilities.mouseInputEnabled else { return }
        emit {
            try normalizer.scroll(
                at: point(for: event),
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                timestampNanoseconds: now()
            )
        }
    }

    override func keyDown(with event: NSEvent) {
        guard inputCapabilities.keyboardInputEnabled else { return }
        emitKey(event, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        guard inputCapabilities.keyboardInputEnabled else { return }
        emitKey(event, pressed: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard inputReady, inputCapabilities.keyboardInputEnabled else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifierFlag(for: event.keyCode) != nil else { return }

        if modifierKeyTracker.isResynchronizing {
            let aggregateIsPressed = !flags.intersection(Self.resynchronizationModifierFlags).isEmpty
            _ = modifierKeyTracker.observeAggregateState(isPressed: aggregateIsPressed)
            return
        }

        guard let transition = modifierKeyTracker.toggle(keyCode: event.keyCode) else { return }
        let isPressed: Bool
        switch transition {
        case .pressed:
            isPressed = true
        case .released:
            isPressed = false
        }

        if !isPressed && !admittedModifierKeyCodes.contains(event.keyCode) {
            return
        }
        let didEmit = emitKey(
            event,
            pressed: isPressed,
            priority: isPressed ? .regular : .stateEnding,
            modifierFlags: flags
        )
        guard didEmit else { return }
        if isPressed {
            admittedModifierKeyCodes.insert(event.keyCode)
        } else {
            admittedModifierKeyCodes.remove(event.keyCode)
        }
    }

    private func configureSurface() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        toolTip = inputReadiness.label
        setAccessibilityLabel("Remote content")
        setAccessibilityValue(inputReadiness.label)
    }

    private func emitButtonDown(_ event: NSEvent, button: UInt8) {
        guard inputReady,
              inputCapabilities.mouseInputEnabled,
              let window,
              window.makeFirstResponder(self) else { return }
        emit { try normalizer.focusIntent(timestampNanoseconds: now()) }
        emitButton(event, button: button, pressed: true)
    }

    private func emitButton(_ event: NSEvent, button: UInt8, pressed: Bool) {
        guard inputCapabilities.mouseInputEnabled else { return }
        emit(
            priority: priority(
                for: .pointerButton(button),
                pressed: pressed
            ),
            stateTransition: pressed
                ? .began(.pointerButton(button))
                : .ended(.pointerButton(button))
        ) {
            try normalizer.pointerButton(
                at: point(for: event),
                button: button,
                pressed: pressed,
                timestampNanoseconds: now()
            )
        }
    }

    @discardableResult
    private func emitKey(
        _ event: NSEvent,
        pressed: Bool,
        priority: InputEventPriority? = nil,
        modifierFlags: NSEvent.ModifierFlags? = nil
    ) -> Bool {
        guard inputCapabilities.keyboardInputEnabled else { return false }
        let flags = modifierFlags ?? event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let eventPriority = priority ?? self.priority(
            for: .key(event.keyCode),
            pressed: pressed
        )
        return emit(
            priority: eventPriority,
            stateTransition: pressed
                ? .began(.key(event.keyCode))
                : .ended(.key(event.keyCode))
        ) {
            try normalizer.key(
                keyCode: event.keyCode,
                modifiers: UInt32(truncatingIfNeeded: flags.rawValue),
                pressed: pressed,
                timestampNanoseconds: now()
            )
        }
    }

    @discardableResult
    private func emit(
        priority: InputEventPriority = .regular,
        stateTransition: InputStateTransition? = nil,
        throttleMovementWhenRateLimited: Bool = false,
        _ make: () throws -> InputEventRecord
    ) -> Bool {
        guard inputReady else { return false }
        do {
            let timestamp = now()
            try rateLimiter.admit(timestampNanoseconds: timestamp, priority: priority)
            let record = try make()
            if let stateTransition {
                updateStateReservation(for: stateTransition)
            }
            onInputEvent?(record)
            return true
        } catch let error as InputCoreError {
            if throttleMovementWhenRateLimited, error == .rateLimited {
                return false
            }
            onInputRejected?(error)
            return false
        } catch {
            onInputRejected?(.invalidEvent)
            return false
        }
    }

    private func point(for event: NSEvent) -> InputPoint {
        let point = convert(event.locationInWindow, from: nil)
        return InputPoint(x: point.x, y: point.y)
    }

    private func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private func releasePressedState() {
        let activeKeys = inputState.activeKeys
        let buttons = activeKeys.compactMap { stateKey -> UInt8? in
            guard case let .pointerButton(button) = stateKey else { return nil }
            return button
        }.sorted()
        let keyCodes = activeKeys.compactMap { stateKey -> UInt16? in
            guard case let .key(keyCode) = stateKey else { return nil }
            return keyCode
        }.sorted()

        for button in buttons {
            _ = emit(
                priority: .stateEnding,
                stateTransition: .ended(.pointerButton(button))
            ) {
                try normalizer.pointerButton(
                    at: InputPoint(x: 0, y: 0),
                    button: button,
                    pressed: false,
                    timestampNanoseconds: now()
                )
            }
        }

        let regularKeys = keyCodes.filter { modifierFlag(for: $0) == nil }
        let modifierKeys = keyCodes.filter { modifierFlag(for: $0) != nil }
        for keyCode in regularKeys + modifierKeys {
            _ = emit(
                priority: .stateEnding,
                stateTransition: .ended(.key(keyCode))
            ) {
                try normalizer.key(
                    keyCode: keyCode,
                    modifiers: 0,
                    pressed: false,
                    timestampNanoseconds: now()
                )
            }
        }

        inputState.reset()
        beginModifierResynchronization()
        admittedModifierKeyCodes.removeAll(keepingCapacity: false)
        rateLimiter.reset()
    }

    private func beginModifierResynchronization() {
        modifierKeyTracker.beginResynchronization()
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.intersection(Self.resynchronizationModifierFlags).isEmpty {
            _ = modifierKeyTracker.observeAggregateState(isPressed: false)
        }
    }

    private func updateStateReservation(for transition: InputStateTransition) {
        switch transition {
        case let .began(stateKey):
            guard inputState.apply(.began(stateKey)) else { return }
            rateLimiter.reserveStateEndingEvent()
        case let .ended(stateKey):
            _ = inputState.apply(.ended(stateKey))
        }
    }

    private func priority(
        for stateKey: InputStateKey,
        pressed: Bool
    ) -> InputEventPriority {
        guard !pressed, inputState.contains(stateKey) else {
            return .regular
        }
        return .stateEnding
    }

    private func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55:
            return .command
        case 58, 61:
            return .option
        case 59, 62:
            return .control
        case 56, 60:
            return .shift
        default:
            return nil
        }
    }

    private static let resynchronizationModifierFlags: NSEvent.ModifierFlags = [
        .command,
        .option,
        .control,
        .shift
    ]
}
