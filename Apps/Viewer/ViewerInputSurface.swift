import AppKit
import InputCore

/// A remote-content-only event surface. It emits typed records and never
/// injects or archives platform events.
@MainActor
final class ViewerInputSurface: NSView {
    private var trackingArea: NSTrackingArea?
    private var normalizer: InputEventNormalizer
    private var rateLimiter: InputEventRateLimiter

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
        inputReadiness.isReady && normalizer.contentRect.isValid
    }

    init(
        frame frameRect: NSRect,
        contentRect: InputContentRect,
        readiness: InputReadiness = .surfaceUnavailable,
        limits: InputEventLimits = .default
    ) {
        self.normalizer = InputEventNormalizer(
            contentRect: contentRect,
            readiness: readiness,
            limits: limits
        )
        self.rateLimiter = InputEventRateLimiter(limits: limits)
        self.inputReadiness = readiness
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
        super.init(coder: coder)
        configureSurface()
    }

    func updateInputState(
        contentRect: InputContentRect,
        readiness: InputReadiness
    ) {
        normalizer.update(contentRect: contentRect, readiness: readiness)
        inputReadiness = readiness
        rateLimiter.reset()
    }

    override var acceptsFirstResponder: Bool { true }

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
        NSColor.black.setFill()
        dirtyRect.fill()
        let borderColor = inputReady ? NSColor.systemGreen : NSColor.systemOrange
        borderColor.setStroke()
        let border = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(rect: border)
        path.lineWidth = 2
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard inputReady else { return }
        window?.makeFirstResponder(self)
        emit { try normalizer.focusIntent(timestampNanoseconds: now()) }
        emit {
            try normalizer.pointerButton(
                at: point(for: event),
                button: 0,
                pressed: true,
                timestampNanoseconds: now()
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        emit {
            try normalizer.pointerButton(
                at: point(for: event),
                button: 0,
                pressed: false,
                timestampNanoseconds: now()
            )
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        emitButton(event, button: 1, pressed: true)
    }

    override func rightMouseUp(with event: NSEvent) {
        emitButton(event, button: 1, pressed: false)
    }

    override func otherMouseDown(with event: NSEvent) {
        emitButton(event, button: UInt8(clamping: event.buttonNumber), pressed: true)
    }

    override func otherMouseUp(with event: NSEvent) {
        emitButton(event, button: UInt8(clamping: event.buttonNumber), pressed: false)
    }

    override func mouseMoved(with event: NSEvent) {
        emit {
            try normalizer.pointerMove(at: point(for: event), timestampNanoseconds: now())
        }
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
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
        emitKey(event, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        emitKey(event, pressed: false)
    }

    private func configureSurface() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        toolTip = inputReadiness.label
        setAccessibilityLabel("Remote content")
        setAccessibilityValue(inputReadiness.label)
    }

    private func emitButton(_ event: NSEvent, button: UInt8, pressed: Bool) {
        emit {
            try normalizer.pointerButton(
                at: point(for: event),
                button: button,
                pressed: pressed,
                timestampNanoseconds: now()
            )
        }
    }

    private func emitKey(_ event: NSEvent, pressed: Bool) {
        emit {
            try normalizer.key(
                keyCode: event.keyCode,
                modifiers: UInt32(truncatingIfNeeded: event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue),
                pressed: pressed,
                timestampNanoseconds: now()
            )
        }
    }

    private func emit(_ make: () throws -> InputEventRecord) {
        guard inputReady else { return }
        do {
            let timestamp = now()
            try rateLimiter.admit(timestampNanoseconds: timestamp)
            let record = try make()
            onInputEvent?(record)
        } catch let error as InputCoreError {
            onInputRejected?(error)
        } catch {
            onInputRejected?(.invalidEvent)
        }
    }

    private func point(for event: NSEvent) -> InputPoint {
        let point = convert(event.locationInWindow, from: nil)
        return InputPoint(x: point.x, y: point.y)
    }

    private func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
