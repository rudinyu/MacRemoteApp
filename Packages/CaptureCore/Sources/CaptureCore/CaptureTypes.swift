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

    fileprivate func intersectionArea(with other: WindowBounds) -> Double {
        let overlapWidth = min(x + width, other.x + other.width) - max(x, other.x)
        let overlapHeight = min(y + height, other.y + other.height) - max(y, other.y)
        guard overlapWidth.isFinite, overlapHeight.isFinite,
              overlapWidth > 0, overlapHeight > 0 else {
            return 0
        }
        return overlapWidth * overlapHeight
    }
}

/// A Host display's global point-space frame and its backing pixels-per-point
/// scale (1 for a standard display, 2 for Retina).
public struct CaptureDisplayGeometry: Equatable, Sendable {
    public let bounds: WindowBounds
    public let backingScaleFactor: Double

    public init(bounds: WindowBounds, backingScaleFactor: Double) {
        self.bounds = bounds
        self.backingScaleFactor = backingScaleFactor
    }
}

/// Backing-scale policy for selected-window capture. Window bounds are global
/// points; capture output is sized in pixels. The scale is sampled from the
/// display that holds the largest part of the window when the catalog is
/// read, so one capture generation keeps one output size.
public enum CaptureBackingScale {
    public static let supportedRange: ClosedRange<Double> = 1...4

    /// Unknown or invalid scale values fall back to 1, which can only lower
    /// capture detail; they never enlarge the output beyond the point size.
    public static func sanitized(_ scale: Double) -> Double {
        guard scale.isFinite, scale > 0 else { return 1 }
        return min(supportedRange.upperBound, max(supportedRange.lowerBound, scale))
    }

    /// Returns the scale of the display with the largest overlap with the
    /// window. Equal overlaps prefer the higher scale; no overlap yields 1.
    public static func backingScaleFactor(
        forWindow bounds: WindowBounds,
        displays: [CaptureDisplayGeometry]
    ) -> Double {
        var bestArea = 0.0
        var bestScale = 1.0
        for display in displays {
            let area = bounds.intersectionArea(with: display.bounds)
            let scale = sanitized(display.backingScaleFactor)
            if area > bestArea || (area == bestArea && area > 0 && scale > bestScale) {
                bestArea = area
                bestScale = scale
            }
        }
        return bestScale
    }
}

/// Encoded capture size in pixels for one capture generation.
public struct CaptureOutputDimensions: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32

    public init(width: UInt32, height: UInt32) {
        self.width = width
        self.height = height
    }
}

public struct CaptureWindow: Equatable, Sendable {
    public let identifier: UInt64
    public let applicationIdentifier: String
    public let applicationName: String?
    public let title: String?
    /// Global point-space frame used for Host input mapping.
    public let bounds: WindowBounds
    /// Pixels per point of the display holding most of the window when the
    /// catalog was read. Used only to size capture output.
    public let backingScaleFactor: Double
    public let processIdentifier: Int32
    public let eligible: Bool

