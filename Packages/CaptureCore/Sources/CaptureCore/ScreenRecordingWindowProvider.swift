@preconcurrency import ScreenCaptureKit
import CoreGraphics
import Foundation

public final class ScreenRecordingWindowProvider: WindowDiscoveryProvider, @unchecked Sendable {
    private let onScreenWindowsOnly: Bool
    private let configuration: CaptureConfiguration

    public init(
        onScreenWindowsOnly: Bool = true,
        configuration: CaptureConfiguration = .default
    ) {
        self.onScreenWindowsOnly = onScreenWindowsOnly
        self.configuration = configuration
    }

    public func permissionState() async -> CapturePermissionState {
        await MainActor.run {
            CGPreflightScreenCaptureAccess() ? .authorized : .denied
        }
    }

    public func requestPermission() async -> CapturePermissionState {
        await MainActor.run {
            CGRequestScreenCaptureAccess() ? .authorized : .denied
        }
    }

    public func discoverWindows() async throws -> [CaptureWindow] {
        guard await permissionState() == .authorized else {
            throw CaptureCoreError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: onScreenWindowsOnly
        )
        return content.windows.compactMap(makeWindow).sorted {
            if $0.applicationIdentifier == $1.applicationIdentifier {
                return $0.identifier < $1.identifier
            }
            return $0.applicationIdentifier < $1.applicationIdentifier
        }
    }

    private func makeWindow(_ window: SCWindow) -> CaptureWindow? {
        guard window.isOnScreen,
              window.windowLayer == 0,
              let application = window.owningApplication else {
            return nil
        }

        guard Self.isLikelyUserFacingApplication(
            applicationName: application.applicationName,
            bundleIdentifier: application.bundleIdentifier
        ) else {
            return nil
        }

        let frame = window.frame
        guard frame.width > 0, frame.height > 0,
              configuration.acceptsWindowSize(
                  WindowBounds(
                      x: frame.origin.x,
                      y: frame.origin.y,
                      width: frame.width,
                      height: frame.height
                  )
              ),
              !application.bundleIdentifier.isEmpty else {
            return nil
        }

        let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CaptureWindow(
            identifier: UInt64(window.windowID),
            applicationIdentifier: application.bundleIdentifier,
            applicationName: application.applicationName,
            title: title?.isEmpty == false ? title : nil,
            bounds: WindowBounds(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height
            ),
            processIdentifier: application.processID,
            eligible: true
        )
    }

    /// ScreenCaptureKit exposes helper, renderer, and service processes as
    /// shareable windows too. They are implementation surfaces rather than
    /// user-facing app windows and can otherwise make the picker select a
    /// black or near-empty surface (for example LINE's 1x33 SeekPreview
    /// window). Keep the rule conservative so the main LINE or ChatGPT app
    /// remains selectable while common subprocesses are hidden.
    private static func isLikelyUserFacingApplication(
        applicationName: String?,
        bundleIdentifier: String
    ) -> Bool {
        let name = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let identifier = bundleIdentifier.lowercased()
        let helperMarkers = [
            " helper",
            "helper (",
            "renderer",
            "gpu process",
            "crashpad",
            "seekpreview",
            "previewservice",
            "mediaservice",
            "audioservice",
            "videoservice",
            "windowmanager",
            "windowserver",
            ".xpc",
            ".service",
            " service"
        ]
        return !helperMarkers.contains {
            name.contains($0) || identifier.contains($0)
        }
    }
}
