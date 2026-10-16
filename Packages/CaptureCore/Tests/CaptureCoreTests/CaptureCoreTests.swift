@testable import CaptureCore
import AppKit
import CoreVideo
import Foundation
import XCTest

final class CaptureCoreTests: XCTestCase {
    func testPickerRequiresOnscreenTargetWhileAuthorizedCaptureMayResolveOffscreen() {
        XCTAssertTrue(WindowCandidateVisibility.permits(
            isOnScreen: true,
            isActive: false,
            allowsActiveOffscreen: false,
            allowsInactiveOffscreen: false
        ))
        XCTAssertFalse(WindowCandidateVisibility.permits(
            isOnScreen: false,
            isActive: true,
            allowsActiveOffscreen: false,
            allowsInactiveOffscreen: false
        ))
        XCTAssertTrue(WindowCandidateVisibility.permits(
            isOnScreen: false,
            isActive: true,
            allowsActiveOffscreen: true,
            allowsInactiveOffscreen: false
        ))
        XCTAssertFalse(WindowCandidateVisibility.permits(
            isOnScreen: false,
            isActive: false,
            allowsActiveOffscreen: false,
            allowsInactiveOffscreen: false
        ))
        XCTAssertTrue(WindowCandidateVisibility.permits(
            isOnScreen: false,
            isActive: false,
            allowsActiveOffscreen: false,
            allowsInactiveOffscreen: true
        ))
    }

    func testPreviouslyAuthorizedOffscreenTargetRemainsBoundToCaptureIdentityAndGeometry() {
        let selected = makeWindow(identifier: 16)
        XCTAssertTrue(WindowCandidateVisibility.permits(
            isOnScreen: false,
            isActive: false,
            allowsActiveOffscreen: false,
            allowsInactiveOffscreen: true
        ))
        XCTAssertTrue(SelectedWindowCaptureTargetEligibility.permits(
            expectedWindow: selected,
            candidateWindow: selected,
            windowLayer: 0,
            configuration: .default
        ))

        let replacedOwner = CaptureWindow(
            identifier: selected.identifier,
            applicationIdentifier: "com.example.replaced",
            bounds: selected.bounds,
            processIdentifier: selected.processIdentifier + 1,
            eligible: true
        )
        XCTAssertFalse(SelectedWindowCaptureTargetEligibility.permits(
            expectedWindow: selected,
            candidateWindow: replacedOwner,
            windowLayer: 0,
            configuration: .default
        ))
    }

    func testCaptureRestartRevalidatesOwnerLayerAndGeometryWithoutForegroundState() {
        let selected = makeWindow(identifier: 16)
        XCTAssertTrue(SelectedWindowCaptureTargetEligibility.permits(
            expectedWindow: selected,
            candidateWindow: selected,
            windowLayer: 0,
            configuration: .default
        ))

        let reusedOwner = CaptureWindow(
            identifier: selected.identifier,
            applicationIdentifier: "com.example.reused",
            bounds: selected.bounds,
            processIdentifier: selected.processIdentifier + 1,
            eligible: true
        )
        XCTAssertFalse(SelectedWindowCaptureTargetEligibility.permits(
            expectedWindow: selected,
            candidateWindow: reusedOwner,
            windowLayer: 0,
            configuration: .default
        ))
        XCTAssertFalse(SelectedWindowCaptureTargetEligibility.permits(
            expectedWindow: selected,
            candidateWindow: selected,
            windowLayer: 1,
            configuration: .default
        ))
        let invalidGeometry = CaptureWindow(
            identifier: selected.identifier,
            applicationIdentifier: selected.applicationIdentifier,
            bounds: WindowBounds(x: .infinity, y: 0, width: 640, height: 480),
            processIdentifier: selected.processIdentifier,
            eligible: true
        )
        XCTAssertFalse(SelectedWindowCaptureTargetEligibility.permits(
            expectedWindow: selected,
            candidateWindow: invalidGeometry,
            windowLayer: 0,
            configuration: .default
        ))
    }

    func testDebugDiscoveryCandidateCountsAccountForEveryFixedFilterReason() {
        var counts = ScreenRecordingWindowDiscoveryCountAccumulator()
        counts.record(nil)
        counts.record(.offScreen)
        counts.record(.nonBaseLayer)
        counts.record(.missingApplication)
        counts.record(.helperApplication)
        counts.record(.invalidWindow)

        let result = counts.snapshot(candidateCount: 6)
        XCTAssertEqual(result.candidates, 6)
        XCTAssertEqual(result.eligible, 1)
        XCTAssertEqual(result.offScreen, 1)
        XCTAssertEqual(result.nonBaseLayer, 1)
        XCTAssertEqual(result.missingApplication, 1)
        XCTAssertEqual(result.helperApplication, 1)
        XCTAssertEqual(result.invalidWindow, 1)
        XCTAssertEqual(
            result.candidates,
            result.eligible + result.offScreen + result.nonBaseLayer + result.missingApplication + result.helperApplication + result.invalidWindow
        )
    }

    func testM0FoundationMarker() {
        XCTAssertEqual(CaptureCoreModule.name, "CaptureCore")
    }

    func testWindowCaptureSessionStartsSelectedWindowAndRelaysBoundedFrame() async throws {
        let window = makeWindow(identifier: 42)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let engine = FakeCaptureEngine()
        let factory = FakeCaptureEngineFactory(engine: engine)
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: factory,
            configuration: CaptureConfiguration(
                monitorIntervalNanoseconds: 0,
                outputBufferCount: 2
            )
        )

