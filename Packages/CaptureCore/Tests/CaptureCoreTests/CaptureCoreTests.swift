import CaptureCore
import AppKit
import CoreVideo
import Foundation
import XCTest

final class CaptureCoreTests: XCTestCase {
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

    private func makeWindow(identifier: UInt64) -> CaptureWindow {
        CaptureWindow(
            identifier: identifier,
            applicationIdentifier: "com.example.test",
            applicationName: "Test App",
            title: "Test Window",
            bounds: WindowBounds(x: 0, y: 0, width: 640, height: 480),
            processIdentifier: 123,
            eligible: true
        )
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

    func setPermission(_ permission: CapturePermissionState) {
        currentPermission = permission
    }

    func setWindows(_ windows: [CaptureWindow]) {
        currentWindows = windows
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
    private let stopped = TestAsyncSignal()
    private let startFailure: CaptureCoreError?
    private let lock = NSLock()
    private var stopCountValue = 0

    init(startGate: TestAsyncSignal, startFailure: CaptureCoreError? = nil) {
        let output = AsyncThrowingStream<CapturedFrame, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.frames = output.stream
        self.continuation = output.continuation
        self.startGate = startGate
        self.startFailure = startFailure
    }

    func start(window: CaptureWindow, generation: UInt64) async throws {
        _ = window
        _ = generation
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

    func waitUntilStopped() async {
        await stopped.wait()
    }

    func stopCount() -> Int {
        lock.withLock { stopCountValue }
    }
}
