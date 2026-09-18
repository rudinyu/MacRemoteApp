import InputCore
import XCTest

final class InputCoreTests: XCTestCase {
    func testM0FoundationMarker() {
        XCTAssertEqual(InputCoreModule.name, "InputCore")
    }

    func testPointerCoordinatesNormalizeToContentRectAndPreserveOrder() throws {
        var normalizer = InputEventNormalizer(
            contentRect: InputContentRect(originX: 10, originY: 20, width: 200, height: 100),
            readiness: .ready(windowGeneration: 7)
        )

        let first = try normalizer.pointerMove(
            at: InputPoint(x: 10, y: 20),
            timestampNanoseconds: 100
        )
        let second = try normalizer.pointerMove(
            at: InputPoint(x: 210, y: 120),
            timestampNanoseconds: 101
        )

        XCTAssertEqual(first.sequence, 0)
        XCTAssertEqual(first.windowGeneration, 7)
        XCTAssertEqual(first.x, 0)
        XCTAssertEqual(first.y, 0)
        XCTAssertEqual(second.sequence, 1)
        XCTAssertEqual(second.x, UInt16.max)
        XCTAssertEqual(second.y, UInt16.max)
    }

    func testPointerOutsideContentAndUnavailableStateAreRejected() {
        var normalizer = InputEventNormalizer(
            contentRect: InputContentRect(originX: 0, originY: 0, width: 100, height: 100),
            readiness: .ready(windowGeneration: 1)
        )
        XCTAssertThrowsError(
            try normalizer.pointerMove(
                at: InputPoint(x: 101, y: 50),
                timestampNanoseconds: 1
            )
        ) { error in
            XCTAssertEqual(error as? InputCoreError, .outsideContentSurface)
        }

        normalizer.update(
            contentRect: InputContentRect(originX: 0, originY: 0, width: 100, height: 100),
            readiness: .awaitingAuthorization
        )
        XCTAssertThrowsError(
            try normalizer.focusIntent(timestampNanoseconds: 2)
        ) { error in
            XCTAssertEqual(
                error as? InputCoreError,
                .inputNotReady(.awaitingAuthorization)
            )
        }
    }

    func testAdmittedButtonReleaseUsesLastValidCoordinateOutsideContent() throws {
        var normalizer = InputEventNormalizer(
            contentRect: InputContentRect(originX: 10, originY: 20, width: 200, height: 100),
            readiness: .ready(windowGeneration: 3)
        )

        let down = try normalizer.pointerButton(
            at: InputPoint(x: 110, y: 70),
            button: 0,
            pressed: true,
            timestampNanoseconds: 1
        )
        let up = try normalizer.pointerButton(
            at: InputPoint(x: 999, y: 999),
            button: 0,
            pressed: false,
            timestampNanoseconds: 2
        )

        XCTAssertEqual(up.kind, .pointerButton)
        XCTAssertEqual(up.pressed, false)
        XCTAssertEqual(up.x, down.x)
        XCTAssertEqual(up.y, down.y)

        XCTAssertThrowsError(
            try normalizer.pointerButton(
                at: InputPoint(x: 999, y: 999),
                button: 1,
                pressed: true,
                timestampNanoseconds: 3
            )
        ) { error in
            XCTAssertEqual(error as? InputCoreError, .outsideContentSurface)
        }
    }

    func testKeyboardModifiersAndScrollAreTypedAndBounded() throws {
        var normalizer = InputEventNormalizer(
            contentRect: InputContentRect(originX: 0, originY: 0, width: 100, height: 100),
            readiness: .ready(windowGeneration: 2)
        )
        let key = try normalizer.key(
            keyCode: 42,
            modifiers: 0x03,
            pressed: true,
            timestampNanoseconds: 3
        )
        XCTAssertEqual(key.kind, .keyDown)
        XCTAssertEqual(key.keyCode, 42)
        XCTAssertEqual(key.modifiers, 0x03)

        let scroll = try normalizer.scroll(
            at: InputPoint(x: 50, y: 50),
            deltaX: -2.5,
            deltaY: 4.4,
            timestampNanoseconds: 4
        )
        XCTAssertEqual(scroll.kind, .scroll)
        XCTAssertEqual(scroll.deltaX, -3)
        XCTAssertEqual(scroll.deltaY, 4)

        XCTAssertThrowsError(
            try normalizer.scroll(
                at: InputPoint(x: 50, y: 50),
                deltaX: 0,
                deltaY: 10_001,
                timestampNanoseconds: 5
            )
        )

        var wideNormalizer = InputEventNormalizer(
            contentRect: InputContentRect(originX: 0, originY: 0, width: 100, height: 100),
            readiness: .ready(windowGeneration: 1),
            limits: InputEventLimits(maxScrollDelta: Double(Int32.max) + 1)
        )
        XCTAssertThrowsError(
            try wideNormalizer.scroll(
                at: InputPoint(x: 10, y: 10),
                deltaX: Double(Int32.max) + 0.75,
                deltaY: 0,
                timestampNanoseconds: 6
            )
        ) { error in
            XCTAssertEqual(error as? InputCoreError, .invalidEvent)
        }
    }

