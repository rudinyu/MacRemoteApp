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
        let displays = content.displays.map(Self.displayGeometry)
        return content.windows.compactMap { makeWindow($0, displays: displays) }.sorted {
            if $0.applicationIdentifier == $1.applicationIdentifier {
                return $0.identifier < $1.identifier
            }
            return $0.applicationIdentifier < $1.applicationIdentifier
        }
    }

    private func makeWindow(_ window: SCWindow, displays: [CaptureDisplayGeometry]) -> CaptureWindow? {
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
        let bounds = WindowBounds(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.width,
            height: frame.height
        )
        return CaptureWindow(
            identifier: UInt64(window.windowID),
            applicationIdentifier: application.bundleIdentifier,
            applicationName: application.applicationName,
            title: title?.isEmpty == false ? title : nil,
            bounds: bounds,
            backingScaleFactor: CaptureBackingScale.backingScaleFactor(
                forWindow: bounds,
                displays: displays
            ),
            processIdentifier: application.processID,
            eligible: true
        )
    }

    /// `SCDisplay.frame` and `SCWindow.frame` share the global point space.
    /// The current display mode's pixel/point ratio is the backing scale; an
    /// unavailable mode yields 1 through `CaptureBackingScale.sanitized`.
    private static func displayGeometry(_ display: SCDisplay) -> CaptureDisplayGeometry {
        let frame = display.frame
        var scale = 1.0
        if let mode = CGDisplayCopyDisplayMode(display.displayID), mode.width > 0 {
            scale = Double(mode.pixelWidth) / Double(mode.width)
        }
        return CaptureDisplayGeometry(
            bounds: WindowBounds(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height
            ),
            backingScaleFactor: scale
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
