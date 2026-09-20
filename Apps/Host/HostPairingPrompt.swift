import AppKit

/// The Host-side first-pairing consent prompt. The code is intentionally
/// displayed only in the local UI; it is never written to diagnostics.
@MainActor
enum HostPairingPrompt {
    static func requestConsent(
        confirmationCode: String,
        expiresAt: Date
    ) async -> Bool {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)

        let controller = PromptController(confirmationCode: confirmationCode)
        return await withTaskCancellationHandler(operation: {
            await controller.present(expiresAt: expiresAt)
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
        private var continuation: CheckedContinuation<Bool, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var finished = false
        private var cancellationRequested = false

        init(confirmationCode: String) {
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
            alert.messageText = "Pair this MacRemoteApp Viewer?"
            alert.informativeText = "Compare this code with the code shown on the Viewer before allowing the connection:\n\n\(confirmationCode)"
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            self.alert = alert
        }

        func present(expiresAt: Date) async -> Bool {
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
                armTimeout(expiresAt: expiresAt)
            }
        }

        func cancel() {
            cancellationRequested = true
            guard !finished, continuation != nil else { return }
            parentWindow.endSheet(alert.window, returnCode: .abort)
            finish(false)
        }

        private func armTimeout(expiresAt: Date) {
            let nanoseconds = UInt64(
                max(
                    0,
                    min(
                        expiresAt.timeIntervalSinceNow * 1_000_000_000,
                        Double(UInt64.max)
                    )
                )
            )
            timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                self?.cancel()
            }
        }

        private func finish(_ accepted: Bool) {
            guard !finished else { return }
            finished = true
            timeoutTask?.cancel()
            timeoutTask = nil
            let continuation = continuation
            self.continuation = nil
            parentWindow.orderOut(nil)
            parentWindow.close()
            continuation?.resume(returning: accepted)
        }
    }
}