        try await session.start(windowIdentifier: window.identifier)
        let startedWindow = engine.startedWindow()
        XCTAssertEqual(startedWindow, window)
        let startedSnapshot = await session.snapshot()
        XCTAssertEqual(
            startedSnapshot.state,
            .capturing(windowIdentifier: window.identifier, generation: 1)
        )

        let receiveTask = Task { () -> CapturedFrame? in
            var iterator = session.frames.makeAsyncIterator()
            return try? await iterator.next()
        }
        let frame = try makeFrame(windowIdentifier: window.identifier, generation: 1)
        engine.emit(frame)
        let received = await receiveTask.value
        XCTAssertEqual(received?.windowIdentifier, window.identifier)
        XCTAssertEqual(received?.generation, 1)
        XCTAssertEqual(received?.width, 2)
        XCTAssertEqual(received?.height, 2)

        await session.stop()
        let stoppedSnapshot = await session.snapshot()
        XCTAssertEqual(stoppedSnapshot.state, .stopped(.cancelled))
    }

    /// Regression: the Host cancels its capture task on every pipeline stop
    /// or window replacement. Swift terminates an `AsyncThrowingStream` when
    /// its waiting consumer is cancelled, so a shared stream delivered no
    /// frames after the first restart and the Viewer froze on the last frame.
    func testCancelledConsumerDoesNotStopFramesForNextGeneration() async throws {
        let window = makeWindow(identifier: 44)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let firstEngine = GatedCaptureEngine(startGate: TestAsyncSignal(signaled: true))
        let secondEngine = GatedCaptureEngine(startGate: TestAsyncSignal(signaled: true))
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: SequencedCaptureEngineFactory(engines: [firstEngine, secondEngine]),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )

        try await session.start(windowIdentifier: window.identifier)
        let firstConsumer = Task { () -> Int in
            var count = 0
            var iterator = session.frames.makeAsyncIterator()
            while (try? await iterator.next()) != nil {
                count += 1
            }
            return count
        }
        firstEngine.emit(try makeFrame(windowIdentifier: window.identifier, generation: 1))
        try await Task.sleep(nanoseconds: 50_000_000)
        // The Host's stopVideoPipeline(): cancel while the consumer waits.
        firstConsumer.cancel()
        let firstCount = await firstConsumer.value
        XCTAssertEqual(firstCount, 1)

        try await session.start(windowIdentifier: window.identifier)
        let secondConsumer = Task { () -> CapturedFrame? in
            var iterator = session.frames.makeAsyncIterator()
            return try await iterator.next()
        }
        secondEngine.emit(try makeFrame(windowIdentifier: window.identifier, generation: 2))
        let received = try await secondConsumer.value
        XCTAssertEqual(received?.generation, 2, "the next generation must still deliver frames")
        await session.stop()
    }

    func testSupersededStartFailureDoesNotFailNewerGeneration() async throws {
        let window = makeWindow(identifier: 43)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let firstGate = TestAsyncSignal()
        let firstEngine = GatedCaptureEngine(
            startGate: firstGate,
            startFailure: .captureFailed("superseded start")
        )
        let secondEngine = GatedCaptureEngine(startGate: TestAsyncSignal(signaled: true))
        let factory = SequencedCaptureEngineFactory(engines: [firstEngine, secondEngine])
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: factory,
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )

        let firstStart = Task { () -> Bool in
            do {
                try await session.start(windowIdentifier: window.identifier)
                return false
            } catch {
                return true
            }
        }
        await firstEngine.waitUntilStartEntered()

        let secondStart = Task { () -> Bool in
            do {
                try await session.start(windowIdentifier: window.identifier)
                return true
            } catch {
                return false
            }
        }
        let secondStartSucceeded = await secondStart.value
        XCTAssertTrue(secondStartSucceeded)
        let newerSnapshot = await session.snapshot()
        XCTAssertEqual(
            newerSnapshot.state,
            .capturing(windowIdentifier: window.identifier, generation: 2)
        )

        await firstGate.signal()
        let firstStartFailed = await firstStart.value
        XCTAssertTrue(firstStartFailed)
        let finalSnapshot = await session.snapshot()
        XCTAssertEqual(
            finalSnapshot.state,
            .capturing(windowIdentifier: window.identifier, generation: 2)
        )
        XCTAssertEqual(secondEngine.stopCount(), 0)
        XCTAssertGreaterThanOrEqual(firstEngine.stopCount(), 1)
    }

    func testDelayedStopDoesNotClearNewerCaptureGeneration() async throws {
        let window = makeWindow(identifier: 46)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let firstStopGate = TestAsyncSignal()
        let firstEngine = GatedCaptureEngine(
            startGate: TestAsyncSignal(signaled: true),
            stopGate: firstStopGate
        )
        let secondEngine = GatedCaptureEngine(startGate: TestAsyncSignal(signaled: true))
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: SequencedCaptureEngineFactory(engines: [firstEngine, secondEngine]),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )

        try await session.start(windowIdentifier: window.identifier)
        let firstStop = Task { await session.stop() }
        await firstEngine.waitUntilStopEntered()

        try await session.start(windowIdentifier: window.identifier)
        let restartedSnapshot = await session.snapshot()
        XCTAssertEqual(
            restartedSnapshot.state,
            .capturing(windowIdentifier: window.identifier, generation: 2)
        )

        await firstStopGate.signal()
        await firstStop.value

        let finalSnapshot = await session.snapshot()
        XCTAssertEqual(
            finalSnapshot.state,
            .capturing(windowIdentifier: window.identifier, generation: 2)
        )
        XCTAssertEqual(finalSnapshot.selectedWindow, window)
        XCTAssertEqual(
            finalSnapshot.outputDimensions,
            CaptureConfiguration().outputDimensions(for: window)
        )
        XCTAssertEqual(secondEngine.stopCount(), 0)
        await session.stop()
    }

    func testDelayedFailureDoesNotFinishNewerGenerationStream() async throws {
        let window = makeWindow(identifier: 47)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let firstStopGate = TestAsyncSignal()
        let firstEngine = GatedCaptureEngine(
            startGate: TestAsyncSignal(signaled: true),
            stopGate: firstStopGate
        )
        let secondEngine = GatedCaptureEngine(startGate: TestAsyncSignal(signaled: true))
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: SequencedCaptureEngineFactory(engines: [firstEngine, secondEngine]),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )

        try await session.start(windowIdentifier: window.identifier)
        await provider.setPermission(.denied)
        let failedRefresh = Task { await session.refreshSelection() }
        await firstEngine.waitUntilStopEntered()

        let failedSnapshot = await session.snapshot()
        XCTAssertEqual(failedSnapshot.state, .failed(.permissionDenied))

        await provider.setPermission(.authorized)
        try await session.start(windowIdentifier: window.identifier)
        let restartedSnapshot = await session.snapshot()
        XCTAssertEqual(
            restartedSnapshot.state,
            .capturing(windowIdentifier: window.identifier, generation: 2)
        )

        let receiveTask = Task { () -> CapturedFrame? in
            var iterator = session.frames.makeAsyncIterator()
            return try? await iterator.next()
        }
        await firstStopGate.signal()
        await failedRefresh.value

        secondEngine.emit(try makeFrame(windowIdentifier: window.identifier, generation: 2))
        let received = await receiveTask.value
        XCTAssertEqual(received?.generation, 2)

        let finalSnapshot = await session.snapshot()
        XCTAssertEqual(
            finalSnapshot.state,
            .capturing(windowIdentifier: window.identifier, generation: 2)
        )
        XCTAssertEqual(finalSnapshot.selectedWindow, window)
        XCTAssertEqual(
            finalSnapshot.outputDimensions,
            CaptureConfiguration().outputDimensions(for: window)
        )
        await session.stop()
    }

    func testRelayFailureDuringEngineStartupFailsStart() async throws {
        let window = makeWindow(identifier: 44)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let startGate = TestAsyncSignal()
        let engine = GatedCaptureEngine(startGate: startGate)
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: FakeCaptureEngineFactory(engine: engine),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )

        let startTask = Task { () -> Result<Void, CaptureCoreError> in
            do {
                try await session.start(windowIdentifier: window.identifier)
                return .success(())
            } catch let error as CaptureCoreError {
                return .failure(error)
            } catch {
                return .failure(.captureFailed(String(describing: error)))
            }
        }
        await engine.waitUntilStartEntered()
        engine.failFrames(CaptureCoreError.captureFailed("relay failed"))
        await engine.waitUntilStopped()

        let failedSnapshot = await session.snapshot()
        if case let .failed(failure) = failedSnapshot.state {
            XCTAssertEqual(failure, CaptureFailure.captureFailed("capture failed: relay failed"))
        } else {
            XCTFail("relay failure must invalidate the starting session")
        }

        await startGate.signal()
        let startResult = await startTask.value
        switch startResult {
        case .success:
            XCTFail("start must not succeed after the relay fails")
        case let .failure(error):
            XCTAssertEqual(
                error,
                .sessionFailed(.captureFailed("capture failed: relay failed"))
            )
        }
    }

    func testNormalRelayEOFDuringEngineStartupFailsStart() async throws {
        let window = makeWindow(identifier: 45)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let startGate = TestAsyncSignal()
        let engine = GatedCaptureEngine(startGate: startGate)
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: FakeCaptureEngineFactory(engine: engine),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )

        let startTask = Task { () -> Result<Void, CaptureCoreError> in
            do {
                try await session.start(windowIdentifier: window.identifier)
                return .success(())
            } catch let error as CaptureCoreError {
                return .failure(error)
            } catch {
                return .failure(.captureFailed(String(describing: error)))
            }
        }
        await engine.waitUntilStartEntered()
        engine.finishFrames()
        await engine.waitUntilStopped()

        let failedSnapshot = await session.snapshot()
        XCTAssertEqual(
            failedSnapshot.state,
            .failed(.captureFailed("capture stream ended during startup"))
        )

        await startGate.signal()
        let startResult = await startTask.value
        switch startResult {
        case .success:
            XCTFail("start must not succeed after the relay ends during startup")
        case let .failure(error):
            XCTAssertEqual(
                error,
                .sessionFailed(.captureFailed("capture stream ended during startup"))
            )
        }
    }

    func testPermissionLossStopsCaptureBeforeAnyFurtherFrame() async throws {
        let window = makeWindow(identifier: 7)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let engine = FakeCaptureEngine()
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: FakeCaptureEngineFactory(engine: engine),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )
        try await session.start(windowIdentifier: window.identifier)

        await provider.setPermission(.denied)
        await session.refreshSelection()
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .failed(.permissionDenied))
        let stopCount = engine.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testWindowDisappearanceFailsClosed() async throws {
        let window = makeWindow(identifier: 8)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let engine = FakeCaptureEngine()
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: FakeCaptureEngineFactory(engine: engine),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )
        try await session.start(windowIdentifier: window.identifier)

        await provider.setWindows([])
        await session.refreshSelection()
        let firstMissingSnapshot = await session.snapshot()
        XCTAssertEqual(
            firstMissingSnapshot.state,
            .capturing(windowIdentifier: window.identifier, generation: 1),
            "one transient catalog miss must not stop the selected stream"
        )
        XCTAssertEqual(engine.stopCount(), 0)

        await session.refreshSelection()
        let secondMissingSnapshot = await session.snapshot()
        XCTAssertEqual(
            secondMissingSnapshot.state,
            .capturing(windowIdentifier: window.identifier, generation: 1)
        )

        await session.refreshSelection()
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .failed(.windowUnavailable))
        let stopCount = engine.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testWindowIDReuseByDifferentOwnerFailsClosed() async throws {
        let window = makeWindow(identifier: 10)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let engine = FakeCaptureEngine()
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: FakeCaptureEngineFactory(engine: engine),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )
        try await session.start(windowIdentifier: window.identifier)

        let reusedWindow = CaptureWindow(
            identifier: window.identifier,
            applicationIdentifier: "com.example.reused",
            applicationName: window.applicationName,
            title: window.title,
            bounds: window.bounds,
            processIdentifier: window.processIdentifier + 1,
            eligible: true
        )
        await provider.setWindows([reusedWindow])
        await session.refreshSelection()

        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.state, .failed(.windowUnavailable))
    }

    func testRecoverableCaptureFailureCanRestartTheReusableOutputStream() async throws {
        let window = makeWindow(identifier: 11)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let firstEngine = GatedCaptureEngine(startGate: TestAsyncSignal(signaled: true))
        let secondEngine = GatedCaptureEngine(startGate: TestAsyncSignal(signaled: true))
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: SequencedCaptureEngineFactory(engines: [firstEngine, secondEngine]),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )
        try await session.start(windowIdentifier: window.identifier)
        await provider.setWindows([])
        await session.refreshSelection()
        await session.refreshSelection()
        await session.refreshSelection()
        let failedSnapshot = await session.snapshot()
        XCTAssertEqual(failedSnapshot.state, .failed(.windowUnavailable))

        await provider.setWindows([window])
        try await session.start(windowIdentifier: window.identifier)
        let restartedSnapshot = await session.snapshot()
        XCTAssertEqual(
            restartedSnapshot.state,
            .capturing(windowIdentifier: window.identifier, generation: 2)
        )

        let receiveTask = Task { () -> CapturedFrame? in
            var iterator = session.frames.makeAsyncIterator()
            return try? await iterator.next()
        }
        secondEngine.emit(try makeFrame(windowIdentifier: window.identifier, generation: 2))
        let received = await receiveTask.value
        XCTAssertEqual(received?.generation, 2)
        XCTAssertEqual(received?.windowIdentifier, window.identifier)
    }

    func testTransientDiscoveryGapKeepsSelectedCaptureAndFrameDelivery() async throws {
        let window = makeWindow(identifier: 12)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let engine = FakeCaptureEngine()
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: FakeCaptureEngineFactory(engine: engine),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )
        try await session.start(windowIdentifier: window.identifier)

        await provider.setWindows([])
        await session.refreshSelection()
        let gapSnapshot = await session.snapshot()
        XCTAssertEqual(
            gapSnapshot.state,
            .capturing(windowIdentifier: window.identifier, generation: 1)
        )
        XCTAssertEqual(engine.stopCount(), 0)

        let receiveTask = Task { () -> CapturedFrame? in
            var iterator = session.frames.makeAsyncIterator()
            return try? await iterator.next()
        }
        engine.emit(try makeFrame(windowIdentifier: window.identifier, generation: 1))
        let received = await receiveTask.value
        XCTAssertEqual(received?.windowIdentifier, window.identifier)
        XCTAssertEqual(received?.generation, 1)

        await provider.setWindows([window])
        await session.refreshSelection()
        let restoredSnapshot = await session.snapshot()
        XCTAssertEqual(restoredSnapshot.state, .capturing(windowIdentifier: window.identifier, generation: 1))
    }

    func testAuthorizedSelectionStartsWhenNormalLivenessLookupReportsInactiveOffscreen() async throws {
        let window = makeWindow(identifier: 17)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        await provider.setRefreshOverride(.unavailable)
        await provider.setRestartWindows([window])
        let engine = FakeCaptureEngine()
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: FakeCaptureEngineFactory(engine: engine),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )

        try await session.start(window: window)
        let snapshot = await session.snapshot()

        XCTAssertEqual(
            snapshot.state,
            .capturing(windowIdentifier: window.identifier, generation: 1)
        )
        XCTAssertEqual(engine.startedWindow(), window)
    }

    func testUnexpectedNormalStreamEndRestartsBoundedlyAndKeepsFrameIterator() async throws {
        let window = makeWindow(identifier: 13)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let firstEngine = GatedCaptureEngine(startGate: TestAsyncSignal(signaled: true))
        let secondEngine = GatedCaptureEngine(startGate: TestAsyncSignal(signaled: true))
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: SequencedCaptureEngineFactory(engines: [firstEngine, secondEngine]),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )
        try await session.start(windowIdentifier: window.identifier)

        let receiveTask = Task { () throws -> CapturedFrame? in
            var iterator = session.frames.makeAsyncIterator()
            return try await iterator.next()
        }
        firstEngine.finishFrames()
        let recovering = await waitForState(
            .recovering(windowIdentifier: window.identifier, generation: 2),
            in: session
        )
        XCTAssertNotNil(recovering, "normal stream completion should enter visible recovery")

        let restarted = await waitForState(
            .capturing(windowIdentifier: window.identifier, generation: 2),
            in: session
        )
        XCTAssertNotNil(restarted, "the same selected target should restart in the next generation")
        secondEngine.emit(try makeFrame(windowIdentifier: window.identifier, generation: 2))
        let received = try await receiveTask.value
        XCTAssertEqual(received?.generation, 2)
        XCTAssertEqual(received?.windowIdentifier, window.identifier)
    }

    func testRecoveryIgnoresInactiveLivenessMissAndKeepsGenerationDimensions() async throws {
        let window = makeWindow(identifier: 18)
        let movedWindow = CaptureWindow(
            identifier: window.identifier,
            applicationIdentifier: window.applicationIdentifier,
            applicationName: window.applicationName,
            title: window.title,
            bounds: WindowBounds(x: 200, y: 100, width: 1024, height: 768),
            backingScaleFactor: 2,
            processIdentifier: window.processIdentifier,
            eligible: true
        )
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let firstEngine = GatedCaptureEngine(startGate: TestAsyncSignal(signaled: true))
        let secondEngine = GatedCaptureEngine(startGate: TestAsyncSignal(signaled: true))
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: SequencedCaptureEngineFactory(engines: [firstEngine, secondEngine]),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 5_000_000)
        )
        try await session.start(windowIdentifier: window.identifier)
        let originalDimensions = await session.snapshot().outputDimensions

        await provider.setRefreshOverride(.unavailable)
        await provider.setRestartWindows([movedWindow])
        firstEngine.finishFrames()

        let recovered = await waitForState(
            .capturing(windowIdentifier: window.identifier, generation: 2),
            in: session
        )
        XCTAssertNotNil(
            recovered,
            "inactive normal-liveness snapshots must not consume restart attempts"
        )
        XCTAssertEqual(secondEngine.startedWindow(), window)
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.selectedWindow, movedWindow)
        XCTAssertEqual(snapshot.outputDimensions, originalDimensions)
    }

    func testCaptureRestartStopsAfterBoundedAttempts() async throws {
        let window = makeWindow(identifier: 14)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let engines = (0 ..< 3).map { _ in
            GatedCaptureEngine(startGate: TestAsyncSignal(signaled: true))
        }
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: SequencedCaptureEngineFactory(engines: engines),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )
        try await session.start(windowIdentifier: window.identifier)

        engines[0].finishFrames()
        let secondGeneration = await waitForState(
            .capturing(windowIdentifier: window.identifier, generation: 2),
            in: session
        )
        XCTAssertNotNil(secondGeneration)
        engines[1].finishFrames()
        let thirdGeneration = await waitForState(
            .capturing(windowIdentifier: window.identifier, generation: 3),
            in: session
        )
        XCTAssertNotNil(thirdGeneration)
        engines[2].finishFrames()
        let exhausted = await waitForState(
            .failed(.captureFailed("capture stream ended unexpectedly")),
            in: session
        )
        XCTAssertNotNil(exhausted, "recovery must stop after the configured retry budget")
    }

    func testCaptureRestartFailsClosedWhenWindowIDHasAReusedOwner() async throws {
        let window = makeWindow(identifier: 15)
        let provider = FakeWindowProvider(windows: [window], permission: .authorized)
        let firstEngine = GatedCaptureEngine(startGate: TestAsyncSignal(signaled: true))
        let secondEngine = GatedCaptureEngine(startGate: TestAsyncSignal(signaled: true))
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: SequencedCaptureEngineFactory(engines: [firstEngine, secondEngine]),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )
        try await session.start(windowIdentifier: window.identifier)
        firstEngine.finishFrames()

        let recovering = await waitForState(
            .recovering(windowIdentifier: window.identifier, generation: 2),
            in: session
        )
        XCTAssertNotNil(recovering)
        let reusedWindow = CaptureWindow(
            identifier: window.identifier,
            applicationIdentifier: "com.example.reused",
            applicationName: window.applicationName,
            title: window.title,
            bounds: window.bounds,
            processIdentifier: window.processIdentifier + 1,
            eligible: true
        )
        await provider.setWindows([reusedWindow])

        let failed = await waitForState(.failed(.windowUnavailable), in: session)
        XCTAssertNotNil(failed)
        XCTAssertEqual(secondEngine.startCount(), 0)
    }

    func testInvalidWindowNeverStartsCapture() async throws {
        let ineligible = CaptureWindow(
            identifier: 9,
            applicationIdentifier: "com.example.test",
            bounds: WindowBounds(x: 0, y: 0, width: 1, height: 1),
            processIdentifier: 9,
            eligible: false
        )
        let provider = FakeWindowProvider(windows: [ineligible], permission: .authorized)
        let engine = FakeCaptureEngine()
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: FakeCaptureEngineFactory(engine: engine),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )

        do {
            try await session.start(windowIdentifier: ineligible.identifier)
            XCTFail("an ineligible window must not start capture")
        } catch CaptureCoreError.invalidWindow {
            // Expected.
        }
        XCTAssertFalse(engine.wasStarted())
    }

    func testCaptureConfigurationDefaultsToEncoderNativeYUV() {
        XCTAssertEqual(
            CaptureConfiguration().pixelFormat,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
    }

    func testCaptureConfigurationRejectsTinyHelperWindows() {
        let configuration = CaptureConfiguration()
        XCTAssertFalse(
            configuration.acceptsWindowSize(
                WindowBounds(x: 0, y: 0, width: 1, height: 33)
            )
        )
        XCTAssertFalse(
            configuration.acceptsWindowSize(
                WindowBounds(x: 0, y: 0, width: 159, height: 80)
            )
        )
        XCTAssertTrue(
            configuration.acceptsWindowSize(
                WindowBounds(x: 0, y: 0, width: 160, height: 80)
            )
        )
    }

    func testOutputDimensionsAtScaleOneUsePointSizeWithinCap() {
        let configuration = CaptureConfiguration()
        let bounds = WindowBounds(x: 10, y: 20, width: 1_280, height: 720)
        XCTAssertEqual(
            configuration.outputDimensions(for: bounds, backingScaleFactor: 1),
            CaptureOutputDimensions(width: 1_280, height: 720)
        )
        XCTAssertEqual(
            configuration.outputDimensions(for: bounds),
            CaptureOutputDimensions(width: 1_280, height: 720)
        )
    }

    func testOutputDimensionsAtScaleTwoCaptureBackingPixels() {
        let configuration = CaptureConfiguration()
        let window = makeWindow(
            identifier: 1,
            bounds: WindowBounds(x: 0, y: 0, width: 640, height: 480),
            backingScaleFactor: 2
        )
        XCTAssertEqual(
            configuration.outputDimensions(for: window),
            CaptureOutputDimensions(width: 1_280, height: 960)
        )

        let exactFit = makeWindow(
            identifier: 2,
            bounds: WindowBounds(x: 0, y: 0, width: 960, height: 540),
            backingScaleFactor: 2
        )
        XCTAssertEqual(
            configuration.outputDimensions(for: exactFit),
            CaptureOutputDimensions(width: 1_920, height: 1_080)
        )
    }

    func testOversizedWindowsDownscaleToCapPreservingAspectRatio() {
        let configuration = CaptureConfiguration()
        let bounds = WindowBounds(x: 0, y: 0, width: 1_600, height: 1_000)

        // 1600x1000 points fits at scale 1 and is never upscaled.
        XCTAssertEqual(
            configuration.outputDimensions(for: bounds, backingScaleFactor: 1),
            CaptureOutputDimensions(width: 1_600, height: 1_000)
        )
        // 3200x2000 pixels is height-bound: 0.54 x -> 1728x1080.
        XCTAssertEqual(
            configuration.outputDimensions(for: bounds, backingScaleFactor: 2),
            CaptureOutputDimensions(width: 1_728, height: 1_080)
        )
        // A wide Retina window is width-bound: 5120x1440 -> 1920x540.
        XCTAssertEqual(
            configuration.outputDimensions(
                for: WindowBounds(x: 0, y: 0, width: 2_560, height: 720),
                backingScaleFactor: 2
            ),
            CaptureOutputDimensions(width: 1_920, height: 540)
        )
        // A 5K Retina window stays within the cap in both dimensions.
        let fiveK = configuration.outputDimensions(
            for: WindowBounds(x: 0, y: 0, width: 2_560, height: 1_440),
            backingScaleFactor: 2
        )
        XCTAssertEqual(fiveK, CaptureOutputDimensions(width: 1_920, height: 1_080))
    }

    func testOutputDimensionsNeverExceedConfiguredCapForAnyScale() {
        let configuration = CaptureConfiguration(maximumWidth: 1_280, maximumHeight: 720)
        for scale in [1.0, 1.5, 2.0, 3.0] {
            for (width, height) in [(160.0, 80.0), (800.0, 600.0), (1_920.0, 1_200.0), (3_000.0, 400.0)] {
                let bounds = WindowBounds(x: 0, y: 0, width: width, height: height)
                let output = configuration.outputDimensions(for: bounds, backingScaleFactor: scale)
                XCTAssertLessThanOrEqual(output.width, 1_280)
                XCTAssertLessThanOrEqual(output.height, 720)
                let sourceAspect = width / height
                let outputAspect = Double(output.width) / Double(output.height)
                XCTAssertEqual(outputAspect, sourceAspect, accuracy: sourceAspect * 0.01)
            }
        }
    }

    func testInvalidBackingScaleFallsBackToPointSize() {
        XCTAssertEqual(CaptureBackingScale.sanitized(.nan), 1)
        XCTAssertEqual(CaptureBackingScale.sanitized(.infinity), 1)
        XCTAssertEqual(CaptureBackingScale.sanitized(0), 1)
        XCTAssertEqual(CaptureBackingScale.sanitized(-2), 1)
        XCTAssertEqual(CaptureBackingScale.sanitized(0.5), 1)
        XCTAssertEqual(CaptureBackingScale.sanitized(8), 4)
        let window = makeWindow(
            identifier: 1,
            bounds: WindowBounds(x: 0, y: 0, width: 640, height: 480),
            backingScaleFactor: .nan
        )
        XCTAssertEqual(window.backingScaleFactor, 1)
        XCTAssertEqual(
            CaptureConfiguration().outputDimensions(for: window),
            CaptureOutputDimensions(width: 640, height: 480)
        )
    }

    func testBackingScaleComesFromDisplayHoldingMostOfTheWindow() {
        let standard = CaptureDisplayGeometry(
            bounds: WindowBounds(x: 0, y: 0, width: 1_920, height: 1_080),
            backingScaleFactor: 1
        )
        let retina = CaptureDisplayGeometry(
            bounds: WindowBounds(x: 1_920, y: 0, width: 1_512, height: 982),
            backingScaleFactor: 2
        )
        let displays = [standard, retina]

        let mostlyStandard = WindowBounds(x: 1_500, y: 100, width: 600, height: 400)
        XCTAssertEqual(
            CaptureBackingScale.backingScaleFactor(forWindow: mostlyStandard, displays: displays),
            1
        )
        let mostlyRetina = WindowBounds(x: 1_800, y: 100, width: 600, height: 400)
        XCTAssertEqual(
            CaptureBackingScale.backingScaleFactor(forWindow: mostlyRetina, displays: displays),
            2
        )
        let evenSplit = WindowBounds(x: 1_620, y: 100, width: 600, height: 400)
        XCTAssertEqual(
            CaptureBackingScale.backingScaleFactor(forWindow: evenSplit, displays: displays),
            2
        )
        let offscreen = WindowBounds(x: -5_000, y: -5_000, width: 600, height: 400)
        XCTAssertEqual(
            CaptureBackingScale.backingScaleFactor(forWindow: offscreen, displays: displays),
            1
        )
        XCTAssertEqual(
            CaptureBackingScale.backingScaleFactor(forWindow: mostlyRetina, displays: []),
            1
        )
    }

    func testSessionPinsOutputDimensionsForTheGenerationAcrossDisplayMoves() async throws {
        let retinaWindow = makeWindow(
            identifier: 42,
            bounds: WindowBounds(x: 0, y: 0, width: 800, height: 600),
            backingScaleFactor: 2
        )
        let provider = FakeWindowProvider(windows: [retinaWindow], permission: .authorized)
        let engine = FakeCaptureEngine()
        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: FakeCaptureEngineFactory(engine: engine),
            configuration: CaptureConfiguration(monitorIntervalNanoseconds: 0)
        )

        try await session.start(windowIdentifier: retinaWindow.identifier)
        // 1600x1200 pixels fit to 1440x1080.
        let expected = CaptureOutputDimensions(width: 1_440, height: 1_080)
        var snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.outputDimensions, expected)
        XCTAssertEqual(engine.startedWindow()?.backingScaleFactor, 2)

        // The window moves to a standard display. The catalog entry updates
        // (input mapping uses current point bounds) but the running stream
        // keeps the size it was configured with for this generation.
        let movedWindow = makeWindow(
            identifier: 42,
            bounds: WindowBounds(x: 2_000, y: 0, width: 800, height: 600),
            backingScaleFactor: 1
        )
        await provider.setWindows([movedWindow])
        await session.refreshSelection()
        snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.selectedWindow, movedWindow)
        XCTAssertEqual(snapshot.outputDimensions, expected)
        XCTAssertEqual(snapshot.generation, 1)

        await session.stop()
        snapshot = await session.snapshot()
        XCTAssertNil(snapshot.outputDimensions)
    }

    func testM3SystemCaptureSmokeWhenOptedIn() async throws {
        guard ProcessInfo.processInfo.environment["MACREMOTEAPP_RUN_M3_SYSTEM_SMOKE"] == "1" else {
            throw XCTSkip("set MACREMOTEAPP_RUN_M3_SYSTEM_SMOKE=1 to use ScreenCaptureKit")
        }

        await MainActor.run {
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)
        }

        let provider = ScreenRecordingWindowProvider()
        guard await provider.permissionState() == .authorized else {
            throw XCTSkip("Screen Recording permission is not granted to this test process")
        }
        let windows = try await provider.discoverWindows()
        guard let window = windows
            .filter({ $0.eligible && $0.applicationIdentifier != "com.apple.WindowManager" })
            .max(by: { lhs, rhs in
                lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
            }) else {
            throw XCTSkip("no eligible on-screen window is available")
        }

        let session = WindowCaptureSession(
            windowProvider: provider,
            engineFactory: SystemWindowCaptureEngineFactory(),
            configuration: CaptureConfiguration(
                monitorIntervalNanoseconds: 0,
                outputBufferCount: 2
            )
        )
        try await session.start(windowIdentifier: window.identifier)
        let frameTask = Task { () -> CapturedFrame? in
            var iterator = session.frames.makeAsyncIterator()
            return try? await iterator.next()
        }
        try await Task.sleep(nanoseconds: 5_000_000_000)
        frameTask.cancel()
        let frame = await frameTask.value
        await session.stop()
        guard let frame else {
            throw XCTSkip("ScreenCaptureKit produced no frame within five seconds")
        }
        XCTAssertEqual(frame.windowIdentifier, window.identifier)
        XCTAssertEqual(frame.generation, 1)
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
    }

    private func makeWindow(
        identifier: UInt64,
        bounds: WindowBounds = WindowBounds(x: 0, y: 0, width: 640, height: 480),
        backingScaleFactor: Double = 1
    ) -> CaptureWindow {
        CaptureWindow(
            identifier: identifier,
            applicationIdentifier: "com.example.test",
            applicationName: "Test App",
            title: "Test Window",
            bounds: bounds,
            backingScaleFactor: backingScaleFactor,
            processIdentifier: 123,
            eligible: true
        )
    }

    private func waitForState(
        _ expectedState: CaptureSessionState,
        in session: WindowCaptureSession
    ) async -> CaptureSessionSnapshot? {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ 4_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let snapshot = await session.snapshot()
            if snapshot.state == expectedState {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await session.snapshot()
    }

    private func makeFrame(windowIdentifier: UInt64, generation: UInt64) throws -> CapturedFrame {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw CaptureCoreError.captureFailed("unable to create test pixel buffer")
        }
        return CapturedFrame(
            windowIdentifier: windowIdentifier,
            generation: generation,
            captureTimestamp: 1,
            presentationTimestamp: 2,
            width: 2,
            height: 2,
            pixelBuffer: pixelBuffer
        )
    }
}

