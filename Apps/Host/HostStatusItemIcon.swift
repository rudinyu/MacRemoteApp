import AppKit

@MainActor
enum HostStatusItemIcon {
    private static let logicalSize = NSSize(width: 18, height: 18)

    static func makeTemplateImage() -> NSImage {
        makeImage(tintColor: .black, isTemplate: true)
    }

    static func makePreviewImage(tintColor: NSColor) -> NSImage {
        makeImage(tintColor: tintColor, isTemplate: false)
    }

    private static func makeImage(tintColor: NSColor, isTemplate: Bool) -> NSImage {
        let image = NSImage(size: logicalSize, flipped: false) { destinationRect in
            guard !destinationRect.isEmpty, let context = NSGraphicsContext.current else {
                return false
            }

            context.saveGraphicsState()
            defer { context.restoreGraphicsState() }

            let transform = NSAffineTransform()
            transform.translateX(by: destinationRect.minX, yBy: destinationRect.minY)
            transform.scaleX(
                by: destinationRect.width / logicalSize.width,
                yBy: destinationRect.height / logicalSize.height
            )
            transform.concat()

            drawWindowAndArrow(tintColor: tintColor)
            return true
        }
        image.isTemplate = isTemplate
        image.accessibilityDescription = "MacRemoteApp Host"
        return image
    }

    private static func drawWindowAndArrow(tintColor: NSColor) {
        tintColor.setStroke()

        // Leave the upper-right corner open so the outbound arrow can cross
        // the window edge without the frame running through its shaft.
        let lowerFrame = NSBezierPath()
        lowerFrame.lineWidth = 1.8
        lowerFrame.lineCapStyle = .round
        lowerFrame.lineJoinStyle = .round
        lowerFrame.move(to: NSPoint(x: 2.4, y: 5.0))
        lowerFrame.appendArc(
            withCenter: NSPoint(x: 4.2, y: 5.0),
            radius: 1.8,
            startAngle: 180,
            endAngle: 270,
            clockwise: false
        )
        lowerFrame.line(to: NSPoint(x: 12.2, y: 3.2))
        lowerFrame.appendArc(
            withCenter: NSPoint(x: 12.2, y: 5.0),
            radius: 1.8,
            startAngle: -90,
            endAngle: 0,
            clockwise: false
        )
        lowerFrame.line(to: NSPoint(x: 14.0, y: 8.9))
        lowerFrame.stroke()

        let upperLeftFrame = NSBezierPath()
        upperLeftFrame.lineWidth = 1.8
        upperLeftFrame.lineCapStyle = .round
        upperLeftFrame.lineJoinStyle = .round
        upperLeftFrame.move(to: NSPoint(x: 2.4, y: 5.0))
        upperLeftFrame.line(to: NSPoint(x: 2.4, y: 10.8))
        upperLeftFrame.appendArc(
            withCenter: NSPoint(x: 4.2, y: 10.8),
            radius: 1.8,
            startAngle: 180,
            endAngle: 90,
            clockwise: true
        )
        upperLeftFrame.line(to: NSPoint(x: 10.8, y: 12.6))
        upperLeftFrame.stroke()

        let arrow = NSBezierPath()
        arrow.lineWidth = 1.8
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: 6.1, y: 5.2))
        arrow.line(to: NSPoint(x: 15.7, y: 15.0))
        arrow.move(to: NSPoint(x: 11.3, y: 14.9))
        arrow.line(to: NSPoint(x: 15.7, y: 15.0))
        arrow.line(to: NSPoint(x: 15.7, y: 10.6))
        arrow.stroke()
    }
}
