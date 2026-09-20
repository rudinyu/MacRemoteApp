import AppKit

/// The Viewer-side first-pairing prompt. The operator must enter the code
/// shown by the Host; the value is used once for this challenge and is not
/// retained or logged.
@MainActor
enum ViewerPairingPrompt {
    static func requestConfirmation(
        confirmationCode: String,
        parentWindow: NSWindow?,
        expiresAt: Date
    ) async -> String? {
        _ = NSApplication.shared
        NSApplication.shared.activate(ignoringOtherApps: true)

        let controller = PromptController(
            confirmationCode: confirmationCode,
            parentWindow: parentWindow
        )
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
        private let ownsParentWindow: Bool
        private var continuation: CheckedContinuation<String?, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var finished = false
        private var cancellationRequested = false
        private let codeField: NSTextField

        init(confirmationCode: String, parentWindow: NSWindow?) {
            let resolvedParent: NSWindow
            if let parentWindow {
                resolvedParent = parentWindow
                ownsParentWindow = false
            } else {
                let fallback = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                fallback.title = "MacRemoteApp Viewer"
                fallback.isReleasedWhenClosed = false
                fallback.alphaValue = 0.01
                fallback.center()
                resolvedParent = fallback
                ownsParentWindow = true
            }
            self.parentWindow = resolvedParent

            let codeField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            codeField.placeholderString = "XXXX-XXXX-XXXX"
            codeField.alignment = .center
            codeField.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
            self.codeField = codeField

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Pair with this MacRemoteApp Host?"
            alert.informativeText = "Enter the code displayed on the Host, then confirm both codes match:\n\n\(confirmationCode)"
            alert.accessoryView = codeField
            alert.addButton(withTitle: "Confirm")
            alert.addButton(withTitle: "Deny")
            self.alert = alert
        }

        func present(expiresAt: Date) async -> String? {
            guard !Task.isCancelled, !cancellationRequested else { return nil }
            return await withCheckedContinuation { continuation in
                guard !cancellationRequested else {
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
                if ownsParentWindow {
                    parentWindow.makeKeyAndOrderFront(nil)
                }
                alert.beginSheetModal(for: parentWindow) { [weak self] response in
                    guard response == .alertFirstButtonReturn else {
                        self?.finish(nil)
                        return
                    }
                    let code = self?.codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.finish(code)
                }
                armTimeout(expiresAt: expiresAt)
            }
        }

        func cancel() {
            cancellationRequested = true
            guard !finished, continuation != nil else { return }
            parentWindow.endSheet(alert.window, returnCode: .abort)
            finish(nil)
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

        private func finish(_ code: String?) {
            guard !finished else { return }
            finished = true
            timeoutTask?.cancel()
            timeoutTask = nil
            let continuation = continuation
            self.continuation = nil
            if ownsParentWindow {
                parentWindow.orderOut(nil)
                parentWindow.close()
            }
            continuation?.resume(returning: code)
        }
    }
}
