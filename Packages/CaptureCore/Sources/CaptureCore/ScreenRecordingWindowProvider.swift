@preconcurrency import ScreenCaptureKit
import AppKit
import CoreGraphics
import Foundation

public final class ScreenRecordingWindowProvider: WindowDiscoveryProvider, @unchecked Sendable {
    private let onScreenWindowsOnly: Bool
    private let includesBackgroundWindows: Bool
    private let configuration: CaptureConfiguration
    private let applicationIsRegular: @Sendable (Int32) -> Bool

    /// - Parameter includesBackgroundWindows: Also offer titled windows of
    ///   regular apps that are offscreen (minimized, hidden app, another Space,
    ///   or a full-screen Space). Selecting one reveals and activates it.
    public init(
        onScreenWindowsOnly: Bool = true,
        includesBackgroundWindows: Bool = true,
        configuration: CaptureConfiguration = .default
    ) {
        self.onScreenWindowsOnly = onScreenWindowsOnly
        self.includesBackgroundWindows = includesBackgroundWindows
        self.configuration = configuration
        self.applicationIsRegular = { processIdentifier in
            NSRunningApplication(processIdentifier: pid_t(processIdentifier))?
                .activationPolicy == .regular
        }
    }

    /// Background windows are only discoverable from the full window list.
    private var catalogQueriesOnScreenWindowsOnly: Bool {
        onScreenWindowsOnly && !includesBackgroundWindows
    }

    public func permissionState() async -> CapturePermissionState {
        CGPreflightScreenCaptureAccess() ? .authorized : .denied
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
            onScreenWindowsOnly: catalogQueriesOnScreenWindowsOnly
        )
        let displays = content.displays.map(Self.displayGeometry)
        var ownerRegularity = ApplicationRegularityCache(lookup: applicationIsRegular)
        let evaluated = content.windows.compactMap {
            evaluateWindow(
                $0,
                displays: displays,
                allowInactiveOffscreen: false,
                allowBackgroundCatalogWindow: includesBackgroundWindows,
                ownerRegularity: &ownerRegularity
            ).window
        }
        return CatalogBackgroundWindowReduction.reduce(evaluated).sorted {
            if $0.applicationIdentifier == $1.applicationIdentifier {
                return $0.identifier < $1.identifier
            }
            return $0.applicationIdentifier < $1.applicationIdentifier
        }
    }

    public func refreshSelectedWindow(
        _ expectedWindow: CaptureWindow
    ) async throws -> CaptureWindowRefreshResult {
        guard await permissionState() == .authorized else {
            throw CaptureCoreError.permissionDenied
        }

        return try await resolveSelectedWindow(
            expectedWindow,
            allowInactiveOffscreen: true
        )
    }

    public func resolveSelectedWindowForCapture(
        _ expectedWindow: CaptureWindow
    ) async throws -> CaptureWindowRefreshResult {
        guard await permissionState() == .authorized else {
            throw CaptureCoreError.permissionDenied
        }

        // The app can become inactive after the Viewer selected it and before
        // capture begins. A stream termination can also clear isActive. The
        // Host-authorized descriptor is therefore resolved by ID, bundle ID,
        // PID, layer, and bounds without requiring foreground or stream state.
        return try await resolveSelectedWindow(
            expectedWindow,
            allowInactiveOffscreen: true
        )
    }

    public func selectedWindowStillExists(_ expectedWindow: CaptureWindow) async -> Bool {
        let windowNumber = CGWindowID(truncatingIfNeeded: expectedWindow.identifier)
        guard UInt64(windowNumber) == expectedWindow.identifier,
              let records = CGWindowListCopyWindowInfo(
                  [.optionIncludingWindow],
                  windowNumber
              ) as? [[String: Any]] else {
            return false
        }
        return SelectedWindowExistence.matches(
            records: records,
            expectedWindow: expectedWindow,
            processIsAlive: { kill(pid_t($0), 0) == 0 }
        )
    }

    private func resolveSelectedWindow(
        _ expectedWindow: CaptureWindow,
        allowInactiveOffscreen: Bool
    ) async throws -> CaptureWindowRefreshResult {

        // Recheck the selected target against the full catalog. P6 permits an
        // authenticated, exact process/window target to remain selected while
        // its app is inactive; owner, layer, geometry, and capture-size checks
        // still apply below.
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        )
        let candidates = content.windows.filter {
            UInt64($0.windowID) == expectedWindow.identifier
        }
        guard !candidates.isEmpty else { return .unavailable }
        let matchingOwner = candidates.first(where: {
            $0.owningApplication?.bundleIdentifier == expectedWindow.applicationIdentifier &&
                $0.owningApplication?.processID == expectedWindow.processIdentifier
        })
        guard let candidate = matchingOwner else {
            return .ownerMismatch
        }
        guard allowInactiveOffscreen || SelectedWindowCaptureEligibility.permitsCapture(
            isOnScreen: candidate.isOnScreen,
            isActive: Self.isActive(candidate)
        ) else {
            return .unavailable
        }

        let displays = content.displays.map(Self.displayGeometry)
        guard let window = evaluateWindow(
            candidate,
            displays: displays,
            allowActiveOffscreen: true,
            allowInactiveOffscreen: allowInactiveOffscreen
        ).window else {
            return .unavailable
        }
        if allowInactiveOffscreen,
           !SelectedWindowCaptureTargetEligibility.permits(
               expectedWindow: expectedWindow,
               candidateWindow: window,
               windowLayer: Int(candidate.windowLayer),
               configuration: configuration
           ) {
            return .unavailable
        }
        return .available(window)
    }

