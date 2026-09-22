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
    var onFramePresented: (@MainActor (UInt64, UInt64) -> Void)?

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

    func submit(pixelBuffer: CVPixelBuffer, captureTimestamp: UInt64) {
        lock.withLock {
            latestPixelBuffer = pixelBuffer
            latestCaptureTimestampValue = captureTimestamp
        }
        if let view {
            view.setNeedsDisplay(view.bounds)
        }
    }

    func latestCaptureTimestamp() -> UInt64 {
        lock.withLock { latestCaptureTimestampValue }
    }

    func draw(in view: MTKView) {
        let pixelBuffer = lock.withLock { latestPixelBuffer }
        guard let pixelBuffer,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let bounds = CGRect(origin: .zero, size: drawableSize(for: view))
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
        let background = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        ).cropped(to: bounds)
        let compositedImage = fittedImage.composited(over: background)
        ciContext.render(
            compositedImage,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: bounds,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let sourceTimestamp = lock.withLock { latestCaptureTimestampValue }
        drawable.addPresentedHandler { [weak self] drawable in
            let presentedTime = drawable.presentedTime
            guard presentedTime.isFinite, presentedTime > 0,
                  presentedTime <= Double(UInt64.max) / 1_000_000_000 else {
                return
            }
            let presentedTimestamp = UInt64(presentedTime * 1_000_000_000)
            Task { @MainActor [weak self] in
                self?.onFramePresented?(sourceTimestamp, presentedTimestamp)
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
}