    func testFocusIntentIsTypedForTheCurrentWindowGeneration() throws {
        var normalizer = InputEventNormalizer(
            contentRect: InputContentRect(originX: 0, originY: 0, width: 100, height: 100),
            readiness: .ready(windowGeneration: 8)
        )

        let focus = try normalizer.focusIntent(timestampNanoseconds: 7)

        XCTAssertEqual(focus.kind, .focusIntent)
        XCTAssertEqual(focus.windowGeneration, 8)
        XCTAssertNil(focus.keyCode)
        XCTAssertNil(focus.button)
    }

    func testRateLimiterRejectsBurstAndOutOfOrderTimestamps() throws {
        var limiter = InputEventRateLimiter(
            limits: InputEventLimits(maxEventsPerSecond: 2)
        )
        try limiter.admit(timestampNanoseconds: 1_000)
        try limiter.admit(timestampNanoseconds: 2_000)
        XCTAssertThrowsError(try limiter.admit(timestampNanoseconds: 3_000)) { error in
            XCTAssertEqual(error as? InputCoreError, .rateLimited)
        }
        limiter.reset()
        try limiter.admit(timestampNanoseconds: 10_000)
        XCTAssertThrowsError(try limiter.admit(timestampNanoseconds: 9_999)) { error in
            XCTAssertEqual(error as? InputCoreError, .invalidEvent)
        }

    }

    func testRateLimiterAdmitsStateEndingEventAfterMovementBudgetIsFull() throws {
        var limiter = InputEventRateLimiter(
            limits: InputEventLimits(maxEventsPerSecond: 2)
        )
        limiter.reserveStateEndingEvent()
        try limiter.admit(timestampNanoseconds: 1_000)
        try limiter.admit(timestampNanoseconds: 2_000)

        XCTAssertThrowsError(try limiter.admit(timestampNanoseconds: 3_000)) { error in
            XCTAssertEqual(error as? InputCoreError, .rateLimited)
        }
        XCTAssertNoThrow(
            try limiter.admit(
                timestampNanoseconds: 3_000,
                priority: .stateEnding
            )
        )
    }

    func testPressedStateRemainsActiveUntilMatchingReleaseIsApplied() {
        var tracker = InputStateTracker()
        let button = InputStateKey.pointerButton(0)
        let key = InputStateKey.key(42)

        XCTAssertTrue(tracker.apply(.began(button)))
        XCTAssertTrue(tracker.apply(.began(key)))
        XCTAssertEqual(tracker.activeKeys, [button, key])
        XCTAssertFalse(tracker.apply(.began(button)))

        XCTAssertTrue(tracker.apply(.ended(button)))
        XCTAssertEqual(tracker.activeKeys, [key])
        XCTAssertTrue(tracker.apply(.ended(key)))
        XCTAssertTrue(tracker.isEmpty)
    }

    func testModifierTrackerIgnoresUnmatchedReleaseAndResynchronizesAfterReset() {
        var tracker = ModifierKeyTracker()

        XCTAssertFalse(tracker.reconcile(keyCode: 55, isPressed: false))
        XCTAssertTrue(tracker.pressedKeyCodes.isEmpty)
        XCTAssertTrue(tracker.reconcile(keyCode: 55, isPressed: true))
        XCTAssertFalse(tracker.reconcile(keyCode: 55, isPressed: true))

        tracker.reset()
        XCTAssertFalse(tracker.reconcile(keyCode: 55, isPressed: false))
        XCTAssertTrue(tracker.reconcile(keyCode: 55, isPressed: true))
    }

    func testModifierTrackerTogglesLeftAndRightKeysIndependently() {
        var tracker = ModifierKeyTracker()
        let leftShift: UInt16 = 56
        let rightShift: UInt16 = 60

        XCTAssertEqual(tracker.toggle(keyCode: leftShift), .pressed)
        XCTAssertEqual(tracker.toggle(keyCode: rightShift), .pressed)
        XCTAssertEqual(tracker.pressedKeyCodes, [leftShift, rightShift])

        // AppKit still reports the aggregate Shift flag here, but the
        // keyCode transition releases only the left physical key.
        XCTAssertEqual(tracker.toggle(keyCode: leftShift), .released)
        XCTAssertEqual(tracker.pressedKeyCodes, [rightShift])
        XCTAssertEqual(tracker.toggle(keyCode: rightShift), .released)
        XCTAssertTrue(tracker.pressedKeyCodes.isEmpty)
    }

    func testModifierTrackerConsumesHeldModifierTransitionsDuringFocusResync() {
        var tracker = ModifierKeyTracker()
        XCTAssertEqual(tracker.toggle(keyCode: 56), .pressed)
        XCTAssertEqual(tracker.toggle(keyCode: 60), .pressed)

        tracker.beginResynchronization()
        XCTAssertTrue(tracker.isResynchronizing)

        // A left-side release while right Shift remains held cannot be
        // classified from the aggregate mask. Consume it while resyncing.
        XCTAssertFalse(tracker.observeAggregateState(isPressed: true))
        XCTAssertNil(tracker.toggle(keyCode: 56))

        // Once the aggregate mask is clear, consume that release too. The
        // next physical press is then admitted as a fresh per-key transition.
        XCTAssertFalse(tracker.observeAggregateState(isPressed: false))
        XCTAssertFalse(tracker.isResynchronizing)
        XCTAssertEqual(tracker.toggle(keyCode: 56), .pressed)
    }
}
