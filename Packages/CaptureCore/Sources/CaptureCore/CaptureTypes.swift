import CoreMedia
import CoreVideo
import Foundation

public enum CapturePermissionState: String, Equatable, Sendable {
    case authorized
    case denied
}

public struct WindowBounds: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var aspectRatio: Double? {
        guard width > 0, height > 0 else { return nil }
        return width / height
    }
}

public struct CaptureWindow: Equatable, Sendable {
    public let identifier: UInt64
    public let applicationIdentifier: String
    public let applicationName: String?
    public let title: String?
    public let bounds: WindowBounds
    public let processIdentifier: Int32
    public let eligible: Bool

    public init(
        identifier: UInt64,
        applicationIdentifier: String,
        applicationName: String? = nil,
        title: String? = nil,
        bounds: WindowBounds,
        processIdentifier: Int32,
        eligible: Bool
    ) {
        self.identifier = identifier
        self.applicationIdentifier = applicationIdentifier
        self.applicationName = applicationName
        self.title = title
        self.bounds = bounds
        self.processIdentifier = processIdentifier
        self.eligible = eligible
    }

    /// Window IDs can be reused by WindowServer. These fields identify the
    /// owning application/process and therefore must be checked together with
    /// the numeric window ID when refreshing a capture session.
    public func hasSameOwner(as other: CaptureWindow) -> Bool {
        identifier == other.identifier &&
            applicationIdentifier == other.applicationIdentifier &&
            processIdentifier == other.processIdentifier
    }
}

public enum CaptureFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case permissionDenied
    case windowUnavailable
    case captureFailed(String)
    case providerFailed(String)
    case cancelled

    public var description: String {
        switch self {
        case .permissionDenied: return "Screen Recording permission is unavailable"
        case .windowUnavailable: return "the selected window is unavailable"
        case let .captureFailed(detail): return "capture failed: \(detail)"
        case let .providerFailed(detail): return "window provider failed: \(detail)"
        case .cancelled: return "capture was cancelled"
        }
    }
}

public enum CaptureCoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case permissionDenied
    case windowUnavailable
    case alreadyCapturing
    case notCapturing
    case invalidWindow
    case captureFailed(String)
    case sessionFailed(CaptureFailure)
    case providerFailed(String)
    case cancelled

    public var description: String {
        switch self {
        case .permissionDenied: return "Screen Recording permission is unavailable"
        case .windowUnavailable: return "the selected window is unavailable"
        case .alreadyCapturing: return "a capture session is already active"
        case .notCapturing: return "no capture session is active"
        case .invalidWindow: return "the selected window is not eligible"
        case let .captureFailed(detail): return "capture failed: \(detail)"
        case let .sessionFailed(failure): return "capture session is failed: \(failure)"
        case let .providerFailed(detail): return "window provider failed: \(detail)"
        case .cancelled: return "capture was cancelled"
        }
    }
}

public enum CaptureSessionState: Equatable, Sendable {
    case idle
    case starting(windowIdentifier: UInt64, generation: UInt64)
    case capturing(windowIdentifier: UInt64, generation: UInt64)
    case stopping
    case stopped(CaptureFailure?)
    case failed(CaptureFailure)
}

public struct CaptureSessionSnapshot: Equatable, Sendable {
    public let state: CaptureSessionState
    public let selectedWindow: CaptureWindow?
    public let generation: UInt64
    public let permission: CapturePermissionState

    public init(
        state: CaptureSessionState,
        selectedWindow: CaptureWindow?,
        generation: UInt64,
        permission: CapturePermissionState
    ) {
        self.state = state
        self.selectedWindow = selectedWindow
        self.generation = generation
        self.permission = permission
    }
}

/// Raw Host capture output. CodecCore owns later encoding; CaptureCore only
/// guarantees the selected-window/generation metadata and bounded delivery.
public struct CapturedFrame: @unchecked Sendable {
    public let windowIdentifier: UInt64
    public let generation: UInt64
    public let captureTimestamp: UInt64
    public let presentationTimestamp: UInt64
    public let width: UInt32
    public let height: UInt32
    public let pixelBuffer: CVPixelBuffer

    public init(
        windowIdentifier: UInt64,
        generation: UInt64,
        captureTimestamp: UInt64,
        presentationTimestamp: UInt64,
        width: UInt32,
        height: UInt32,
        pixelBuffer: CVPixelBuffer
    ) {
        self.windowIdentifier = windowIdentifier
        self.generation = generation
        self.captureTimestamp = captureTimestamp
        self.presentationTimestamp = presentationTimestamp
        self.width = width
        self.height = height
        self.pixelBuffer = pixelBuffer
    }
}

