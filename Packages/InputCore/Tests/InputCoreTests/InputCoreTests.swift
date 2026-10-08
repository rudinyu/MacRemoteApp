@testable import InputCore
import XCTest

final class InputCoreTests: XCTestCase {
    func testM0FoundationMarker() {
        XCTAssertEqual(InputCoreModule.name, "InputCore")
    }

    func testBackgroundControlRequiresKnownInactiveGlobalAndTargetSecureInput() {
        XCTAssertEqual(
            CoreGraphicsAccessibilityContextProvider.classifyBackgroundSecureInput(
                global: .unknown,
                target: .inactive
            ),
            .unknown
        )
        XCTAssertEqual(
            CoreGraphicsAccessibilityContextProvider.classifyBackgroundSecureInput(
                global: .active,
                target: .inactive
            ),
            .secureInput
        )
        XCTAssertEqual(
            CoreGraphicsAccessibilityContextProvider.classifyBackgroundSecureInput(
                global: .inactive,
                target: .active
            ),
            .secureInput
        )
        XCTAssertEqual(
            CoreGraphicsAccessibilityContextProvider.classifyBackgroundSecureInput(
                global: .inactive,
                target: .unknown
            ),
            .unknown
        )
        XCTAssertEqual(
            CoreGraphicsAccessibilityContextProvider.classifyBackgroundSecureInput(
                global: .inactive,
                target: .inactive
            ),
            .backgroundEligible
        )
    }

    func testTargetSecureInputInspectionFailsClosedOnMissingOrMismatchedAXOwnership() {
        XCTAssertEqual(
            CoreGraphicsAccessibilityContextProvider.classifyTargetSecureInputState(
                expectedProcessIdentifier: 42,
                focusedElementProcessIdentifier: 41,
                role: "AXTextField",
                subrole: nil
            ),
            .unknown
        )
        XCTAssertEqual(
            CoreGraphicsAccessibilityContextProvider.classifyTargetSecureInputState(
                expectedProcessIdentifier: 42,
                focusedElementProcessIdentifier: nil,
                role: "AXTextField",
                subrole: nil
            ),
            .unknown
        )
        XCTAssertEqual(
            CoreGraphicsAccessibilityContextProvider.classifyTargetSecureInputState(
                expectedProcessIdentifier: 42,
                focusedElementProcessIdentifier: 42,
                role: "AXTextField",
                subrole: nil
            ),
            .inactive
        )
        XCTAssertEqual(
            CoreGraphicsAccessibilityContextProvider.classifyTargetSecureInputState(
                expectedProcessIdentifier: 42,
                focusedElementProcessIdentifier: 42,
                role: "AXTextField",
                subrole: nil,
                subroleInspectionFailed: true
            ),
            .unknown
        )
        XCTAssertEqual(
            CoreGraphicsAccessibilityContextProvider.classifyTargetSecureInputState(
                expectedProcessIdentifier: 42,
                focusedElementProcessIdentifier: 42,
                role: "AXSecureTextField",
                subrole: nil
            ),
            .active
        )
        XCTAssertEqual(
            CoreGraphicsAccessibilityContextProvider.classifyTargetSecureInputState(
                expectedProcessIdentifier: 42,
                focusedElementProcessIdentifier: 42,
                role: "AXTextField",
                subrole: "AXSecureTextField"
            ),
            .active
        )
    }

    func testInputSourcePolicyKeepsEnglishNoOpAndMatchesChineseModeExactly() {
        let englishRequested = InputSourceDescriptor(
            identifier: "com.apple.keylayout.US",
            kind: .english
        )
        let anotherEnglish = InputSourceDescriptor(
            identifier: "com.apple.keylayout.Dvorak",
            kind: .english
        )
        XCTAssertEqual(
            InputSourceSelectionPolicy.plan(
                requested: englishRequested,
                current: anotherEnglish,
                enabled: []
            ),
            .alreadyMatches
        )

        let chineseRequested = InputSourceDescriptor(
            identifier: "com.example.ime.zhuyin",
            kind: .chinese
        )
        let differentChineseMode = InputSourceDescriptor(
            identifier: "com.example.ime.pinyin",
            kind: .chinese
        )
        XCTAssertEqual(
            InputSourceSelectionPolicy.plan(
                requested: chineseRequested,
                current: chineseRequested,
                enabled: []
            ),
            .alreadyMatches
        )
        XCTAssertEqual(
            InputSourceSelectionPolicy.plan(
                requested: chineseRequested,
                current: anotherEnglish,
                enabled: [differentChineseMode]
            ),
            .unavailable
        )
        XCTAssertEqual(
            InputSourceSelectionPolicy.plan(
                requested: chineseRequested,
                current: anotherEnglish,
                enabled: [differentChineseMode, chineseRequested]
            ),
            .select(chineseRequested)
        )
    }

    func testInputSourcePolicyPrefersRequestedEnglishThenUsesStableEnabledFallback() {
        let requested = InputSourceDescriptor(
            identifier: "com.apple.keylayout.US",
            kind: .english
        )
        let fallbackZ = InputSourceDescriptor(identifier: "layout.z", kind: .english)
        let fallbackA = InputSourceDescriptor(identifier: "layout.a", kind: .english)
        let currentChinese = InputSourceDescriptor(identifier: "ime.zh", kind: .chinese)

        XCTAssertEqual(
            InputSourceSelectionPolicy.plan(
                requested: requested,
                current: currentChinese,
                enabled: [fallbackZ, requested, fallbackA]
            ),
            .select(requested)
        )
        XCTAssertEqual(
            InputSourceSelectionPolicy.plan(
                requested: requested,
                current: currentChinese,
                enabled: [fallbackZ, fallbackA]
            ),
            .select(fallbackA)
        )
        XCTAssertEqual(
            InputSourceSelectionPolicy.plan(
                requested: requested,
                current: currentChinese,
                enabled: [currentChinese]
            ),
            .unavailable
        )
    }

    func testInputSourcePolicyRejectsInvalidAndMismatchedDescriptors() {
        let invalid = InputSourceDescriptor(identifier: "bad\nidentifier", kind: .chinese)
        let oversized = InputSourceDescriptor(
            identifier: String(repeating: "a", count: 257),
            kind: .chinese
        )
        let englishWithChineseIdentifier = InputSourceDescriptor(
            identifier: "ime.zh",
            kind: .english
        )
        let enabledChinese = InputSourceDescriptor(identifier: "ime.zh", kind: .chinese)

        XCTAssertEqual(
            InputSourceSelectionPolicy.plan(
                requested: invalid,
                current: nil,
                enabled: [enabledChinese]
            ),
            .unavailable
        )
        XCTAssertEqual(
            InputSourceSelectionPolicy.plan(
                requested: oversized,
                current: nil,
                enabled: [enabledChinese]
            ),
            .unavailable
        )
        XCTAssertEqual(
            InputSourceSelectionPolicy.plan(
                requested: englishWithChineseIdentifier,
                current: nil,
                enabled: [enabledChinese]
            ),
            .unavailable
        )
    }