private actor FakeWindowProvider: WindowDiscoveryProvider {
    private var currentWindows: [CaptureWindow]
    private var currentPermission: CapturePermissionState
    private var refreshOverride: CaptureWindowRefreshResult?
    private var restartWindows: [CaptureWindow]?

    init(windows: [CaptureWindow], permission: CapturePermissionState) {
        self.currentWindows = windows
        self.currentPermission = permission
    }

    func permissionState() async -> CapturePermissionState {
        currentPermission
    }

    func requestPermission() async -> CapturePermissionState {
        currentPermission
    }

    func discoverWindows() async throws -> [CaptureWindow] {
        guard currentPermission == .authorized else {
            throw CaptureCoreError.permissionDenied
        }
        return currentWindows
    }

    func refreshSelectedWindow(
        _ expectedWindow: CaptureWindow
    ) async throws -> CaptureWindowRefreshResult {
        guard currentPermission == .authorized else {
            throw CaptureCoreError.permissionDenied
        }
        if let refreshOverride { return refreshOverride }
        return Self.resolve(expectedWindow, from: currentWindows)
    }

    func resolveSelectedWindowForCapture(
        _ expectedWindow: CaptureWindow
    ) async throws -> CaptureWindowRefreshResult {
        guard currentPermission == .authorized else {
            throw CaptureCoreError.permissionDenied
        }
        return Self.resolve(expectedWindow, from: restartWindows ?? currentWindows)
    }

    func setPermission(_ permission: CapturePermissionState) {
        currentPermission = permission
    }

    func setWindows(_ windows: [CaptureWindow]) {
        currentWindows = windows
    }

    func setRefreshOverride(_ result: CaptureWindowRefreshResult?) {
        refreshOverride = result
    }

    func setRestartWindows(_ windows: [CaptureWindow]?) {
        restartWindows = windows
    }

    private static func resolve(
        _ expectedWindow: CaptureWindow,
        from windows: [CaptureWindow]
    ) -> CaptureWindowRefreshResult {
        let matchingID = windows.filter { $0.identifier == expectedWindow.identifier }
        guard !matchingID.isEmpty else { return .unavailable }
        guard let sameOwner = matchingID.first(where: { $0.hasSameOwner(as: expectedWindow) }) else {
            return .ownerMismatch
        }
        guard sameOwner.eligible else { return .unavailable }
        return .available(sameOwner)
    }
}

