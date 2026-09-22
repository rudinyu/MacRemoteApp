import AppKit

/// Viewer-side first-run setup. Local Network has no public preflight API;
/// the discovery browser is started only after the operator has been shown
/// the macOS consent step, just like the Host's Bonjour publisher.
@MainActor
enum ViewerStartupOnboarding {
    private static let localNetworkSetupReviewedKey =
        "MacRemoteApp.Viewer.localNetworkSetupReviewed"

    static func prepareLocalNetwork(
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !defaults.bool(forKey: localNetworkSetupReviewedKey) else {
            return true
        }

        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Set up MacRemoteApp Viewer"
        alert.informativeText =
            "MacRemoteApp Viewer needs Local Network access to discover a MacRemoteApp Host on your trusted LAN. Click Continue, then allow the macOS Local Network request if it appears."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            openLocalNetworkSettings()
            return true
        default:
            return false
        }
    }

    /// Persist the setup result only after the Bonjour browser has produced an
    /// update. If macOS denied Local Network, the browser can finish without
    /// an update; leaving the flag unset makes the next launch retryable.
    static func markLocalNetworkReady(
        defaults: UserDefaults = .standard
    ) {
        defaults.set(true, forKey: localNetworkSetupReviewedKey)
    }

    static func openLocalNetworkSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
