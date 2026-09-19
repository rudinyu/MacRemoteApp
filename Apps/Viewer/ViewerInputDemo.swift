#if DEBUG
import AppKit
import InputCore

@MainActor
final class ViewerInputDemo: NSObject, NSWindowDelegate, NSApplicationDelegate {
    private let window: NSWindow
    private let statusLabel: NSTextField
    private let surface: ViewerInputSurface

    override init() {
        let frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        self.surface = ViewerInputSurface(
            frame: frame,
            contentRect: InputContentRect(originX: 0, originY: 0, width: 960, height: 540),
            readiness: .awaitingAuthentication
        )
        self.statusLabel = NSTextField(labelWithString: InputReadiness.awaitingAuthentication.label)
        self.window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        let contentView = NSView(frame: frame)
        surface.frame = NSRect(x: 0, y: 28, width: frame.width, height: frame.height - 28)
        statusLabel.frame = NSRect(x: 12, y: 4, width: frame.width - 24, height: 20)
        statusLabel.alignment = .left
        statusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(surface)
        contentView.addSubview(statusLabel)
        window.contentView = contentView
        window.title = "MacRemoteApp Viewer — M5 input surface"
        window.delegate = self
        window.isReleasedWhenClosed = false
        surface.onInputEvent = { [weak self] _ in
            self?.statusLabel.stringValue = "Input ready — event captured"
        }
        surface.onInputRejected = { [weak self] error in
            self?.statusLabel.stringValue = error.description
        }
    }

    func run() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        application.run()
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }
}
#endif