    @MainActor
    func testHostControllerSynchronizesInputSourceOnlyForCurrentEligibleTarget() {
        let chinese = InputSourceDescriptor(identifier: "ime.zhuyin", kind: .chinese)
        let english = InputSourceDescriptor(identifier: "layout.us", kind: .english)
        let deniedContexts = [
            authorizedHostContext(sessionAuthorized: false),
            authorizedHostContext(authorizedWindowGeneration: 8),
            authorizedHostContext(currentWindowIdentifier: 999),
            authorizedHostContext(permission: .missing),
            authorizedHostContext(focus: .lockedScreen),
            authorizedHostContext(focus: .notForeground),
            authorizedHostContext(focus: .secureInput),
            authorizedHostContext(keyboardInputEnabled: false)
        ]

        for context in deniedContexts {
            let contextProvider = FakeHostInputContextProvider(context: context)
            let sourceProvider = FakeInputSourceProvider(
                current: english,
                enabled: [chinese]
            )
            let controller = HostInputController(
                contextProvider: contextProvider,
                injectionAdapter: RecordingHostInputAdapter()
            )

            XCTAssertEqual(
                controller.synchronizeInputSource(
                    descriptor: chinese,
                    windowGeneration: 9,
                    provider: sourceProvider
                ),
                .denied
            )
            XCTAssertTrue(sourceProvider.selections.isEmpty)
        }
    }

    @MainActor
    func testHostControllerRechecksEligibilityAtTheFinalSelectionBoundary() {
        let contextProvider = FakeHostInputContextProvider(context: authorizedHostContext())
        let chinese = InputSourceDescriptor(identifier: "ime.zhuyin", kind: .chinese)
        let english = InputSourceDescriptor(identifier: "layout.us", kind: .english)
        let sourceProvider = FakeInputSourceProvider(current: english, enabled: [chinese])
        sourceProvider.onSelectionValidation = {
            contextProvider.context = self.authorizedHostContext(focus: .secureInput)
        }
        let controller = HostInputController(
            contextProvider: contextProvider,
            injectionAdapter: RecordingHostInputAdapter()
        )

        XCTAssertEqual(
            controller.synchronizeInputSource(
                descriptor: chinese,
                windowGeneration: 9,
                provider: sourceProvider
            ),
            .denied
        )
        XCTAssertTrue(sourceProvider.selections.isEmpty)
    }

    @MainActor
    func testHostControllerRechecksEligibilityBeforeAcknowledgingNoOp() {
        let contextProvider = FakeHostInputContextProvider(context: authorizedHostContext())
        let english = InputSourceDescriptor(identifier: "layout.us", kind: .english)
        let sourceProvider = FakeInputSourceProvider(current: english, enabled: [english])
        sourceProvider.onEnabledSourcesRead = {
            contextProvider.context = self.authorizedHostContext(focus: .lockedScreen)
        }
        let controller = HostInputController(
            contextProvider: contextProvider,
            injectionAdapter: RecordingHostInputAdapter()
        )

        XCTAssertEqual(
            controller.synchronizeInputSource(
                descriptor: InputSourceDescriptor(identifier: "layout.dvorak", kind: .english),
                windowGeneration: 9,
                provider: sourceProvider
            ),
            .denied
        )
        XCTAssertTrue(sourceProvider.selections.isEmpty)
    }

    @MainActor
    func testHostControllerUsesPolicyNoOpAndSelectsExactChineseDescriptor() {
        let contextProvider = FakeHostInputContextProvider(context: authorizedHostContext())
        let english = InputSourceDescriptor(identifier: "layout.us", kind: .english)
        let chinese = InputSourceDescriptor(identifier: "ime.zhuyin", kind: .chinese)
        let sourceProvider = FakeInputSourceProvider(current: english, enabled: [chinese])
        let controller = HostInputController(
            contextProvider: contextProvider,
            injectionAdapter: RecordingHostInputAdapter()
        )

        XCTAssertEqual(
            controller.synchronizeInputSource(
                descriptor: InputSourceDescriptor(identifier: "layout.dvorak", kind: .english),
                windowGeneration: 9,
                provider: sourceProvider
            ),
            .applied
        )
        XCTAssertTrue(sourceProvider.selections.isEmpty)

        XCTAssertEqual(
            controller.synchronizeInputSource(
                descriptor: chinese,
                windowGeneration: 9,
                provider: sourceProvider
            ),
            .applied
        )
        XCTAssertEqual(sourceProvider.selections, [chinese])
    }

    func testAccessibilityWindowMatcherUsesUniqueGeometryWithinPointTolerance() {
        let selected = InputWindowBounds(originX: 40, originY: 70, width: 800, height: 600)
        let candidates = [
            AccessibilityWindowGeometry(
                title: "Document",
                bounds: InputWindowBounds(originX: 41, originY: 69, width: 801, height: 600)
            ),
            AccessibilityWindowGeometry(
                title: "Other",
                bounds: InputWindowBounds(originX: 1000, originY: 70, width: 800, height: 600)
            )
        ]

        XCTAssertEqual(
            AccessibilityWindowMatcher.matchIndex(
                selectedBounds: selected,
                selectedTitle: "Document",
                candidates: candidates
            ),
            0
        )
    }

    func testAccessibilityWindowMatcherRejectsUniqueGeometryWithMismatchedKnownTitle() {
        let selected = InputWindowBounds(originX: 40, originY: 70, width: 800, height: 600)
        let candidates = [
            AccessibilityWindowGeometry(title: "Different document", bounds: selected)
        ]

        XCTAssertNil(
            AccessibilityWindowMatcher.matchIndex(
                selectedBounds: selected,
                selectedTitle: "Document",
                candidates: candidates
            )
        )
    }

    func testAccessibilityWindowMatcherUsesTitleOnlyToResolveGeometryCollision() {
        let selected = InputWindowBounds(originX: 40, originY: 70, width: 800, height: 600)
        let candidates = [
            AccessibilityWindowGeometry(title: "Other", bounds: selected),
            AccessibilityWindowGeometry(title: "Document", bounds: selected)
        ]

        XCTAssertEqual(
            AccessibilityWindowMatcher.matchIndex(
                selectedBounds: selected,
                selectedTitle: "Document",
                candidates: candidates
            ),
            1
        )
    }

