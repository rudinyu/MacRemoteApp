import AppKit
import Foundation

@MainActor
private final class HostControlPromptSession {
    private let alert: NSAlert

    init(peerName: String?, peerIdentifier: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow Viewer to control apps on this Mac?"
        let name = peerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Paired Viewer"
        let fingerprint = String(peerIdentifier.prefix(16))
        alert.informativeText = "\(safeName) (identity \(fingerprint)…) is requesting process-level mouse and keyboard control. This one-time grant is saved for this authenticated Viewer. The selected app will not be brought to the front; exact-window targeting is not guaranteed when an app has multiple windows. You can pause or revoke control from the Host menu at any time."
        alert.addButton(withTitle: "Allow Control")
        alert.addButton(withTitle: "Not Now")
        self.alert = alert
    }

    func run() -> Bool {
        guard !Task.isCancelled else { return false }
        return alert.runModal() == .alertFirstButtonReturn
    }

    func cancel() {
        guard NSApplication.shared.modalWindow === alert.window else { return }
        NSApplication.shared.abortModal()
        alert.window.close()
    }
}

enum HostControlPrompt {
    static func requestConsent(peerName: String?, peerIdentifier: String) async -> Bool {
        let prompt = await MainActor.run {
            HostControlPromptSession(
                peerName: peerName,
                peerIdentifier: peerIdentifier
            )
        }
        return await withTaskCancellationHandler {
            await MainActor.run { prompt.run() }
        } onCancel: {
            Task { @MainActor in prompt.cancel() }
        }
    }
}