private final class FakeCaptureEngineFactory: WindowCaptureEngineFactory, @unchecked Sendable {
    private let engine: any WindowCaptureEngine

    init(engine: any WindowCaptureEngine) {
        self.engine = engine
    }

    func makeEngine() -> any WindowCaptureEngine {
        engine
    }
}

private final class FakeCaptureEngine: WindowCaptureEngine, @unchecked Sendable {
    let frames: AsyncThrowingStream<CapturedFrame, Error>

    private let continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation
    private let lock = NSLock()
    private var started = false
    private var startedWindowValue: CaptureWindow?
    private var stopCountValue = 0

    init() {
        let output = AsyncThrowingStream<CapturedFrame, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        self.frames = output.stream
        self.continuation = output.continuation
    }

    func start(window: CaptureWindow, generation: UInt64) async throws {
        lock.withLock {
            started = true
            startedWindowValue = window
        }
    }

    func stop() async {
        lock.withLock {
            stopCountValue += 1
        }
        continuation.finish()
    }

    func failFrames(_ error: Error) {
        continuation.finish(throwing: error)
    }

    func emit(_ frame: CapturedFrame) {
        _ = continuation.yield(frame)
    }

    func wasStarted() -> Bool {
        lock.withLock { started }
    }

    func startedWindow() -> CaptureWindow? {
        lock.withLock { startedWindowValue }
    }