    func testAccessibilityWindowMatcherRejectsAmbiguousGeometryAndTitle() {
        let selected = InputWindowBounds(originX: 40, originY: 70, width: 800, height: 600)
        let candidates = [
            AccessibilityWindowGeometry(title: "Document", bounds: selected),
            AccessibilityWindowGeometry(title: "Document", bounds: selected)
        ]

        XCTAssertNil(
            AccessibilityWindowMatcher.matchIndex(
                selectedBounds: selected,
                selectedTitle: "Document",
                candidates: candidates
            )
        )
    }

    func testFocusIgnoresUnresolvedWindowOutsideSelectedBounds() {
        let selectedBounds = InputWindowBounds(originX: 100, originY: 100, width: 800, height: 600)
        let selection = focusSelection(bounds: selectedBounds)
        let windows = [
            onScreenWindow(
                identifier: 11,
                processIdentifier: 11,
                applicationIdentifier: nil,
                isRegularApplication: false,
                bounds: InputWindowBounds(originX: 0, originY: 0, width: 80, height: 80)
            ),
            onScreenWindow(
                identifier: selection.windowIdentifier,
                processIdentifier: selection.processIdentifier,
                applicationIdentifier: selection.applicationIdentifier,
                isRegularApplication: true,
                bounds: selectedBounds
            )
        ]

        XCTAssertEqual(
            CoreGraphicsAccessibilityContextProvider.selectedWindowFocusState(
                for: selection,
                windows: windows
            ),
            .eligible
        )
    }

    func testFocusRejectsUnresolvedWindowOverlappingSelectedBounds() {
        let selectedBounds = InputWindowBounds(originX: 100, originY: 100, width: 800, height: 600)
        let selection = focusSelection(bounds: selectedBounds)
        let windows = [
            onScreenWindow(
                identifier: 11,
                processIdentifier: 11,
                applicationIdentifier: nil,
                isRegularApplication: false,
                bounds: InputWindowBounds(originX: 150, originY: 150, width: 30, height: 30)
            ),
            onScreenWindow(
                identifier: selection.windowIdentifier,
                processIdentifier: selection.processIdentifier,
                applicationIdentifier: selection.applicationIdentifier,
                isRegularApplication: true,
                bounds: selectedBounds
            )
        ]

        XCTAssertEqual(
            CoreGraphicsAccessibilityContextProvider.selectedWindowFocusState(
                for: selection,
                windows: windows
            ),
            .unknown
        )
    }

    func testFocusRejectsDifferentFrontmostRegularWindow() {
        let selectedBounds = InputWindowBounds(originX: 100, originY: 100, width: 800, height: 600)
        let selection = focusSelection(bounds: selectedBounds)
        let windows = [
            onScreenWindow(
                identifier: 99,
                processIdentifier: 300,
                applicationIdentifier: "com.example.other",
                isRegularApplication: true,
                bounds: InputWindowBounds(originX: 1_000, originY: 100, width: 400, height: 300)
            ),
            onScreenWindow(
                identifier: selection.windowIdentifier,
                processIdentifier: selection.processIdentifier,
                applicationIdentifier: selection.applicationIdentifier,
                isRegularApplication: true,
                bounds: selectedBounds
            )
        ]

        XCTAssertEqual(
            CoreGraphicsAccessibilityContextProvider.selectedWindowFocusState(
                for: selection,
                windows: windows
            ),
            .notForeground
        )
    }

