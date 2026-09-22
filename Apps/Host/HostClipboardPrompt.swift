import AppKit

/// Per-session Host consent for text clipboard synchronization. Clipboard
/// data is never enabled solely because the Viewer advertises the capability.
@MainActor
enum HostClipboardPrompt {
    static func requestConsent(
        expiresAt: Date,
        isSessionActive: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)

        let controller = PromptController(
            expiresAt: expiresAt,
            isSessionActive: isSessionActive
        )
        return await withTaskCancellationHandler(operation: {
            await controller.present()
        }, onCancel: {
            Task { @MainActor in
                controller.cancel()
            }
        })
    }

    @MainActor
    private final class PromptController {
        private let alert: NSAlert
        private let parentWindow: NSWindow
        private let expiresAt: Date
        private let isSessionActive: @Sendable () async -> Bool
        private var continuation: CheckedContinuation<Bool, Never>?
        private var monitorTask: Task<Void, Never>?
        private var finished = false
        private var cancellationRequested = false

        init(
            expiresAt: Date,
            isSessionActive: @escaping @Sendable () async -> Bool
        ) {
            self.expiresAt = expiresAt
            self.isSessionActive = isSessionActive

            let parentWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            parentWindow.title = "MacRemoteApp Host"
            parentWindow.isReleasedWhenClosed = false
            parentWindow.alphaValue = 0.01
            parentWindow.center()
            self.parentWindow = parentWindow

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Enable text clipboard for this session?"
            alert.informativeText = "MacRemoteApp will synchronize text clipboard contents with the paired Viewer while this session is active."
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Keep Disabled")
            self.alert = alert
        }

        func present() async -> Bool {
            guard !Task.isCancelled, !cancellationRequested else { return false }
            return await withCheckedContinuation { continuation in
                guard !cancellationRequested else {
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
                parentWindow.makeKeyAndOrderFront(nil)
                alert.beginSheetModal(for: parentWindow) { [weak self] response in
                    self?.finish(response == .alertFirstButtonReturn)
                }
                monitorTask = Task { @MainActor [weak self] in
                    await self?.monitorSession()
                }
            }
        }

        func cancel() {
            cancellationRequested = true
            guard !finished, continuation != nil else { return }
            parentWindow.endSheet(alert.window, returnCode: .abort)
            finish(false)
        }

        private func monitorSession() async {
            while !Task.isCancelled, !finished {
                if Date() >= expiresAt {
                    finish(false)
                    return
                }
                let active = await isSessionActive()
                if !active {
                    finish(false)
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
            }
        }

        private func finish(_ accepted: Bool) {
            guard !finished else { return }
            finished = true
            monitorTask?.cancel()
            monitorTask = nil
            let continuation = continuation
            self.continuation = nil
            parentWindow.orderOut(nil)
            parentWindow.close()
            continuation?.resume(returning: accepted)
        }
    }
}