    func stopCount() -> Int {
        lock.withLock { stopCountValue }
    }
}

private actor TestAsyncSignal {
    private var signaled: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(signaled: Bool = false) {
        self.signaled = signaled
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !signaled else { return }
        signaled = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

private final class SequencedCaptureEngineFactory: WindowCaptureEngineFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var engines: [GatedCaptureEngine]

    init(engines: [GatedCaptureEngine]) {
        self.engines = engines
    }

    func makeEngine() -> any WindowCaptureEngine {
        lock.withLock { engines.removeFirst() }
    }
}

private final class GatedCaptureEngine: WindowCaptureEngine, @unchecked Sendable {
    let frames: AsyncThrowingStream<CapturedFrame, Error>

    private let continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation
    private let startGate: TestAsyncSignal
    private let startEntered = TestAsyncSignal()
    private let stopGate: TestAsyncSignal
    private let stopEntered = TestAsyncSignal()
    private let stopped = TestAsyncSignal()
    private let startFailure: CaptureCoreError?
    private let lock = NSLock()
    private var stopCountValue = 0
    private var startCountValue = 0
    private var startedWindowsValue: [CaptureWindow] = []

    init(
        startGate: TestAsyncSignal,
        startFailure: CaptureCoreError? = nil,
        stopGate: TestAsyncSignal? = nil
    ) {
        let output = AsyncThrowingStream<CapturedFrame, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.frames = output.stream
        self.continuation = output.continuation
        self.startGate = startGate
        self.startFailure = startFailure
        self.stopGate = stopGate ?? TestAsyncSignal(signaled: true)
    }

    func start(window: CaptureWindow, generation: UInt64) async throws {
        _ = generation
        lock.withLock {
            startCountValue += 1
            startedWindowsValue.append(window)
        }
        await startEntered.signal()
        await startGate.wait()
        if let startFailure {
            throw startFailure
        }
    }

    func stop() async {
        lock.withLock {
            stopCountValue += 1
        }
        await stopEntered.signal()
        await stopGate.wait()
        continuation.finish()
        await stopped.signal()
    }

    func failFrames(_ error: Error) {
        continuation.finish(throwing: error)
    }

    func emit(_ frame: CapturedFrame) {
        _ = continuation.yield(frame)
    }

    func finishFrames() {
        continuation.finish()
    }

    func waitUntilStartEntered() async {
        await startEntered.wait()
    }

    func waitUntilStopEntered() async {
        await stopEntered.wait()
    }

    func waitUntilStopped() async {
        await stopped.wait()
    }

    func stopCount() -> Int {
        lock.withLock { stopCountValue }
    }

    func startCount() -> Int {
        lock.withLock { startCountValue }
    }

    func startedWindow() -> CaptureWindow? {
        lock.withLock { startedWindowsValue.last }
    }
}
