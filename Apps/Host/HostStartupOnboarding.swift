import AppKit

/// The Host's first-run setup prompts. TCC does not expose a reliable
/// preflight API for Local Network, so the app records only that the operator
/// has been shown the setup step. The actual network result is still decided
/// by Network.framework and handled fail-closed by HostRuntime.
@MainActor
enum HostStartupOnboarding {
    private static let localNetworkSetupReviewedKey =
        "MacRemoteApp.Host.localNetworkSetupReviewed"

    static func requestScreenRecording() -> Bool {
        activateApplication()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Set up MacRemoteApp Host"
        alert.informativeText =
            "MacRemoteApp Host needs Screen Recording access to list and capture the one window you choose to share. Click Continue, then allow the macOS permission request for MacRemoteApp Host."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            openScreenRecordingSettings()
            return false
        default:
            return false
        }
    }

    static func shouldRequestLocalNetwork(
        defaults: UserDefaults = .standard
    ) -> Bool {
        !defaults.bool(forKey: localNetworkSetupReviewedKey)
    }

    static func requestLocalNetwork(
        defaults: UserDefaults = .standard
    ) -> Bool {
        activateApplication()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow MacRemoteApp Host on the Local Network"
        alert.informativeText =
            "MacRemoteApp Host must advertise itself so the paired Viewer can find it on your trusted LAN. Click Continue, then allow the macOS Local Network request if it appears."
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

    static func markLocalNetworkReady(
        defaults: UserDefaults = .standard
    ) {
        defaults.set(true, forKey: localNetworkSetupReviewedKey)
    }

    static func openScreenRecordingSettings() {
        open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        )
    }

    static func openLocalNetworkSettings() {
        open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        )
    }

    private static func activateApplication() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private static func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