    public init(
        identifier: UInt64,
        applicationIdentifier: String,
        applicationName: String? = nil,
        title: String? = nil,
        bounds: WindowBounds,
        backingScaleFactor: Double = 1,
        processIdentifier: Int32,
        eligible: Bool
    ) {
        self.identifier = identifier
        self.applicationIdentifier = applicationIdentifier
        self.applicationName = applicationName
        self.title = title
        self.bounds = bounds
        self.backingScaleFactor = CaptureBackingScale.sanitized(backingScaleFactor)
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
    /// Pixel size the engine was configured with for the current generation.
    /// It stays fixed while the selected window's catalog entry is refreshed,
    /// so the Host encoder and StreamConfig match the delivered frames.
    public let outputDimensions: CaptureOutputDimensions?

    public init(
        state: CaptureSessionState,
        selectedWindow: CaptureWindow?,
        generation: UInt64,
        permission: CapturePermissionState,
        outputDimensions: CaptureOutputDimensions? = nil
    ) {
        self.state = state
        self.selectedWindow = selectedWindow
        self.generation = generation
        self.permission = permission
        self.outputDimensions = outputDimensions
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

/// A reusable capture-session stream.
///
/// Each capture generation gets its own underlying `AsyncThrowingStream`.
/// Swift terminates an `AsyncThrowingStream` permanently when the task
/// awaiting it is cancelled, and the Host cancels its capture task whenever it
/// stops or replaces the video pipeline. A single shared stream would therefore
/// deliver no frames after the first pipeline restart. The channel replaces
/// the stream on every `start`, so a cancelled consumer only ends its own
/// generation. The generation gate still discards frames buffered by a
/// previous selection.
///
/// An iterator binds to the current generation on its first `next()`. If that
/// generation is replaced while the iterator is waiting, it follows the
/// replacement; if the generation is stopped or fails without a replacement,
/// the iterator ends (a failure is thrown). The channel closes only when its
/// owning WindowCaptureSession is deallocated.
public struct CapturedFrameStream: AsyncSequence, Sendable {
    public typealias Element = CapturedFrame
    public typealias Failure = Error

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let channel: CapturedFrameChannel
        private let generationGate: CapturedFrameGenerationGate
        private var iterator: AsyncThrowingStream<CapturedFrame, Error>.AsyncIterator?
        private var boundStreamID: UInt64?

        fileprivate init(
            channel: CapturedFrameChannel,
            generationGate: CapturedFrameGenerationGate
        ) {
            self.channel = channel
            self.generationGate = generationGate
        }

        public mutating func next() async throws -> CapturedFrame? {
            while true {
                if iterator == nil {
                    let current = channel.current()
                    iterator = current.stream.makeAsyncIterator()
                    boundStreamID = current.id
                }
                if let frame = try await iterator?.next() {
                    if generationGate.accepts(frame.generation) {
                        return frame
                    }
                    continue
                }
                // The bound generation ended. Follow a replacement that was
                // installed while this iterator was waiting; otherwise end.
                guard !Task.isCancelled,
                      let boundStreamID,
                      channel.hasReplaced(streamID: boundStreamID) else {
                    return nil
                }
                iterator = nil
            }
        }
    }

    private let channel: CapturedFrameChannel
    private let generationGate: CapturedFrameGenerationGate

    init(
        channel: CapturedFrameChannel,
        generationGate: CapturedFrameGenerationGate
    ) {
        self.channel = channel
        self.generationGate = generationGate
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(channel: channel, generationGate: generationGate)
    }
}

/// Owns the per-generation frame stream behind `CapturedFrameStream`.
final class CapturedFrameChannel: @unchecked Sendable {
    typealias Stream = AsyncThrowingStream<CapturedFrame, Error>

    private let lock = NSLock()
    private let bufferCount: Int
    private var stream: Stream
    private var continuation: Stream.Continuation
    private var streamID: UInt64 = 0
    private var isClosed = false

    init(bufferCount: Int) {
        self.bufferCount = max(1, bufferCount)
        (stream, continuation) = Self.makeStream(bufferCount: self.bufferCount)
    }

    func current() -> (stream: Stream, id: UInt64) {
        lock.withLock { (stream, streamID) }
    }

    func hasReplaced(streamID candidate: UInt64) -> Bool {
        lock.withLock { !isClosed && streamID != candidate }
    }

    /// Installs a fresh stream for a new capture generation and ends the
    /// previous one.
    func replace() {
        let previous: Stream.Continuation? = lock.withLock {
            guard !isClosed else { return nil }
            let previous = continuation
            (stream, continuation) = Self.makeStream(bufferCount: bufferCount)
            streamID &+= 1
            return previous
        }
        previous?.finish()
    }

    @discardableResult
    func yield(_ frame: CapturedFrame) -> Stream.Continuation.YieldResult {
        let target = lock.withLock { continuation }
        return target.yield(frame)
    }

    /// Ends the current generation without installing a replacement.
    func finishCurrent(throwing error: Error? = nil) {
        let target = lock.withLock { continuation }
        target.finish(throwing: error)
    }

    func close() {
        let target: Stream.Continuation = lock.withLock {
            isClosed = true
            return continuation
        }
        target.finish()
    }

    private static func makeStream(bufferCount: Int) -> (Stream, Stream.Continuation) {
        let output = Stream.makeStream(bufferingPolicy: .bufferingNewest(bufferCount))
        return (output.stream, output.continuation)
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
    public let minimumWindowWidth: UInt32
    public let minimumWindowHeight: UInt32
    public let frameRate: UInt16
    public let queueDepth: Int
    public let monitorIntervalNanoseconds: UInt64
    public let outputBufferCount: Int
    /// Capture pixel format. The default is 4:2:0 bi-planar video range, the
    /// encoder's native input, so VideoToolbox does not convert every frame
    /// from BGRA on the Host.
    public let pixelFormat: OSType

    public init(
        maximumWidth: UInt32 = 1920,
        maximumHeight: UInt32 = 1080,
        minimumWindowWidth: UInt32 = 160,
        minimumWindowHeight: UInt32 = 80,
        frameRate: UInt16 = 60,
        queueDepth: Int = 3,
        monitorIntervalNanoseconds: UInt64 = 1_000_000_000,
        outputBufferCount: Int = 3,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ) {
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.minimumWindowWidth = minimumWindowWidth
        self.minimumWindowHeight = minimumWindowHeight
        self.frameRate = frameRate
        self.queueDepth = queueDepth
        self.monitorIntervalNanoseconds = monitorIntervalNanoseconds
        self.outputBufferCount = outputBufferCount
        self.pixelFormat = pixelFormat
    }

    /// Reject macOS helper/service surfaces that are technically on-screen
    /// but too small to be a useful user-facing application window.
    public func acceptsWindowSize(_ bounds: WindowBounds) -> Bool {
        bounds.width >= Double(minimumWindowWidth) &&
            bounds.height >= Double(minimumWindowHeight)
    }

    /// Capture output size for a selected window: its point bounds times its
    /// backing scale, downscaled with preserved aspect ratio to fit
    /// `maximumWidth` x `maximumHeight` pixels. Never upscales.
    public func outputDimensions(for window: CaptureWindow) -> CaptureOutputDimensions {
        outputDimensions(for: window.bounds, backingScaleFactor: window.backingScaleFactor)
    }

    public func outputDimensions(
        for bounds: WindowBounds,
        backingScaleFactor: Double = 1
    ) -> CaptureOutputDimensions {
        let scale = CaptureBackingScale.sanitized(backingScaleFactor)
        func pixels(_ points: Double) -> Double {
            let value = (points * scale).rounded()
            return value.isFinite ? max(1.0, value) : 1.0
        }
        let sourceWidth = pixels(bounds.width)
        let sourceHeight = pixels(bounds.height)
        let maximumWidth = Double(max(1, self.maximumWidth))
        let maximumHeight = Double(max(1, self.maximumHeight))
        let fit = min(1.0, maximumWidth / sourceWidth, maximumHeight / sourceHeight)
        let width = min(maximumWidth, max(1.0, (sourceWidth * fit).rounded()))
        let height = min(maximumHeight, max(1.0, (sourceHeight * fit).rounded()))
        return CaptureOutputDimensions(width: UInt32(width), height: UInt32(height))
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