    func testFocusTreatsInvalidUnresolvedWindowBoundsAsPotentiallyOverlapping() {
        let selectedBounds = InputWindowBounds(originX: 100, originY: 100, width: 800, height: 600)
        let selection = focusSelection(bounds: selectedBounds)
        let windows = [
            onScreenWindow(
                identifier: 11,
                processIdentifier: 11,
                applicationIdentifier: nil,
                isRegularApplication: false,
                bounds: InputWindowBounds(originX: .nan, originY: 150, width: 30, height: 30)
            ),
            onScreenWindow(
                identifier: selection.windowIdentifier,
                processIdentifier: selection.processIdentifier,
                applicationIdentifier: selection.applicationIdentifier,
                isRegularApplication: true,
                bounds: selectedBounds
            )
        ]

        XCTAssertEqual(
            CoreGraphicsAccessibilityContextProvider.selectedWindowFocusState(
                for: selection,
                windows: windows
            ),
            .unknown
        )
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

    func testPreciseScrollFractionsAccumulatePerAxis() throws {
        var normalizer = InputEventNormalizer(
            contentRect: InputContentRect(originX: 0, originY: 0, width: 100, height: 100),
            readiness: .ready(windowGeneration: 1)
        )
        var totalDeltaX: Int32 = 0
        var totalDeltaY: Int32 = 0

        for sequence in 0 ..< 5 {
            let event = try normalizer.scroll(
                at: InputPoint(x: 50, y: 50),
                deltaX: 0.2,
                deltaY: -0.2,
                timestampNanoseconds: UInt64(sequence + 1)
            )
            totalDeltaX += try XCTUnwrap(event.deltaX)
            totalDeltaY += try XCTUnwrap(event.deltaY)
        }

        XCTAssertEqual(totalDeltaX, 1)
        XCTAssertEqual(totalDeltaY, -1)
    }

    func testScrollFractionalRemainderDoesNotCrossReadinessEpoch() throws {
        var normalizer = InputEventNormalizer(
            contentRect: InputContentRect(originX: 0, originY: 0, width: 100, height: 100),
            readiness: .ready(windowGeneration: 1)
        )

        let first = try normalizer.scroll(
            at: InputPoint(x: 50, y: 50),
            deltaX: 0.4,
            deltaY: 0.4,
            timestampNanoseconds: 1
        )
        normalizer.update(
            contentRect: InputContentRect(originX: 0, originY: 0, width: 100, height: 100),
            readiness: .ready(windowGeneration: 2)
        )
        let nextEpoch = try normalizer.scroll(
            at: InputPoint(x: 50, y: 50),
            deltaX: 0.4,
            deltaY: 0.4,
            timestampNanoseconds: 2
        )

        XCTAssertEqual(first.deltaX, 0)
        XCTAssertEqual(first.deltaY, 0)
        XCTAssertEqual(nextEpoch.windowGeneration, 2)
        XCTAssertEqual(nextEpoch.deltaX, 0)
        XCTAssertEqual(nextEpoch.deltaY, 0)
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

    func testHostMapsNormalizedPointerToSelectedWindowScreenCoordinates() throws {
        let context = authorizedHostContext()
        let record = InputEventRecord(
            sequence: 1,
            timestampNanoseconds: 1_000,
            windowGeneration: 9,
            kind: .pointerMove,
            x: UInt16.max,
            y: 0
        )

        let command = try HostInputMapper.command(for: record, in: context)

        guard case let .pointerMove(_, location) = command else {
            return XCTFail("expected a pointer move command")
        }
        XCTAssertEqual(location, InputScreenPoint(x: 1_300.0.nextDown, y: 200))

        let bottomRecord = InputEventRecord(
            sequence: 2,
            timestampNanoseconds: 2_000,
            windowGeneration: 9,
            kind: .pointerMove,
            x: 0,
            y: UInt16.max
        )
        guard case let .pointerMove(_, bottomLocation) = try HostInputMapper.command(
            for: bottomRecord,
            in: context
        ) else {
            return XCTFail("expected a second pointer move command")
        }
        XCTAssertEqual(bottomLocation, InputScreenPoint(x: 100, y: 700.0.nextDown))
    }

    func testGrantedBackgroundProcessTargetDoesNotRequireForegroundEligibility() throws {
        let context = authorizedHostContext(
            currentWindowIdentifier: 100,
            currentProcessIdentifier: 200,
            currentApplicationIdentifier: "com.example.test",
            focus: .backgroundEligible,
            processTargetingAuthorized: true
        )
        let record = InputEventRecord(
            sequence: 1,
            timestampNanoseconds: 1_000,
            windowGeneration: 9,
            kind: .pointerMove,
            x: UInt16.max / 2,
            y: UInt16.max / 2
        )

        XCTAssertNoThrow(try HostInputMapper.command(for: record, in: context))
        let controller = HostInputController(
            contextProvider: FakeHostInputContextProvider(context: context),
            injectionAdapter: RecordingHostInputAdapter()
        )
        XCTAssertEqual(controller.status(), .backgroundTargetReady)

        let withoutGrant = authorizedHostContext(
            currentWindowIdentifier: 100,
            currentProcessIdentifier: 200,
            currentApplicationIdentifier: "com.example.test",
            focus: .backgroundEligible,
            processTargetingAuthorized: false
        )
        XCTAssertThrowsError(try HostInputMapper.command(for: record, in: withoutGrant)) { error in
            XCTAssertEqual(error as? HostInputError, .focusUnavailable(.backgroundEligible))
        }
    }

    func testHostMapsAgainstCurrentWindowGeometry() throws {
        let context = authorizedHostContext(
            currentWindowBounds: InputWindowBounds(
                originX: 200,
                originY: 300,
                width: 800,
                height: 400
            )
        )
        let record = InputEventRecord(
            sequence: 1,
            timestampNanoseconds: 1_000,
            windowGeneration: 9,
            kind: .pointerMove,
            x: UInt16.max,
            y: 0
        )

        guard case let .pointerMove(_, location) = try HostInputMapper.command(
            for: record,
            in: context
        ) else {
            return XCTFail("expected a pointer move command")
        }
        XCTAssertEqual(location, InputScreenPoint(x: 1_000.0.nextDown, y: 300))
    }

    func testHostMapsKeyboardModifiersAndScrollToTypedCommands() throws {
        let context = authorizedHostContext()
        let key = InputEventRecord(
            sequence: 1,
            timestampNanoseconds: 1_000,
            windowGeneration: 9,
            kind: .keyDown,
            keyCode: 42,
            modifiers: 0x0002_0000
        )
        let scroll = InputEventRecord(
            sequence: 2,
            timestampNanoseconds: 2_000,
            windowGeneration: 9,
            kind: .scroll,
            x: 32_767,
            y: 32_767,
            deltaX: -3,
            deltaY: 4
        )

        guard case let .key(_, keyCode, modifiers, pressed) = try HostInputMapper.command(
            for: key,
            in: context
        ) else {
            return XCTFail("expected a key command")
        }
        XCTAssertEqual(keyCode, 42)
        XCTAssertEqual(modifiers, 0x0002_0000)
        XCTAssertTrue(pressed)
        guard case let .scroll(_, location, deltaX, deltaY) = try HostInputMapper.command(
            for: scroll,
            in: context
        ) else {
            return XCTFail("expected a scroll command")
        }
        XCTAssertEqual(location.x, 100 + (32_767.0 / 65_535.0) * 1_200, accuracy: 0.000_001)
        XCTAssertEqual(location.y, 200 + (32_767.0 / 65_535.0) * 500, accuracy: 0.000_001)
        XCTAssertEqual(deltaX, -3)
        XCTAssertEqual(deltaY, 4)
    }

    func testHostRejectsUnauthorizedStalePermissionFocusAndWindowState() {
        let record = InputEventRecord(
            sequence: 1,
            timestampNanoseconds: 1_000,
            windowGeneration: 9,
            kind: .pointerMove,
            x: 1,
            y: 2
        )

        var context = authorizedHostContext()
        context = HostInputContext(
            sessionAuthorized: false,
            authorizedWindowGeneration: 9,
            selectedWindow: context.selectedWindow,
            currentWindowIdentifier: 100,
            currentProcessIdentifier: 200,
            currentWindowBounds: context.currentWindowBounds,
            permission: .authorized,
            focus: .eligible,
            mouseInputEnabled: true,
            keyboardInputEnabled: true
        )
        XCTAssertThrowsError(try HostInputMapper.command(for: record, in: context)) { error in
            XCTAssertEqual(error as? HostInputError, .sessionUnauthorized)
        }

        context = authorizedHostContext(authorizedWindowGeneration: 8)
        XCTAssertThrowsError(try HostInputMapper.command(for: record, in: context)) { error in
            XCTAssertEqual(error as? HostInputError, .windowGenerationMismatch)
        }

        context = authorizedHostContext(permission: .missing)
        XCTAssertThrowsError(try HostInputMapper.command(for: record, in: context)) { error in
            XCTAssertEqual(error as? HostInputError, .permissionUnavailable)
        }

        context = authorizedHostContext(focus: .lockedScreen)
        XCTAssertThrowsError(try HostInputMapper.command(for: record, in: context)) { error in
            XCTAssertEqual(error as? HostInputError, .focusUnavailable(.lockedScreen))
        }

        context = authorizedHostContext(currentWindowIdentifier: 999)
        XCTAssertThrowsError(try HostInputMapper.command(for: record, in: context)) { error in
            XCTAssertEqual(error as? HostInputError, .windowUnavailable)
        }

        context = authorizedHostContext(currentApplicationIdentifier: "com.example.other")
        XCTAssertThrowsError(try HostInputMapper.command(for: record, in: context)) { error in
            XCTAssertEqual(error as? HostInputError, .windowUnavailable)
        }

        context = authorizedHostContext(focus: .secureInput)
        XCTAssertThrowsError(try HostInputMapper.command(for: record, in: context)) { error in
            XCTAssertEqual(error as? HostInputError, .focusUnavailable(.secureInput))
        }
    }

    func testHostControllerSerializesAdmissionAndStopsAfterFocusLoss() throws {
        let provider = FakeHostInputContextProvider(context: authorizedHostContext())
        let adapter = RecordingHostInputAdapter()
        let controller = HostInputController(
            contextProvider: provider,
            injectionAdapter: adapter
        )
        let first = InputEventRecord(
            sequence: 1,
            timestampNanoseconds: 1_000,
            windowGeneration: 9,
            kind: .pointerButton,
            x: 10,
            y: 20,
            button: 0,
            pressed: true
        )

        XCTAssertEqual(try controller.inject(first).sequence, 1)
        XCTAssertEqual(adapter.commands.count, 1)
        guard case let .pointerButton(_, location, button, pressed) = adapter.commands[0] else {
            return XCTFail("expected a pointer button command")
        }
        XCTAssertEqual(location.x, 100 + (10.0 / 65_535.0) * 1_200, accuracy: 0.000_001)
        XCTAssertEqual(location.y, 200 + (20.0 / 65_535.0) * 500, accuracy: 0.000_001)
        XCTAssertEqual(button, 0)
        XCTAssertTrue(pressed)
        XCTAssertThrowsError(try controller.inject(first)) { error in
            XCTAssertEqual(error as? HostInputError, .replayedEvent)
        }

        provider.context = authorizedHostContext(focus: .notForeground)
        let second = InputEventRecord(
            sequence: 2,
            timestampNanoseconds: 2_000,
            windowGeneration: 9,
            kind: .pointerMove,
            x: 5,
            y: 6
        )
        XCTAssertThrowsError(try controller.inject(second)) { error in
            XCTAssertEqual(error as? HostInputError, .focusUnavailable(.notForeground))
        }
        XCTAssertEqual(controller.status(), .focusUnavailable(.notForeground))

        controller.resetInputState()
        provider.context = authorizedHostContext()
        XCTAssertNoThrow(try controller.inject(first))
    }

    func testHostControllerUsesSafetyLaneAndReleasesPressedStateOnReset() throws {
        let provider = FakeHostInputContextProvider(context: authorizedHostContext())
        let adapter = RecordingHostInputAdapter()
        let controller = HostInputController(
            contextProvider: provider,
            injectionAdapter: adapter,
            limits: InputEventLimits(maxEventsPerSecond: 1)
        )
        let down = InputEventRecord(
            sequence: 1,
            timestampNanoseconds: 1_000,
            windowGeneration: 9,
            kind: .pointerButton,
            x: 10,
            y: 20,
            button: 0,
            pressed: true
        )
        let movement = InputEventRecord(
            sequence: 2,
            timestampNanoseconds: 1_001,
            windowGeneration: 9,
            kind: .pointerMove,
            x: 30,
            y: 40
        )
        let up = InputEventRecord(
            sequence: 3,
            timestampNanoseconds: 1_002,
            windowGeneration: 9,
            kind: .pointerButton,
            x: 10,
            y: 20,
            button: 0,
            pressed: false
        )

        XCTAssertNoThrow(try controller.inject(down))
        controller.reconcileInputState()
        XCTAssertEqual(adapter.commands.count, 1)
        XCTAssertThrowsError(try controller.inject(movement)) { error in
            XCTAssertEqual(error as? HostInputError, .rateLimited)
        }
        XCTAssertNoThrow(try controller.inject(up))
        XCTAssertEqual(adapter.commands.count, 2)

        let secondDown = InputEventRecord(
            sequence: 4,
            timestampNanoseconds: 2_000_000_000,
            windowGeneration: 9,
            kind: .pointerButton,
            x: 10,
            y: 20,
            button: 0,
            pressed: true
        )
        XCTAssertNoThrow(try controller.inject(secondDown))
        controller.resetInputState()
        XCTAssertEqual(adapter.commands.count, 4)
        guard case let .pointerButton(_, _, button, pressed) = adapter.commands[3] else {
            return XCTFail("expected a synthetic pointer release")
        }
        XCTAssertEqual(button, 0)
        XCTAssertFalse(pressed)
    }

    func testHostControllerRejectsUnmatchedRelease() {
        let adapter = RecordingHostInputAdapter()
        let controller = HostInputController(
            contextProvider: FakeHostInputContextProvider(context: authorizedHostContext()),
            injectionAdapter: adapter
        )
        let release = InputEventRecord(
            sequence: 1,
            timestampNanoseconds: 1_000,
            windowGeneration: 9,
            kind: .keyUp,
            keyCode: 12,
            modifiers: 0
        )

        XCTAssertThrowsError(try controller.inject(release)) { error in
            XCTAssertEqual(error as? HostInputError, .unmatchedStateRelease)
        }
        XCTAssertTrue(adapter.commands.isEmpty)
    }

    func testHostControllerAttemptsSafeReleaseAfterAuthorizationLoss() throws {
        let provider = FakeHostInputContextProvider(context: authorizedHostContext())
        let adapter = RecordingHostInputAdapter()
        let controller = HostInputController(
            contextProvider: provider,
            injectionAdapter: adapter
        )
        let down = InputEventRecord(
            sequence: 1,
            timestampNanoseconds: 1_000,
            windowGeneration: 9,
            kind: .keyDown,
            keyCode: 12,
            modifiers: 0
        )

        XCTAssertNoThrow(try controller.inject(down))
        provider.context = authorizedHostContext(
            sessionAuthorized: false,
            authorizedWindowGeneration: nil
        )
        controller.resetInputState()

        XCTAssertEqual(adapter.commands.count, 2)
        guard case let .key(_, keyCode, _, pressed) = adapter.commands[1] else {
            return XCTFail("expected a synthetic key release")
        }
        XCTAssertEqual(keyCode, 12)
        XCTAssertFalse(pressed)
    }

    func testHostControllerRejectsMixedPressedStateAfterSelectionChanges() throws {
        let provider = FakeHostInputContextProvider(context: authorizedHostContext())
        let adapter = RecordingHostInputAdapter()
        let controller = HostInputController(
            contextProvider: provider,
            injectionAdapter: adapter
        )
        let down = InputEventRecord(
            sequence: 1,
            timestampNanoseconds: 1_000,
            windowGeneration: 9,
            kind: .pointerButton,
            x: 10,
            y: 20,
            button: 0,
            pressed: true
        )

        XCTAssertNoThrow(try controller.inject(down))
        provider.context = authorizedHostContext(
            authorizedWindowGeneration: 10,
            currentWindowIdentifier: 101,
            currentProcessIdentifier: 201,
            windowIdentifier: 101,
            processIdentifier: 201,
            generation: 10
        )
        let newTargetEvent = InputEventRecord(
            sequence: 2,
            timestampNanoseconds: 2_000,
            windowGeneration: 10,
            kind: .pointerMove,
            x: 10,
            y: 20
        )

        XCTAssertThrowsError(try controller.inject(newTargetEvent)) { error in
            XCTAssertEqual(error as? HostInputError, .windowGenerationMismatch)
        }
        controller.resetInputState()
        XCTAssertEqual(controller.status(), .inputStateCleanupPending)
        XCTAssertEqual(adapter.commands.count, 1)
        XCTAssertThrowsError(try controller.inject(newTargetEvent)) { error in
            XCTAssertEqual(error as? HostInputError, .inputStateCleanupPending)
        }
    }

    func testHostControllerReleasesAdmittedStateAfterSelectionChanges() throws {
        let oldContext = authorizedHostContext()
        let provider = FakeHostInputContextProvider(context: oldContext)
        let adapter = RecordingHostInputAdapter()
        let controller = HostInputController(
            contextProvider: provider,
            injectionAdapter: adapter
        )
        let down = InputEventRecord(
            sequence: 1,
            timestampNanoseconds: 1_000,
            windowGeneration: 9,
            kind: .keyDown,
            keyCode: 12,
            modifiers: 0
        )

        XCTAssertNoThrow(try controller.inject(down))
        provider.context = authorizedHostContext(
            authorizedWindowGeneration: 10,
            currentWindowIdentifier: 101,
            currentProcessIdentifier: 201,
            windowIdentifier: 101,
            processIdentifier: 201,
            generation: 10
        )
        provider.releaseContext = oldContext

        controller.resetInputState()

        XCTAssertEqual(controller.status(), .ready)
        XCTAssertEqual(adapter.commands.count, 2)
        guard case let .key(_, keyCode, _, pressed) = adapter.commands[1] else {
            return XCTFail("expected a target-bound synthetic key release")
        }
        XCTAssertEqual(keyCode, 12)
        XCTAssertFalse(pressed)
    }

    func testHostControllerReleasesBeforeSelectionChange() throws {
        let provider = FakeHostInputContextProvider(context: authorizedHostContext())
        let adapter = RecordingHostInputAdapter()
        let controller = HostInputController(
            contextProvider: provider,
            injectionAdapter: adapter
        )
        let down = InputEventRecord(
            sequence: 1,
            timestampNanoseconds: 1_000,
            windowGeneration: 9,
            kind: .pointerButton,
            x: 10,
            y: 20,
            button: 0,
            pressed: true
        )
        let newTargetEvent = InputEventRecord(
            sequence: 2,
            timestampNanoseconds: 2_000,
            windowGeneration: 10,
            kind: .pointerMove,
            x: 10,
            y: 20
        )

        XCTAssertNoThrow(try controller.inject(down))
        controller.resetInputState()
        XCTAssertEqual(adapter.commands.count, 2)
        provider.context = authorizedHostContext(
            authorizedWindowGeneration: 10,
            currentWindowIdentifier: 101,
            currentProcessIdentifier: 201,
            windowIdentifier: 101,
            processIdentifier: 201,
            generation: 10
        )

        XCTAssertEqual(controller.status(), .ready)
        XCTAssertNoThrow(try controller.inject(newTargetEvent))
        XCTAssertEqual(adapter.commands.count, 3)
    }

    func testHostControllerRetriesCleanupAfterPermissionReturnsAndClampsMovedWindowPoint() throws {
        let provider = FakeHostInputContextProvider(context: authorizedHostContext())
        let adapter = RecordingHostInputAdapter()
        let controller = HostInputController(
            contextProvider: provider,
            injectionAdapter: adapter
        )
        let down = InputEventRecord(
            sequence: 1,
            timestampNanoseconds: 1_000,
            windowGeneration: 9,
            kind: .pointerButton,
            x: UInt16.max,
            y: UInt16.max,
            button: 0,
            pressed: true
        )

        XCTAssertNoThrow(try controller.inject(down))
        provider.context = authorizedHostContext(permission: .missing)
        controller.resetInputState()
        XCTAssertEqual(controller.status(), .inputStateCleanupPending)
        XCTAssertEqual(adapter.commands.count, 1)

        provider.context = authorizedHostContext(
            currentWindowBounds: InputWindowBounds(
                originX: 500,
                originY: 600,
                width: 100,
                height: 50
            )
        )
        controller.reconcileInputState()

        XCTAssertEqual(controller.status(), .ready)
        XCTAssertEqual(adapter.commands.count, 2)
        guard case let .pointerButton(_, location, button, pressed) = adapter.commands[1] else {
            return XCTFail("expected a synthetic pointer release")
        }
        XCTAssertEqual(location, InputScreenPoint(x: 600.0.nextDown, y: 650.0.nextDown))
        XCTAssertEqual(button, 0)
        XCTAssertFalse(pressed)
    }

    func testHostStatusRejectsMismatchedSelectionGeneration() {
        let provider = FakeHostInputContextProvider(
            context: authorizedHostContext(authorizedWindowGeneration: 8)
        )
        let controller = HostInputController(
            contextProvider: provider,
            injectionAdapter: RecordingHostInputAdapter()
        )

        XCTAssertEqual(controller.status(), .selectionUnavailable)
    }

    func testHostStatusPreservesFocusStateDuringFrontmostOrLockTransition() {
        let lockedProvider = FakeHostInputContextProvider(
            context: authorizedHostContext(
                currentWindowIdentifier: nil,
                currentProcessIdentifier: nil,
                currentWindowBounds: nil,
                focus: .lockedScreen
            )
        )
        let lockedController = HostInputController(
            contextProvider: lockedProvider,
            injectionAdapter: RecordingHostInputAdapter()
        )
        XCTAssertEqual(lockedController.status(), .focusUnavailable(.lockedScreen))

        let frontmostProvider = FakeHostInputContextProvider(
            context: authorizedHostContext(
                currentWindowIdentifier: 999,
                currentProcessIdentifier: 999,
                focus: .eligible
            )
        )
        let frontmostController = HostInputController(
            contextProvider: frontmostProvider,
            injectionAdapter: RecordingHostInputAdapter()
        )
        XCTAssertEqual(frontmostController.status(), .focusUnavailable(.notForeground))
    }

    func testSelectionSnapshotIgnoresFrontmostFocusChanges() {
        let selected = HostInputSelectionSnapshot(
            context: authorizedHostContext()
        )
        let focusChanged = HostInputSelectionSnapshot(
            context: authorizedHostContext(
                currentWindowIdentifier: 999,
                currentProcessIdentifier: 999,
                focus: .notForeground
            )
        )

        XCTAssertTrue(selected.hasSameSelectedTarget(as: focusChanged))
        XCTAssertNotEqual(selected, focusChanged)
    }

    func testHostStatusRejectsChangedOwningApplication() {
        let provider = FakeHostInputContextProvider(
            context: authorizedHostContext(currentApplicationIdentifier: "com.example.other")
        )
        let controller = HostInputController(
            contextProvider: provider,
            injectionAdapter: RecordingHostInputAdapter()
        )

        XCTAssertEqual(controller.status(), .focusUnavailable(.notForeground))
    }

    func testHostStatusReportsUnavailableWhenNoCapabilityIsEnabled() {
        let provider = FakeHostInputContextProvider(
            context: authorizedHostContext(
                mouseInputEnabled: false,
                keyboardInputEnabled: false
            )
        )
        let controller = HostInputController(
            contextProvider: provider,
            injectionAdapter: RecordingHostInputAdapter()
        )

        XCTAssertEqual(controller.status(), .capabilityUnavailable)
    }

    func testHostRejectsRecordsOverConfiguredPayloadLimit() {
        let adapter = RecordingHostInputAdapter()
        let controller = HostInputController(
            contextProvider: FakeHostInputContextProvider(context: authorizedHostContext()),
            injectionAdapter: adapter,
            limits: InputEventLimits(maxEncodedPayloadBytes: 1)
        )
        let record = InputEventRecord(
            sequence: 1,
            timestampNanoseconds: 1_000,
            windowGeneration: 9,
            kind: .pointerMove,
            x: 1,
            y: 2
        )

        XCTAssertThrowsError(try controller.inject(record)) { error in
            XCTAssertEqual(error as? HostInputError, .invalidEvent)
        }
        XCTAssertTrue(adapter.commands.isEmpty)
    }

    func testHostControllerRejectsMalformedModifiersButtonsAndRateBurst() {
        let provider = FakeHostInputContextProvider(context: authorizedHostContext())
        let adapter = RecordingHostInputAdapter()
        let controller = HostInputController(
            contextProvider: provider,
            injectionAdapter: adapter,
            limits: InputEventLimits(maxEventsPerSecond: 1)
        )
        let invalidModifier = InputEventRecord(
            sequence: 1,
            timestampNanoseconds: 1_000,
            windowGeneration: 9,
            kind: .keyDown,
            keyCode: 12,
            modifiers: 1
        )
        XCTAssertThrowsError(try controller.inject(invalidModifier)) { error in
            XCTAssertEqual(error as? HostInputError, .invalidModifierMask)
        }

        let unsupportedButton = InputEventRecord(
            sequence: 2,
            timestampNanoseconds: 2_000,
            windowGeneration: 9,
            kind: .pointerButton,
            x: 1,
            y: 1,
            button: 3,
            pressed: true
        )
        XCTAssertThrowsError(try controller.inject(unsupportedButton)) { error in
            XCTAssertEqual(error as? HostInputError, .unsupportedButton)
        }

        let valid = InputEventRecord(
            sequence: 3,
            timestampNanoseconds: 3_000,
            windowGeneration: 9,
            kind: .pointerMove,
            x: 1,
            y: 1
        )
        XCTAssertNoThrow(try controller.inject(valid))

        let burst = InputEventRecord(
            sequence: 4,
            timestampNanoseconds: 3_001,
            windowGeneration: 9,
            kind: .pointerMove,
            x: 2,
            y: 2
        )
        XCTAssertThrowsError(try controller.inject(burst)) { error in
            XCTAssertEqual(error as? HostInputError, .rateLimited)
        }
    }

    // Keyboard layout policy (docs/PROTOCOL.md): physical key positions are
    // forwarded unchanged and the Host's active input source interprets them.

    func testHostForwardsOptionDeadKeySequenceAsOrderedPhysicalKeyEvents() throws {
        // US-layout Option-E dead key followed by E. The Host must not compose,
        // collapse, or reorder these; its own text system does the composition.
        let option: UInt32 = 0x0008_0000
        let steps: [(keyCode: UInt16, modifiers: UInt32, pressed: Bool)] = [
            (58, option, true),
            (14, option, true),
            (14, option, false),
            (58, 0, false),
            (14, 0, true),
            (14, 0, false)
        ]

        let adapter = try injectKeySequence(steps)

        XCTAssertEqual(adapter.commands.count, steps.count)
        XCTAssertEqual(keyCommands(adapter.commands), steps.map { KeyCommandValues($0) })
    }

    func testHostPreservesModifierOrderingAndMasksAroundShortcut() throws {
        // Shift-Command-Z with left Shift pressed first and released last.
        let shift: UInt32 = 0x0002_0000
        let command: UInt32 = 0x0010_0000
        let steps: [(keyCode: UInt16, modifiers: UInt32, pressed: Bool)] = [
            (56, shift, true),
            (55, shift | command, true),
            (6, shift | command, true),
            (6, shift | command, false),
            (55, shift, false),
            (56, 0, false)
        ]

        let adapter = try injectKeySequence(steps)

        XCTAssertEqual(keyCommands(adapter.commands), steps.map { KeyCommandValues($0) })
    }

    func testHostForwardsLayoutSpecificKeyCodesWithoutRemapping() throws {
        // ISO section (10), JIS Yen (93), JIS Eisu (102), JIS Kana (104), and a
        // key carrying the Caps Lock state bit are passed through as positions.
        let capsLock: UInt32 = 0x0001_0000
        let steps: [(keyCode: UInt16, modifiers: UInt32, pressed: Bool)] = [
            (10, 0, true), (10, 0, false),
            (93, 0, true), (93, 0, false),
            (102, 0, true), (102, 0, false),
            (104, 0, true), (104, 0, false),
            (0, capsLock, true), (0, capsLock, false)
        ]

        let adapter = try injectKeySequence(steps)

        XCTAssertEqual(keyCommands(adapter.commands), steps.map { KeyCommandValues($0) })
    }

    func testHostKeyRejectionStatusAndReceiptsContainNoKeyValues() throws {
        // A distinctive key code and mask that must not appear in any text the
        // Host could surface to status UI or diagnostics.
        let keyCode: UInt16 = 47_813
        let modifiers: UInt32 = 0x0048_0000
        let forbidden = ["\(keyCode)", "\(modifiers)", String(modifiers, radix: 16)]
        let provider = FakeHostInputContextProvider(context: authorizedHostContext())
        let controller = HostInputController(
            contextProvider: provider,
            injectionAdapter: RecordingHostInputAdapter()
        )
        var surfaced: [String] = []

        func key(_ sequence: UInt64, pressed: Bool, mask: UInt32 = modifiers) -> InputEventRecord {
            InputEventRecord(
                sequence: sequence,
                timestampNanoseconds: sequence * 1_000,
                windowGeneration: 9,
                kind: pressed ? .keyDown : .keyUp,
                keyCode: keyCode,
                modifiers: mask
            )
        }
        func captureRejection(_ record: InputEventRecord) {
            do {
                surfaced.append(String(describing: try controller.inject(record)))
                XCTFail("expected rejection")
            } catch {
                surfaced.append(String(describing: error))
            }
        }

        captureRejection(key(1, pressed: false))
        captureRejection(key(2, pressed: true, mask: modifiers | 0x0000_0001))
        let receipt = try controller.inject(key(3, pressed: true))
        surfaced.append(String(describing: receipt))
        surfaced.append(String(describing: controller.status()))
        provider.context = authorizedHostContext(focus: .secureInput)
        captureRejection(key(4, pressed: true))
        surfaced.append(String(describing: controller.status()))
        provider.context = authorizedHostContext(keyboardInputEnabled: false)
        captureRejection(key(5, pressed: true))

        XCTAssertEqual(surfaced.count, 7)
        for text in surfaced {
            for value in forbidden {
                XCTAssertFalse(text.contains(value), "surfaced text leaked a key value")
            }
        }
    }

    private func injectKeySequence(
        _ steps: [(keyCode: UInt16, modifiers: UInt32, pressed: Bool)]
    ) throws -> RecordingHostInputAdapter {
        let adapter = RecordingHostInputAdapter()
        let controller = HostInputController(
            contextProvider: FakeHostInputContextProvider(context: authorizedHostContext()),
            injectionAdapter: adapter
        )
        for (index, step) in steps.enumerated() {
            let sequence = UInt64(index + 1)
            try controller.inject(InputEventRecord(
                sequence: sequence,
                timestampNanoseconds: sequence * 1_000,
                windowGeneration: 9,
                kind: step.pressed ? .keyDown : .keyUp,
                keyCode: step.keyCode,
                modifiers: step.modifiers
            ))
        }
        return adapter
    }

    private func keyCommands(_ commands: [HostInputCommand]) -> [KeyCommandValues] {
        commands.map { command in
            guard case let .key(target, keyCode, modifiers, pressed) = command else {
                XCTFail("keyboard input must reach the adapter only as typed key commands")
                return KeyCommandValues(keyCode: 0, modifiers: 0, pressed: false)
            }
            XCTAssertEqual(target.windowGeneration, 9)
            return KeyCommandValues(keyCode: keyCode, modifiers: modifiers, pressed: pressed)
        }
    }

    private func authorizedHostContext(
        sessionAuthorized: Bool = true,
        authorizedWindowGeneration: UInt64? = 9,
        currentWindowIdentifier: UInt64? = 100,
        currentProcessIdentifier: Int32? = 200,
        currentApplicationIdentifier: String? = "com.example.test",
        currentWindowBounds: InputWindowBounds? = nil,
        permission: HostInputPermissionState = .authorized,
        focus: HostInputFocusState = .eligible,
        mouseInputEnabled: Bool = true,
        keyboardInputEnabled: Bool = true,
        processTargetingAuthorized: Bool = false,
        windowIdentifier: UInt64 = 100,
        processIdentifier: Int32 = 200,
        applicationIdentifier: String = "com.example.test",
        generation: UInt64 = 9
    ) -> HostInputContext {
        let selection = HostInputWindowSelection(
            windowIdentifier: windowIdentifier,
            processIdentifier: processIdentifier,
            applicationIdentifier: applicationIdentifier,
            generation: generation,
            bounds: InputWindowBounds(originX: 100, originY: 200, width: 1_200, height: 500)
        )
        return HostInputContext(
            sessionAuthorized: sessionAuthorized,
            authorizedWindowGeneration: authorizedWindowGeneration,
            selectedWindow: selection,
            currentWindowIdentifier: currentWindowIdentifier,
            currentProcessIdentifier: currentProcessIdentifier,
            currentApplicationIdentifier: currentApplicationIdentifier,
            currentWindowBounds: currentWindowBounds ?? selection.bounds,
            permission: permission,
            focus: focus,
            mouseInputEnabled: mouseInputEnabled,
            keyboardInputEnabled: keyboardInputEnabled,
            processTargetingAuthorized: processTargetingAuthorized
        )
    }

    private func focusSelection(bounds: InputWindowBounds) -> HostInputWindowSelection {
        HostInputWindowSelection(
            windowIdentifier: 100,
            processIdentifier: 200,
            applicationIdentifier: "com.linecorp.LINE",
            generation: 9,
            bounds: bounds
        )
    }

    private func onScreenWindow(
        identifier: UInt64,
        processIdentifier: Int32,
        applicationIdentifier: String?,
        isRegularApplication: Bool,
        bounds: InputWindowBounds
    ) -> CoreGraphicsAccessibilityContextProvider.OnScreenWindow {
        CoreGraphicsAccessibilityContextProvider.OnScreenWindow(
            windowIdentifier: identifier,
            processIdentifier: processIdentifier,
            applicationIdentifier: applicationIdentifier,
            isRegularApplication: isRegularApplication,
            bounds: bounds
        )
    }
}

private struct KeyCommandValues: Equatable {
    let keyCode: UInt16
    let modifiers: UInt32
    let pressed: Bool

    init(keyCode: UInt16, modifiers: UInt32, pressed: Bool) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.pressed = pressed
    }

    init(_ step: (keyCode: UInt16, modifiers: UInt32, pressed: Bool)) {
        self.init(keyCode: step.keyCode, modifiers: step.modifiers, pressed: step.pressed)
    }
}

@MainActor
private final class FakeInputSourceProvider: InputSourceProvider {
    let current: InputSourceDescriptor?
    let enabled: [InputSourceDescriptor]
    var selectionOutcome: InputSourceSelectionOutcome = .applied
    var onEnabledSourcesRead: (@MainActor () -> Void)?
    var onSelectionValidation: (@MainActor () -> Void)?
    private(set) var selections: [InputSourceDescriptor] = []

