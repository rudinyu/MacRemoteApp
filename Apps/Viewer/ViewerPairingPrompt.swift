import AppKit

/// The Viewer-side first-pairing consent prompt. The operator compares the
/// independently derived code with the Host, then explicitly accepts or denies.
@MainActor
enum ViewerPairingPrompt {
    static func requestConsent(
        confirmationCode: String,
        peerName: String?,
        parentWindow: NSWindow?,
        expiresAt: Date
    ) async -> Bool {
        _ = NSApplication.shared
        NSApplication.shared.activate(ignoringOtherApps: true)

        let controller = PromptController(
            confirmationCode: confirmationCode,
            peerName: peerName,
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
        private var continuation: CheckedContinuation<Bool, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var finished = false
        private var cancellationRequested = false

        init(confirmationCode: String, peerName: String?, parentWindow: NSWindow?) {
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

            let codeLabel = NSTextField(labelWithString: confirmationCode)
            codeLabel.frame = NSRect(x: 0, y: 0, width: 280, height: 34)
            codeLabel.alignment = .center
            codeLabel.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)

            let alert = NSAlert()
            alert.alertStyle = .informational
            let displayName = Self.safePeerName(peerName, fallback: "MacRemoteApp Host")
            alert.messageText = "Pair with \(displayName)?"
            alert.informativeText = "Compare this code with the code shown on \(displayName). If they match, select Accept to continue pairing."
            alert.accessoryView = codeLabel
            alert.addButton(withTitle: "Accept")
            alert.addButton(withTitle: "Deny")
            self.alert = alert
        }

        private static func safePeerName(_ value: String?, fallback: String) -> String {
            guard let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                return fallback
            }
            return value
        }

        func present(expiresAt: Date) async -> Bool {
            guard !Task.isCancelled, !cancellationRequested else { return false }
            return await withCheckedContinuation { continuation in
                guard !cancellationRequested else {
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
                if ownsParentWindow {
                    parentWindow.makeKeyAndOrderFront(nil)
                }
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
            if ownsParentWindow {
                parentWindow.orderOut(nil)
                parentWindow.close()
            }
            continuation?.resume(returning: accepted)
        }
    }
}
