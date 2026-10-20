import CodecCore
import CoreImage
import CoreVideo
import Foundation
import MetalKit

/// Viewer-side presentation only. Session authorization and transport remain
/// owned by TransportCore; this type accepts already-decoded local frames.
@MainActor
final class MetalVideoRenderer: NSObject, MTKViewDelegate {
    private let lock = NSLock()
    private weak var view: MTKView?
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestCaptureTimestampValue: UInt64 = 0
    private var latestStreamGenerationValue: UInt64 = 0
    private var activeLifetimeToken = UUID()
    var onFramePresented: (@MainActor (UUID, UInt64, UInt64, UInt64?, TimeInterval) -> Void)?

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = commandQueue
        self.ciContext = CIContext(mtlDevice: device)
        super.init()
        self.view = view
        view.device = device
        view.delegate = self
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
    }

    @discardableResult
    func submit(
        pixelBuffer: CVPixelBuffer,
        captureTimestamp: UInt64,
        streamGeneration: UInt64,
        lifetimeToken: UUID
    ) -> Bool {
        guard let view else { return false }
        let accepted = lock.withLock {
            guard activeLifetimeToken == lifetimeToken else { return false }
            latestPixelBuffer = pixelBuffer
            latestCaptureTimestampValue = captureTimestamp
            latestStreamGenerationValue = streamGeneration
            return true
        }
        guard accepted else { return false }
        view.setNeedsDisplay(view.bounds)
        return true
    }

    func reset(lifetimeToken: UUID) {
        lock.withLock {
            activeLifetimeToken = lifetimeToken
            latestPixelBuffer = nil
            latestCaptureTimestampValue = 0
            latestStreamGenerationValue = 0
        }
        if let view {
            view.setNeedsDisplay(view.bounds)
        }
    }

    func latestCaptureTimestamp() -> UInt64 {
        lock.withLock { latestCaptureTimestampValue }
    }

    func draw(in view: MTKView) {
        let submittedFrame = lock.withLock {
            (
                pixelBuffer: latestPixelBuffer,
                captureTimestamp: latestCaptureTimestampValue,
                streamGeneration: latestStreamGenerationValue,
                lifetimeToken: activeLifetimeToken
            )
        }
        // `currentDrawable` blocks the main thread for up to one second when
        // no drawable is available, which happens while the window is
        // occluded or minimized. Skip those draws; the next submitted frame
        // redraws once the window is visible again.
        guard view.window?.occlusionState.contains(.visible) == true else { return }
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        let drawableSize = drawableSize(for: view)
        guard drawableSize.width.isFinite,
              drawableSize.height.isFinite,
              drawableSize.width > 0,
              drawableSize.height > 0 else {
            return
        }
        let bounds = CGRect(origin: .zero, size: drawableSize)
        let background = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        ).cropped(to: bounds)
        var compositedImage = background
        if let pixelBuffer = submittedFrame.pixelBuffer {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            if image.extent.width.isFinite,
               image.extent.height.isFinite,
               image.extent.width > 0,
               image.extent.height > 0 {
                let targetRect = VideoContentLayout.aspectFitRect(
                    contentWidth: image.extent.width,
                    contentHeight: image.extent.height,
                    in: bounds
                )
                let scale = min(
                    targetRect.width / image.extent.width,
                    targetRect.height / image.extent.height
                )
                let scaledImage = image.transformed(
                    by: CGAffineTransform(scaleX: scale, y: scale)
                )
                let fittedImage = scaledImage.transformed(
                    by: CGAffineTransform(
                        translationX: targetRect.midX - scaledImage.extent.midX,
                        y: targetRect.midY - scaledImage.extent.midY
                    )
                )
                compositedImage = fittedImage.composited(over: background)
            }
        }
        ciContext.render(
            compositedImage,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: bounds,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let sourceTimestamp = submittedFrame.captureTimestamp
        let streamGeneration = submittedFrame.streamGeneration
        let lifetimeToken = submittedFrame.lifetimeToken
        drawable.addPresentedHandler { [weak self] drawable in
            let presentedTime = drawable.presentedTime
            let presentedTimestamp: UInt64?
            if presentedTime.isFinite,
               presentedTime > 0,
               presentedTime <= Double(UInt64.max) / 1_000_000_000 {
                presentedTimestamp = UInt64(presentedTime * 1_000_000_000)
            } else {
                presentedTimestamp = nil
            }
            let presentationUptime = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                guard let self, self.acceptsLifetime(lifetimeToken) else { return }
                self.onFramePresented?(
                    lifetimeToken,
                    streamGeneration,
                    sourceTimestamp,
                    presentedTimestamp,
                    presentationUptime
                )
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        _ = view
        _ = size
    }

    private func drawableSize(for view: MTKView) -> CGSize {
        view.drawableSize
    }

    private func acceptsLifetime(_ token: UUID) -> Bool {
        lock.withLock { activeLifetimeToken == token }
    }
}