    init(current: InputSourceDescriptor?, enabled: [InputSourceDescriptor]) {
        self.current = current
        self.enabled = enabled
    }

    func currentInputSource() -> InputSourceDescriptor? {
        current
    }

    func enabledInputSources() -> [InputSourceDescriptor] {
        onEnabledSourcesRead?()
        return enabled
    }

    func selectInputSource(_ descriptor: InputSourceDescriptor) -> InputSourceSelectionOutcome {
        selections.append(descriptor)
        return selectionOutcome
    }

    func selectInputSource(
        _ descriptor: InputSourceDescriptor,
        validatingImmediatelyBeforeSelection isStillEligible: @MainActor () -> Bool
    ) -> InputSourceSelectionOutcome {
        onSelectionValidation?()
        guard isStillEligible() else { return .denied }
        return selectInputSource(descriptor)
    }
}

private final class FakeHostInputContextProvider: HostInputContextProvider, @unchecked Sendable {
    var context: HostInputContext
    var releaseContext: HostInputContext?

    init(context: HostInputContext) {
        self.context = context
    }

    func currentContext() -> HostInputContext {
        context
    }

    func currentReleaseContext(for target: HostInputTarget) -> HostInputContext? {
        releaseContext
    }
}

private final class RecordingHostInputAdapter: HostInputInjectionAdapter, @unchecked Sendable {
    private(set) var commands: [HostInputCommand] = []

    func inject(_ command: HostInputCommand) throws {
        commands.append(command)
    }
}