#if DEBUG
    /// Debug-only companion to `discoverWindows()` for fixed, shareable
    /// candidate counts. No candidate names or identifiers leave this type.
    public func discoverWindowsWithDiagnostics() async throws -> ScreenRecordingWindowDiscoveryResult {
        guard await permissionState() == .authorized else {
            throw CaptureCoreError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: catalogQueriesOnScreenWindowsOnly
        )
        let displays = content.displays.map(Self.displayGeometry)
        var counts = ScreenRecordingWindowDiscoveryCountAccumulator()
        var windows: [CaptureWindow] = []
        windows.reserveCapacity(content.windows.count)
        var ownerRegularity = ApplicationRegularityCache(lookup: applicationIsRegular)
        for candidate in content.windows {
            let evaluation = evaluateWindow(
                candidate,
                displays: displays,
                allowInactiveOffscreen: false,
                allowBackgroundCatalogWindow: includesBackgroundWindows,
                ownerRegularity: &ownerRegularity
            )
            counts.record(evaluation.rejection)
            if let window = evaluation.window {
                windows.append(window)
            }
        }
        let reduced = CatalogBackgroundWindowReduction.reduce(windows)
        counts.reclassifyAsOffScreen(UInt64(windows.count - reduced.count))
        windows = reduced
        windows.sort {
            if $0.applicationIdentifier == $1.applicationIdentifier {
                return $0.identifier < $1.identifier
            }
            return $0.applicationIdentifier < $1.applicationIdentifier
        }
        return ScreenRecordingWindowDiscoveryResult(
            windows: windows,
            counts: counts.snapshot(candidateCount: UInt64(content.windows.count))
        )
    }
#endif

    private func evaluateWindow(
        _ window: SCWindow,
        displays: [CaptureDisplayGeometry],
        allowActiveOffscreen: Bool = false,
        allowInactiveOffscreen: Bool = false,
        allowBackgroundCatalogWindow: Bool = false
    ) -> WindowCandidateEvaluation {
        var ownerRegularity = ApplicationRegularityCache(lookup: applicationIsRegular)
        return evaluateWindow(
            window,
            displays: displays,
            allowActiveOffscreen: allowActiveOffscreen,
            allowInactiveOffscreen: allowInactiveOffscreen,
            allowBackgroundCatalogWindow: allowBackgroundCatalogWindow,
            ownerRegularity: &ownerRegularity
        )
    }

    private func evaluateWindow(
        _ window: SCWindow,
        displays: [CaptureDisplayGeometry],
        allowActiveOffscreen: Bool = false,
        allowInactiveOffscreen: Bool = false,
        allowBackgroundCatalogWindow: Bool,
        ownerRegularity: inout ApplicationRegularityCache
    ) -> WindowCandidateEvaluation {
        let visible = WindowCandidateVisibility.permits(
            isOnScreen: window.isOnScreen,
            isActive: Self.isActive(window),
            allowsActiveOffscreen: allowActiveOffscreen,
            allowsInactiveOffscreen: allowInactiveOffscreen
        )
        if !visible {
            guard allowBackgroundCatalogWindow,
                  let owner = window.owningApplication,
                  WindowCandidateVisibility.permitsBackgroundCatalogWindow(
                      title: window.title,
                      ownerIsRegularApplication: ownerRegularity.isRegular(owner.processID)
                  ) else {
                return .rejected(.offScreen)
            }
        }
        guard window.windowLayer == 0 else { return .rejected(.nonBaseLayer) }
        guard let application = window.owningApplication else {
            return .rejected(.missingApplication)
        }

        guard Self.isLikelyUserFacingApplication(
            applicationName: application.applicationName,
            bundleIdentifier: application.bundleIdentifier
        ) else {
            return .rejected(.helperApplication)
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
            return .rejected(.invalidWindow)
        }

        let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounds = WindowBounds(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.width,
            height: frame.height
        )
        return .included(
            CaptureWindow(
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
                eligible: true,
                isOnScreen: window.isOnScreen
            )
        )
    }

    private static func isActive(_ window: SCWindow) -> Bool {
        if #available(macOS 13.1, *) {
            return window.isActive
        }
        return false
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

