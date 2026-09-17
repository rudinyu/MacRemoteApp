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
}