/// A reusable capture-session stream. The underlying stream remains alive when
/// a selection stops, while the generation gate discards frames buffered by a
/// previous selection before they reach the next consumer.
public struct CapturedFrameStream: AsyncSequence, Sendable {
    public typealias Element = CapturedFrame
    public typealias Failure = Error

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var iterator: AsyncThrowingStream<CapturedFrame, Error>.AsyncIterator
        private let generationGate: CapturedFrameGenerationGate

        fileprivate init(
            iterator: AsyncThrowingStream<CapturedFrame, Error>.AsyncIterator,
            generationGate: CapturedFrameGenerationGate
        ) {
            self.iterator = iterator
            self.generationGate = generationGate
        }

        public mutating func next() async throws -> CapturedFrame? {
            while let frame = try await iterator.next() {
                if generationGate.accepts(frame.generation) {
                    return frame
                }
            }
            return nil
        }
    }

    private let stream: AsyncThrowingStream<CapturedFrame, Error>
    private let generationGate: CapturedFrameGenerationGate

    init(
        stream: AsyncThrowingStream<CapturedFrame, Error>,
        generationGate: CapturedFrameGenerationGate
    ) {
        self.stream = stream
        self.generationGate = generationGate
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            iterator: stream.makeAsyncIterator(),
            generationGate: generationGate
        )
    }
}

final class CapturedFrameGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var minimumGeneration: UInt64 = 0

    func advance(to generation: UInt64) {
        lock.withLock {
            minimumGeneration = max(minimumGeneration, generation)
        }
    }

    func accepts(_ generation: UInt64) -> Bool {
        lock.withLock { generation >= minimumGeneration }
    }
}

public protocol WindowDiscoveryProvider: Sendable {
    func permissionState() async -> CapturePermissionState
    func requestPermission() async -> CapturePermissionState
    func discoverWindows() async throws -> [CaptureWindow]
}

public protocol WindowCaptureEngine: AnyObject, Sendable {
    var frames: AsyncThrowingStream<CapturedFrame, Error> { get }

    func start(window: CaptureWindow, generation: UInt64) async throws
    func stop() async
}

public protocol WindowCaptureEngineFactory: Sendable {
    func makeEngine() -> any WindowCaptureEngine
}

public struct CaptureConfiguration: Equatable, Sendable {
    public static let `default` = CaptureConfiguration()

    public let maximumWidth: UInt32
    public let maximumHeight: UInt32
    public let frameRate: UInt16
    public let queueDepth: Int
    public let monitorIntervalNanoseconds: UInt64
    public let outputBufferCount: Int

    public init(
        maximumWidth: UInt32 = 1920,
        maximumHeight: UInt32 = 1080,
        frameRate: UInt16 = 60,
        queueDepth: Int = 3,
        monitorIntervalNanoseconds: UInt64 = 1_000_000_000,
        outputBufferCount: Int = 3
    ) {
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.frameRate = frameRate
        self.queueDepth = queueDepth
        self.monitorIntervalNanoseconds = monitorIntervalNanoseconds
        self.outputBufferCount = outputBufferCount
    }

    public func outputDimensions(for bounds: WindowBounds) -> (width: UInt32, height: UInt32) {
        let sourceWidth = max(1.0, bounds.width.rounded())
        let sourceHeight = max(1.0, bounds.height.rounded())
        let maximumWidth = Double(max(1, self.maximumWidth))
        let maximumHeight = Double(max(1, self.maximumHeight))
        let scale = min(1.0, maximumWidth / sourceWidth, maximumHeight / sourceHeight)
        let width = min(maximumWidth, max(1.0, (sourceWidth * scale).rounded()))
        let height = min(maximumHeight, max(1.0, (sourceHeight * scale).rounded()))
        return (UInt32(width), UInt32(height))
    }
}

func timestampNanoseconds(_ time: CMTime) -> UInt64 {
    guard time.isValid else { return DispatchTime.now().uptimeNanoseconds }
    let seconds = CMTimeGetSeconds(time)
    guard seconds.isFinite, seconds >= 0 else {
        return DispatchTime.now().uptimeNanoseconds
    }
    return UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
}