/// Resolves each owning process's activation policy once per discovery. A
/// full window list holds hundreds of offscreen windows from a few dozen
/// processes; repeating the AppKit lookup per window competed with capture
/// and encoding on the Host every second.
struct ApplicationRegularityCache {
    private let lookup: (Int32) -> Bool
    private var resolved: [Int32: Bool] = [:]
    private(set) var lookupCount = 0

    init(lookup: @escaping (Int32) -> Bool) {
        self.lookup = lookup
    }

    mutating func isRegular(_ processIdentifier: Int32) -> Bool {
        if let known = resolved[processIdentifier] { return known }
        lookupCount += 1
        let regular = lookup(processIdentifier)
        resolved[processIdentifier] = regular
        return regular
    }
}

enum WindowCandidateVisibility {
    static func permits(
        isOnScreen: Bool,
        isActive: Bool,
        allowsActiveOffscreen: Bool,
        allowsInactiveOffscreen: Bool
    ) -> Bool {
        isOnScreen || allowsInactiveOffscreen || (allowsActiveOffscreen && isActive)
    }

    /// Whether an offscreen window may be offered in the selection catalog.
    /// Minimized windows, hidden apps, and windows on another Space or in a
    /// full-screen Space are offscreen but are real user documents; an
    /// explicit selection reveals and activates them. Windows of non-regular
    /// (agent/accessory) apps are not offered. A title is not required: some
    /// apps, such as LINE, leave their main window untitled, and
    /// `CatalogBackgroundWindowReduction` keeps at most one entry per app
    /// (preferring titled windows), while selection falls back to the app's
    /// visible window if the listed one cannot be revealed.
    static func permitsBackgroundCatalogWindow(
        title: String?,
        ownerIsRegularApplication: Bool
    ) -> Bool {
        _ = title
        return ownerIsRegularApplication
    }
}

enum WindowCandidateRejection: Sendable {
    case offScreen
    case nonBaseLayer
    case missingApplication
    case helperApplication
    case invalidWindow
}

struct WindowCandidateEvaluation {
    let window: CaptureWindow?
    let rejection: WindowCandidateRejection?

    static func included(_ window: CaptureWindow) -> Self {
        Self(window: window, rejection: nil)
    }

    static func rejected(_ reason: WindowCandidateRejection) -> Self {
        Self(window: nil, rejection: reason)
    }
}

struct ScreenRecordingWindowDiscoveryCountAccumulator {
    private(set) var eligible: UInt64 = 0
    private(set) var offScreen: UInt64 = 0
    private(set) var nonBaseLayer: UInt64 = 0
    private(set) var missingApplication: UInt64 = 0
    private(set) var helperApplication: UInt64 = 0
    private(set) var invalidWindow: UInt64 = 0

    /// Background windows dropped by `CatalogBackgroundWindowReduction` are
    /// reported as offscreen rejections rather than eligible windows.
    mutating func reclassifyAsOffScreen(_ count: UInt64) {
        let moved = min(count, eligible)
        eligible &-= moved
        offScreen &+= moved
    }

    mutating func record(_ rejection: WindowCandidateRejection?) {
        guard let rejection else {
            eligible &+= 1
            return
        }
        switch rejection {
        case .offScreen: offScreen &+= 1
        case .nonBaseLayer: nonBaseLayer &+= 1
        case .missingApplication: missingApplication &+= 1
        case .helperApplication: helperApplication &+= 1
        case .invalidWindow: invalidWindow &+= 1
        }
    }

    func snapshot(candidateCount: UInt64) -> ScreenRecordingWindowDiscoveryCounts {
        ScreenRecordingWindowDiscoveryCounts(
            candidates: candidateCount,
            eligible: eligible,
            offScreen: offScreen,
            nonBaseLayer: nonBaseLayer,
            missingApplication: missingApplication,
            helperApplication: helperApplication,
            invalidWindow: invalidWindow
        )
    }
}
