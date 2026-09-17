@preconcurrency import ScreenCaptureKit
import CoreGraphics
import Foundation

public final class ScreenRecordingWindowProvider: WindowDiscoveryProvider, @unchecked Sendable {
    private let onScreenWindowsOnly: Bool

    public init(onScreenWindowsOnly: Bool = true) {
        self.onScreenWindowsOnly = onScreenWindowsOnly
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
        return content.windows.compactMap(Self.makeWindow).sorted {
            if $0.applicationIdentifier == $1.applicationIdentifier {
                return $0.identifier < $1.identifier
            }
            return $0.applicationIdentifier < $1.applicationIdentifier
        }
    }

    private static func makeWindow(_ window: SCWindow) -> CaptureWindow? {
        guard window.isOnScreen,
              window.windowLayer == 0,
              let application = window.owningApplication else {
            return nil
        }

        let frame = window.frame
        guard frame.width > 0, frame.height > 0,
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
}
