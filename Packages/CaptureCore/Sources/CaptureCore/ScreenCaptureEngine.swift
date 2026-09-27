@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Foundation

public final class ScreenCaptureEngine: NSObject, WindowCaptureEngine, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let frames: AsyncThrowingStream<CapturedFrame, Error>

    private let continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation
    private let configuration: CaptureConfiguration
    private let sampleQueue: DispatchQueue
    private let lock = NSLock()
    private var stream: SCStream?
    private var windowIdentifier: UInt64?
    private var generation: UInt64 = 0
    private var isStopping = false

    public init(
        configuration: CaptureConfiguration = .default,
        sampleQueue: DispatchQueue = DispatchQueue(label: "MacRemoteApp.ScreenCapture", qos: .userInitiated)
    ) {
        let output = AsyncThrowingStream<CapturedFrame, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, configuration.outputBufferCount))
        )
        self.frames = output.stream
        self.continuation = output.continuation
        self.configuration = configuration
        self.sampleQueue = sampleQueue
        super.init()
    }

    public func start(window: CaptureWindow, generation: UInt64) async throws {
        let alreadyStarted = lock.withLock { stream != nil }
        guard !alreadyStarted else {
            throw CaptureCoreError.alreadyCapturing
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        guard let shareableWindow = content.windows.first(where: {
            UInt64($0.windowID) == window.identifier &&
                $0.owningApplication?.bundleIdentifier == window.applicationIdentifier &&
                $0.owningApplication?.processID == window.processIdentifier &&
                $0.isOnScreen
        }) else {
            throw CaptureCoreError.windowUnavailable
        }

        let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
        let streamConfiguration = SCStreamConfiguration()
        let outputDimensions = configuration.outputDimensions(for: window)
        streamConfiguration.width = Int(outputDimensions.width)
        streamConfiguration.height = Int(outputDimensions.height)
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(1, configuration.frameRate))
        )
        streamConfiguration.queueDepth = configuration.queueDepth
        streamConfiguration.pixelFormat = configuration.pixelFormat
        if configuration.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            // Tag the YCbCr conversion explicitly so the H.264 VUI and the
            // Viewer's color conversion agree.
            streamConfiguration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
        streamConfiguration.showsCursor = false

        let newStream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        lock.withLock {
            self.stream = newStream
            self.windowIdentifier = window.identifier
            self.generation = generation
            self.isStopping = false
        }
        do {
            try await newStream.startCapture()
        } catch {
            lock.withLock {
                self.stream = nil
                self.windowIdentifier = nil
            }
            throw CaptureCoreError.captureFailed(String(describing: error))
        }
    }

    public func stop() async {
        let activeStream: SCStream? = lock.withLock {
            isStopping = true
            let activeStream = stream
            stream = nil
            windowIdentifier = nil
            return activeStream
        }
        if let activeStream {
            try? await activeStream.stopCapture()
        }
        continuation.finish()
    }

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }
        let metadata: (UInt64, UInt64, UInt64)? = lock.withLock {
            guard let windowIdentifier, !isStopping else { return nil }
            // Capture latency is measured from the Host's monotonic arrival
            // boundary. The CMSampleBuffer PTS remains useful for media
            // pacing, but it is not assumed to be a cross-host wall/uptime
            // clock value.
            return (
                windowIdentifier,
                generation,
                DispatchTime.now().uptimeNanoseconds
            )
        }
        guard let (windowIdentifier, generation, timestamp) = metadata else { return }
        let frame = CapturedFrame(
            windowIdentifier: windowIdentifier,
            generation: generation,
            captureTimestamp: timestamp,
            presentationTimestamp: timestampNanoseconds(sampleBuffer.presentationTimeStamp),
            width: UInt32(CVPixelBufferGetWidth(pixelBuffer)),
            height: UInt32(CVPixelBufferGetHeight(pixelBuffer)),
            pixelBuffer: pixelBuffer
        )
        _ = continuation.yield(frame)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let shouldReport = lock.withLock {
            let shouldReport = !isStopping
            self.stream = nil
            self.windowIdentifier = nil
            return shouldReport
        }
        if shouldReport {
            continuation.finish(throwing: CaptureCoreError.captureFailed(String(describing: error)))
        } else {
            continuation.finish()
        }
    }
}

public struct SystemWindowCaptureEngineFactory: WindowCaptureEngineFactory {
    public let configuration: CaptureConfiguration

    public init(configuration: CaptureConfiguration = .default) {
        self.configuration = configuration
    }

    public func makeEngine() -> any WindowCaptureEngine {
        ScreenCaptureEngine(configuration: configuration)
    }
}
