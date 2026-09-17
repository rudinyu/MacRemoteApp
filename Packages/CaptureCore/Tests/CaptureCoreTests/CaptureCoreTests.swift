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

    func testFailedCaptureSessionCannotRestartOnFinishedOutputStream() async throws {
        let window = makeWindow(identifier: 11)
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

        await provider.setWindows([window])
        do {
            try await session.start(windowIdentifier: window.identifier)
            XCTFail("a failed session must not restart its finished frame stream")
        } catch CaptureCoreError.sessionFailed(.windowUnavailable) {
            // Expected.
        }
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
    private let engine: FakeCaptureEngine

    init(engine: FakeCaptureEngine) {
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
