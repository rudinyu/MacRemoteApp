@preconcurrency import ApplicationServices
@preconcurrency import CoreGraphics
import AppKit
import Foundation

/// A single wall-clock budget shared by all AX messages used to inspect secure
/// input during one Host input-context snapshot. AX request errors, including
/// timeout, are handled as unknown by the caller.
struct AccessibilityMessagingDeadline: Sendable {
    let deadlineUptimeNanoseconds: UInt64

    func remainingTimeoutSeconds(nowUptimeNanoseconds: UInt64) -> Float? {
        guard nowUptimeNanoseconds < deadlineUptimeNanoseconds else { return nil }
        let remainingNanoseconds = deadlineUptimeNanoseconds - nowUptimeNanoseconds
        return Float(Double(remainingNanoseconds) / 1_000_000_000)
    }

    func setMessagingTimeout(
        on element: AXUIElement,
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        guard let remainingTimeout = remainingTimeoutSeconds(
            nowUptimeNanoseconds: nowUptimeNanoseconds
        ) else {
            return false
        }
        return AXUIElementSetMessagingTimeout(element, remainingTimeout) == .success
    }
}

/// Applies a temporary timeout through the system-wide AX element, then
/// immediately restores the process-wide default before returning. Passing
/// zero to AXUIElementSetMessagingTimeout resets the system-wide timeout.
func withTemporarySystemWideMessagingTimeout<Result>(
    timeoutSeconds: Float,
    setTimeout: (Float) -> AXError,
    operation: () -> Result
) -> Result? {
    guard setTimeout(timeoutSeconds) == .success else {
        _ = setTimeout(0)
        return nil
    }

    let result = operation()
    guard setTimeout(0) == .success else { return nil }
    return result
}

/// The real macOS context source. It checks the PostEvent permission required
/// for Quartz event posting, the exact live WindowServer target, foreground
/// ordering, and the console/lock state for every snapshot. Accessibility is
/// an optional local signal for secure-input detection; it is not the base
/// event-posting gate. This provider never attempts to activate a background
/// window.
public struct CoreGraphicsAccessibilityContextProvider: HostInputContextProvider, @unchecked Sendable {
    public typealias SessionStateProvider = @Sendable () -> HostInputSessionState
    public typealias SelectionProvider = @Sendable () -> HostInputWindowSelection?
    public typealias SecureInputStateProvider = @Sendable () -> HostInputSecureInputState
    public typealias TargetSecureInputStateProvider = @Sendable (Int32) -> HostInputSecureInputState

    private let sessionStateProvider: SessionStateProvider
    private let selectionProvider: SelectionProvider
    private let secureInputStateProvider: SecureInputStateProvider?
    private let targetSecureInputStateProvider: TargetSecureInputStateProvider?
    private static let secureInputProbeBudgetNanoseconds: UInt64 = 100_000_000

    /// The public macOS API does not expose a general secure-input status
    /// query. The default is therefore `.unknown`. A Host UI/adapter may
    /// provide a trustworthy, local safe-app signal for the selected test
    /// application; it must never infer safety from Viewer input or a remote
    /// message.
    public init(
        sessionStateProvider: @escaping SessionStateProvider,
        selectionProvider: @escaping SelectionProvider,
        secureInputStateProvider: SecureInputStateProvider? = nil,
        targetSecureInputStateProvider: TargetSecureInputStateProvider? = nil
    ) {
        self.sessionStateProvider = sessionStateProvider
        self.selectionProvider = selectionProvider
        self.secureInputStateProvider = secureInputStateProvider
        self.targetSecureInputStateProvider = targetSecureInputStateProvider
    }

    /// Best-effort local secure-input signal. macOS does not expose a single
    /// public global secure-input flag, so the provider checks the focused
    /// Accessibility element for the secure-text-field role. This is a local
    /// host fact only; it never uses Viewer input as evidence. When the
    /// optional Accessibility signal is unavailable, foreground and window
    /// identity checks still protect the base PostEvent path.
    public static func detectSecureInputState() -> HostInputSecureInputState {
        guard AXIsProcessTrusted() else { return .unknown }

        let system = AXUIElementCreateSystemWide()
        return focusedSecureInputState(
            in: system,
            expectedProcessIdentifier: nil,
            deadline: makeSecureInputProbeDeadline()
        )
    }

    /// Inspects the selected process itself instead of inferring its safety
    /// from the unrelated foreground application. A missing or mismatched AX
    /// focus owner is unknown and cannot authorize P6 background input.
    public static func detectTargetSecureInputState(
        processIdentifier: Int32
    ) -> HostInputSecureInputState {
        guard processIdentifier > 0,
              AXIsProcessTrusted() else { return .unknown }
        let application = AXUIElementCreateApplication(pid_t(processIdentifier))
        return focusedSecureInputState(
            in: application,
            expectedProcessIdentifier: processIdentifier,
            deadline: makeSecureInputProbeDeadline()
        )
    }

    /// Deterministic classifier for the target application's focused element.
    /// Tests exercise secure roles, missing AX facts, and PID mismatches without
    /// querying or controlling the desktop.
    public static func classifyTargetSecureInputState(
        expectedProcessIdentifier: Int32,
        focusedElementProcessIdentifier: Int32?,
        role: String?,
        subrole: String?,
        subroleInspectionFailed: Bool = false
    ) -> HostInputSecureInputState {
        guard expectedProcessIdentifier > 0,
              focusedElementProcessIdentifier == expectedProcessIdentifier,
              let role else { return .unknown }
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return .active
        }
        return subroleInspectionFailed ? .unknown : .inactive
    }

    public static func classifyBackgroundSecureInput(
        global: HostInputSecureInputState,
        target: HostInputSecureInputState
    ) -> HostInputFocusState {
        switch global {
        case .active:
            return .secureInput
        case .unknown:
            return .unknown
        case .inactive:
            switch target {
            case .active: return .secureInput
            case .inactive: return .backgroundEligible
            case .unknown: return .unknown
            }
        }
    }

    static func foregroundProcessTargetFocusState(
        foregroundFocus: HostInputFocusState,
        globalSecureInputState: HostInputSecureInputState
    ) -> HostInputFocusState {
        switch globalSecureInputState {
        case .active:
            return .secureInput
        case .inactive, .unknown:
            // Foreground P6 uses the same optional global secure-input signal
            // as the established foreground path. Target-process AX is only
            // required to classify inactive-target cleanup safety.
            return foregroundFocus
        }
    }

    /// Classifies the P6 path from the selected process's live WindowServer
    /// identity and process-specific safety facts. This intentionally does
    /// not depend on ordered foreground-window classification: a separate
    /// foreground signal remains responsible for the legacy path.
    static func backgroundProcessTargetFocusState(
        for selection: HostInputWindowSelection,
        targetWindows: [WindowServerWindow],
        frontmostProcessIdentifier: Int32?,
        consoleState: HostInputFocusState?,
        globalSecureInputState: HostInputSecureInputState,
        targetSecureInputState: HostInputSecureInputState
    ) -> HostInputFocusState {
        if let consoleState { return consoleState }
        guard let frontmostProcessIdentifier,
              frontmostProcessIdentifier != selection.processIdentifier else {
            return .unknown
        }
        guard let selected = liveTarget(for: selection, windows: targetWindows),
              selected.layer == 0,
              selected.isRegularApplication,
              selected.bounds.isValid else {
            return .windowUnavailable
        }
        return classifyBackgroundSecureInput(
            global: globalSecureInputState,
            target: targetSecureInputState
        )
    }

    private static func focusedSecureInputState(
        in root: AXUIElement,
        expectedProcessIdentifier: Int32?,
        deadline: AccessibilityMessagingDeadline
    ) -> HostInputSecureInputState {
        var focusedValue: CFTypeRef?
        let focusedElementQueryStatus: AXError
        if expectedProcessIdentifier == nil {
            guard let timeout = deadline.remainingTimeoutSeconds(
                nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            ),
            let queryStatus = withTemporarySystemWideMessagingTimeout(
                timeoutSeconds: timeout,
                setTimeout: { AXUIElementSetMessagingTimeout(root, $0) },
                operation: {
                    AXUIElementCopyAttributeValue(
                        root,
                        kAXFocusedUIElementAttribute as CFString,
                        &focusedValue
                    )
                }
            ) else {
                return .unknown
            }
            focusedElementQueryStatus = queryStatus
        } else {
            guard deadline.setMessagingTimeout(on: root) else { return .unknown }
            focusedElementQueryStatus = AXUIElementCopyAttributeValue(
                root,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue
            )
        }

        guard focusedElementQueryStatus == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .unknown
        }
        let focused = unsafeDowncast(focusedValue, to: AXUIElement.self)

        if let expectedProcessIdentifier {
            var focusedProcessIdentifier: pid_t = 0
            guard deadline.setMessagingTimeout(on: focused),
                  AXUIElementGetPid(focused, &focusedProcessIdentifier) == .success,
                  Int32(focusedProcessIdentifier) == expectedProcessIdentifier else {
                return .unknown
            }
        }

        var roleValue: CFTypeRef?
        guard deadline.setMessagingTimeout(on: focused),
              AXUIElementCopyAttributeValue(
            focused,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
        let role = roleValue as? String else {
            return .unknown
        }

        var subroleValue: CFTypeRef?
        let subrole: String?
        let subroleInspectionFailed: Bool
        guard deadline.setMessagingTimeout(on: focused) else { return .unknown }
        let subroleStatus = AXUIElementCopyAttributeValue(
            focused,
            kAXSubroleAttribute as CFString,
            &subroleValue
        )
        if subroleStatus == .success {
            guard let value = subroleValue as? String else { return .unknown }
            subrole = value
            subroleInspectionFailed = false
        } else if subroleStatus == .attributeUnsupported || subroleStatus == .noValue {
            subrole = nil
            subroleInspectionFailed = false
        } else {
            subrole = nil
            subroleInspectionFailed = true
        }
        if let expectedProcessIdentifier {
            return classifyTargetSecureInputState(
                expectedProcessIdentifier: expectedProcessIdentifier,
                focusedElementProcessIdentifier: expectedProcessIdentifier,
                role: role,
                subrole: subrole,
                subroleInspectionFailed: subroleInspectionFailed
            )
        }
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return .active
        }
        return subroleInspectionFailed ? .unknown : .inactive
    }

    /// Returns the current local permission state without presenting a
    /// consent prompt. Hosts use this to keep remote input capabilities in
    /// sync with macOS TCC state.
    public static func currentPermissionState() -> HostInputPermissionState {
        permissionState()
    }

    /// Requests the local PostEvent permission required for event posting and
    /// optionally asks for Accessibility so secure-input/AX enhancements can
    /// work. The request is intentionally initiated by the signed Host bundle
    /// so TCC records the decision against MacRemoteApp, not a launching
    /// shell.
    @discardableResult
    public static func requestPermission() -> HostInputPermissionState {
        _ = CGRequestPostEventAccess()
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        return permissionState()
    }

    public func currentContext() -> HostInputContext {
        let session = sessionStateProvider()
        guard let selection = selectionProvider() else {
            return HostInputContext(
                sessionAuthorized: session.authorized,
                authorizedWindowGeneration: session.authorizedWindowGeneration,
                selectedWindow: nil,
                currentWindowIdentifier: nil,
                currentProcessIdentifier: nil,
                currentWindowBounds: nil,
                permission: Self.permissionState(),
                focus: .windowUnavailable,
                mouseInputEnabled: session.mouseInputEnabled,
                keyboardInputEnabled: session.keyboardInputEnabled,
                processTargetingAuthorized: session.processTargetingAuthorized
            )
        }

        let windows = Self.onScreenApplicationWindows()
        let targetWindows = Self.targetWindowSnapshot(
            windowIdentifier: selection.windowIdentifier,
            windows: windows
        )
        let selectedTarget = Self.liveTarget(for: selection, windows: targetWindows)
        return HostInputContext(
            sessionAuthorized: session.authorized,
            authorizedWindowGeneration: session.authorizedWindowGeneration,
            selectedWindow: selection,
            currentWindowIdentifier: selectedTarget?.windowIdentifier,
            currentProcessIdentifier: selectedTarget?.processIdentifier,
            currentApplicationIdentifier: selectedTarget?.applicationIdentifier,
            currentWindowBounds: currentWindowBounds(for: selection, windows: targetWindows),
            permission: Self.permissionState(),
            focus: focusState(
                for: selection,
                windows: windows,
                targetWindows: targetWindows,
                allowsBackgroundTargeting: session.processTargetingAuthorized
            ),
            mouseInputEnabled: session.mouseInputEnabled,
            keyboardInputEnabled: session.keyboardInputEnabled,
            processTargetingAuthorized: session.processTargetingAuthorized
        )
    }

    public func currentReleaseContext(for target: HostInputTarget) -> HostInputContext? {
        let session = sessionStateProvider()
        let windows = Self.onScreenApplicationWindows()
        let targetWindows = Self.targetWindowSnapshot(
            windowIdentifier: target.windowIdentifier,
            windows: windows
        )
        guard let liveWindow = Self.liveTarget(for: target, windows: targetWindows) else {
            return nil
        }

        // CaptureCore may have published a replacement selection by the time
        // cleanup runs. Reconstruct the admitted target from the live
        // WindowServer record instead of pretending the new selection owns
        // the old pressed state.
        let selection = HostInputWindowSelection(
            windowIdentifier: liveWindow.windowIdentifier,
            processIdentifier: liveWindow.processIdentifier,
            applicationIdentifier: target.applicationIdentifier,
            generation: target.windowGeneration,
            bounds: liveWindow.bounds
        )
        return HostInputContext(
            sessionAuthorized: session.authorized,
            authorizedWindowGeneration: session.authorizedWindowGeneration,
            selectedWindow: selection,
            currentWindowIdentifier: liveWindow.windowIdentifier,
            currentProcessIdentifier: liveWindow.processIdentifier,
            currentApplicationIdentifier: liveWindow.applicationIdentifier,
            currentWindowBounds: liveWindow.bounds,
            permission: Self.permissionState(),
            focus: focusState(
                for: selection,
                windows: windows,
                targetWindows: targetWindows,
                allowsBackgroundTargeting: session.processTargetingAuthorized
            ),
            mouseInputEnabled: session.mouseInputEnabled,
            keyboardInputEnabled: session.keyboardInputEnabled,
            processTargetingAuthorized: session.processTargetingAuthorized
        )
    }

    private static func permissionState() -> HostInputPermissionState {
        guard CGPreflightPostEventAccess() else {
            return .missing
        }
        return .authorized
    }

    private func focusState(
        for selection: HostInputWindowSelection,
        windows: [WindowServerWindow],
        targetWindows: [WindowServerWindow],
        allowsBackgroundTargeting: Bool = false
    ) -> HostInputFocusState {
        let deadline = Self.makeSecureInputProbeDeadline()
        let globalSecureInputState = secureInputStateProvider?() ?? Self.detectSecureInputState(
            deadline: deadline
        )
        switch globalSecureInputState {
        case .active:
            return .secureInput
        case .unknown:
            // Accessibility is optional for base Quartz event posting. Keep
            // using the independent foreground/window checks when the
            // best-effort secure-input signal cannot be read.
            break
        case .inactive:
            break
        }
        if let consoleState = consoleFocusState() {
            return consoleState
        }

        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focus = Self.selectedWindowFocusState(
            for: selection,
            windows: windows,
            targetWindows: targetWindows,
            frontmostProcessIdentifier: frontmostProcessIdentifier
        )
        if allowsBackgroundTargeting {
            if frontmostProcessIdentifier != selection.processIdentifier {
                let targetSecureInputState = targetSecureInputStateProvider?(selection.processIdentifier) ??
                    Self.detectTargetSecureInputState(
                        processIdentifier: selection.processIdentifier,
                        deadline: deadline
                    )
                // P6 retains its strict process-safe secure-input check, but
                // an inactive target is cleanup/readiness information only.
                // Ordinary input still requires the selected process to be
                // frontmost.
                return Self.backgroundProcessTargetFocusState(
                    for: selection,
                    targetWindows: targetWindows,
                    frontmostProcessIdentifier: frontmostProcessIdentifier,
                    consoleState: nil,
                    globalSecureInputState: globalSecureInputState,
                    targetSecureInputState: targetSecureInputState
                )
            }
            return Self.foregroundProcessTargetFocusState(
                foregroundFocus: focus,
                globalSecureInputState: globalSecureInputState
            )
        }
        return focus
    }

    private static func makeSecureInputProbeDeadline() -> AccessibilityMessagingDeadline {
        let now = DispatchTime.now().uptimeNanoseconds
        return AccessibilityMessagingDeadline(
            deadlineUptimeNanoseconds: now &+ secureInputProbeBudgetNanoseconds
        )
    }

    private static func detectSecureInputState(
        deadline: AccessibilityMessagingDeadline
    ) -> HostInputSecureInputState {
        guard AXIsProcessTrusted() else { return .unknown }
        return focusedSecureInputState(
            in: AXUIElementCreateSystemWide(),
            expectedProcessIdentifier: nil,
            deadline: deadline
        )
    }

    private static func detectTargetSecureInputState(
        processIdentifier: Int32,
        deadline: AccessibilityMessagingDeadline
    ) -> HostInputSecureInputState {
        guard processIdentifier > 0,
              AXIsProcessTrusted() else { return .unknown }
        return focusedSecureInputState(
            in: AXUIElementCreateApplication(pid_t(processIdentifier)),
            expectedProcessIdentifier: processIdentifier,
            deadline: deadline
        )
    }

    static func liveTarget(
        for selection: HostInputWindowSelection,
        windows: [WindowServerWindow]
    ) -> WindowServerWindow? {
        liveTarget(
            windowIdentifier: selection.windowIdentifier,
            processIdentifier: selection.processIdentifier,
            applicationIdentifier: selection.applicationIdentifier,
            windows: windows
        )
    }

    static func liveTarget(
        for target: HostInputTarget,
        windows: [WindowServerWindow]
    ) -> WindowServerWindow? {
        liveTarget(
            windowIdentifier: target.windowIdentifier,
            processIdentifier: target.processIdentifier,
            applicationIdentifier: target.applicationIdentifier,
            windows: windows
        )
    }

    private static func liveTarget(
        windowIdentifier: UInt64,
        processIdentifier: Int32,
        applicationIdentifier: String,
        windows: [WindowServerWindow]
    ) -> WindowServerWindow? {
        windows.first(where: {
            $0.windowIdentifier == windowIdentifier &&
                $0.processIdentifier == processIdentifier &&
                $0.applicationIdentifier == applicationIdentifier
        })
    }

    /// Classifies ordered onscreen focus facts plus an exact target snapshot.
    /// An unresolved layer-0 window ahead of an onscreen selection blocks
    /// focus when its bounds overlap. For an offscreen target, any unresolved
    /// overlapping onscreen window blocks because no z-order comparison is
    /// available. The selected target must remain an exact regular,
    /// layer-0 WindowServer record.
    static func selectedWindowFocusState(
        for selection: HostInputWindowSelection,
        windows: [WindowServerWindow],
        targetWindows: [WindowServerWindow]? = nil,
        frontmostProcessIdentifier: Int32?
    ) -> HostInputFocusState {
        let targetCatalog = targetWindows ?? windows
        guard let selected = liveTarget(for: selection, windows: targetCatalog),
              selected.layer == 0,
              selected.isRegularApplication else {
            return .windowUnavailable
        }
        guard selected.bounds.isValid else { return .windowUnavailable }

        let selectedOnScreenIndex = windows.firstIndex(where: {
            $0.windowIdentifier == selection.windowIdentifier &&
                $0.processIdentifier == selection.processIdentifier &&
                $0.applicationIdentifier == selection.applicationIdentifier &&
                $0.layer == 0 && $0.isRegularApplication
        })

        // Nonzero-layer surfaces are outside this classifier. A layer value
        // we cannot read remains conservative because it may be a layer-0
        // overlay. An unresolved owner at layer 0 blocks only when it may
        // cover the selected target.
        if let selectedOnScreenIndex {
            if windows[..<selectedOnScreenIndex].contains(where: { window in
                (window.layer == 0 || window.layer == nil) &&
                    window.applicationIdentifier == nil &&
                    Self.mayOverlap(window.bounds, selected.bounds)
            }) {
                return .unknown
            }
        } else if windows.contains(where: { window in
            (window.layer == 0 || window.layer == nil) &&
                window.applicationIdentifier == nil &&
                Self.mayOverlap(window.bounds, selected.bounds)
        }) {
            // The target is absent from the ordered onscreen list, so there is
            // no safe z-order comparison. Any unresolved onscreen surface
            // overlapping its live WindowServer bounds remains a blocker.
            return .unknown
        }

        guard let frontmostProcessIdentifier else { return .unknown }
        guard selectedOnScreenIndex != nil else { return .notForeground }
        guard frontmostProcessIdentifier == selection.processIdentifier else {
            return .notForeground
        }
        guard let frontmostApplication = Self.frontmostApplicationWindow(in: windows),
              frontmostApplication.processIdentifier == selection.processIdentifier,
              frontmostApplication.applicationIdentifier == selection.applicationIdentifier else {
            return .notForeground
        }
        return .eligible
    }

    private static func mayOverlap(
        _ first: InputWindowBounds,
        _ second: InputWindowBounds
    ) -> Bool {
        guard first.isValid, second.isValid else { return true }
        return first.originX < second.originX + second.width &&
            second.originX < first.originX + first.width &&
            first.originY < second.originY + second.height &&
            second.originY < first.originY + first.height
    }

    private func currentWindowBounds(
        for selection: HostInputWindowSelection,
        windows: [WindowServerWindow]
    ) -> InputWindowBounds? {
        windows.first(where: {
            $0.windowIdentifier == selection.windowIdentifier &&
                $0.processIdentifier == selection.processIdentifier &&
                $0.applicationIdentifier == selection.applicationIdentifier
        })?.bounds
    }

    struct WindowServerWindow: Sendable {
        let windowIdentifier: UInt64
        let processIdentifier: Int32
        /// WindowServer layer. Missing metadata remains distinguishable so
        /// potentially overlapping unknown layers can fail closed.
        let layer: Int?
        /// `nil` means the owner could not be resolved. Keep unknown windows
        /// in the ordered on-screen list so focus classification can reject
        /// them when they may cover the selection.
        let applicationIdentifier: String?
        let isRegularApplication: Bool
        let bounds: InputWindowBounds
    }

    fileprivate static func frontmostApplicationWindow(
        in windows: [WindowServerWindow]
    ) -> WindowServerWindow? {
        windows.first(where: {
            $0.layer == 0 && $0.applicationIdentifier != nil && $0.isRegularApplication
        })
    }

    fileprivate static func onScreenApplicationWindows() -> [WindowServerWindow] {
        applicationWindows(options: [.optionOnScreenOnly, .excludeDesktopElements])
    }

    private static func targetWindowSnapshot(
        windowIdentifier: UInt64,
        windows: [WindowServerWindow]
    ) -> [WindowServerWindow] {
        // Prefer the same ordered onscreen snapshot used for focus checks. If
        // the exact ID is absent, resolve it from all current-session
        // WindowServer windows so an inactive P6 target remains verifiable.
        guard !windows.contains(where: { $0.windowIdentifier == windowIdentifier }) else {
            return windows
        }
        return applicationWindows(options: [.optionAll, .excludeDesktopElements])
    }

    private static func applicationWindows(
        options: CGWindowListOption
    ) -> [WindowServerWindow] {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return rawWindows.compactMap { info in
            guard let windowNumber = (info["kCGWindowNumber"] as? NSNumber)?.uint64Value,
                  let processIdentifier = (info["kCGWindowOwnerPID"] as? NSNumber)?.int32Value,
                  processIdentifier > 0,
                  let boundsDictionary = info["kCGWindowBounds"] as? NSDictionary else {
                return nil
            }

            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDictionary, &bounds),
                  bounds.width > 0,
                  bounds.height > 0 else {
                return nil
            }
            let application = NSRunningApplication(
                processIdentifier: processIdentifier
            )
            return WindowServerWindow(
                windowIdentifier: windowNumber,
                processIdentifier: processIdentifier,
                layer: (info["kCGWindowLayer"] as? NSNumber)?.intValue,
                applicationIdentifier: application?.bundleIdentifier,
                isRegularApplication: application?.activationPolicy == .regular,
                bounds: InputWindowBounds(
                    originX: bounds.origin.x,
                    originY: bounds.origin.y,
                    width: bounds.width,
                    height: bounds.height
                )
            )
        }
    }

    private func consoleFocusState() -> HostInputFocusState? {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return .unknown
        }

        var observedState = false
        for key in ["CGSSessionScreenIsLocked", "CGSessionScreenIsLocked"] {
            guard let value = dictionary[key] else { continue }
            guard let isLocked = value as? Bool else { return .unknown }
            observedState = true
            if isLocked { return .lockedScreen }
        }
        if let value = dictionary["kCGSSessionOnConsoleKey"] {
            guard let onConsole = value as? Bool else { return .unknown }
            observedState = true
            if !onConsole { return .lockedScreen }
        }
        if let value = dictionary["kCGSessionLoginDoneKey"] {
            guard let loginDone = value as? Bool else { return .unknown }
            observedState = true
            if !loginDone { return .lockedScreen }
        }
        return observedState ? nil : .unknown
    }
}

/// Best-effort foregrounding for the exact window the Viewer explicitly
/// selected. Accessibility is used only for the local AXRaise action; input
/// authorization still independently requires a fresh foreground check.
public enum CoreGraphicsAccessibilityWindowFocus {
    /// Confirms the exact selected target is still live and its process is the
    /// active workspace app. The top regular layer-0 WindowServer window must
    /// belong to that app, but may have a different window identifier.
    /// Overlapping unknown-owner layer-0 surfaces remain fail-closed.
    public static func isSelectedWindowForeground(
        _ selection: HostInputWindowSelection
    ) -> Bool {
        let windows = CoreGraphicsAccessibilityContextProvider.onScreenApplicationWindows()
        return CoreGraphicsAccessibilityContextProvider.selectedWindowFocusState(
            for: selection,
            windows: windows,
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ) == .eligible
    }

    /// Raises a uniquely identified AX window for an explicit Viewer window
    /// selection. It never prompts for Accessibility access and returns false
    /// when permission, geometry, or window identity is ambiguous.
    @discardableResult
    public static func raiseSelectedWindowIfAccessible(
        _ selection: HostInputWindowSelection,
        title: String?
    ) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let application = AXUIElementCreateApplication(pid_t(selection.processIdentifier))
        _ = AXUIElementSetMessagingTimeout(application, 0.35)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
        let accessibilityWindows = windowsValue as? [AXUIElement] else {
            return false
        }

        let candidates = accessibilityWindows.compactMap { element -> (AXUIElement, AccessibilityWindowGeometry)? in
            guard let geometry = Self.geometry(of: element) else { return nil }
            return (element, geometry)
        }
        let geometries = candidates.map(\.1)
        let geometryMatches = AccessibilityWindowMatcher.geometryMatchIndices(
            selectedBounds: selection.bounds,
            candidates: geometries
        )
        guard !geometryMatches.isEmpty else {
            return false
        }

        let index: Int
        let hasSelectedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if geometryMatches.count == 1,
           !hasSelectedTitle {
            index = geometryMatches[0]
        } else {
            var titledCandidates = geometries
            for candidateIndex in geometryMatches {
                titledCandidates[candidateIndex] = AccessibilityWindowGeometry(
                    title: Self.title(of: candidates[candidateIndex].0),
                    bounds: geometries[candidateIndex].bounds
                )
            }
            guard let match = AccessibilityWindowMatcher.matchIndex(
                selectedBounds: selection.bounds,
                selectedTitle: title,
                candidates: titledCandidates
            ) else {
                return false
            }
            index = match
        }

        return AXUIElementPerformAction(
            candidates[index].0,
            kAXRaiseAction as CFString
        ) == .success
    }

    private static func geometry(of element: AXUIElement) -> AccessibilityWindowGeometry? {
        _ = AXUIElementSetMessagingTimeout(element, 0.35)
        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        let positionValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID() else {
            return nil
        }
        let accessibilityPosition = unsafeDowncast(positionValue, to: AXValue.self)
        guard AXValueGetType(accessibilityPosition) == .cgPoint else { return nil }
        var position = CGPoint.zero
        guard AXValueGetValue(accessibilityPosition, .cgPoint, &position) else { return nil }

        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let sizeValue,
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        let accessibilitySize = unsafeDowncast(sizeValue, to: AXValue.self)
        guard AXValueGetType(accessibilitySize) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(accessibilitySize, .cgSize, &size) else { return nil }

        let bounds = InputWindowBounds(
            originX: Double(position.x),
            originY: Double(position.y),
            width: Double(size.width),
            height: Double(size.height)
        )
        guard bounds.isValid else { return nil }
        return AccessibilityWindowGeometry(title: nil, bounds: bounds)
    }

    private static func title(of element: AXUIElement) -> String? {
        _ = AXUIElementSetMessagingTimeout(element, 0.35)
        var titleValue: CFTypeRef?
        let title = AXUIElementCopyAttributeValue(
            element,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success ? titleValue as? String : nil
        return title
    }
}

struct AccessibilityWindowGeometry: Equatable, Sendable {
    let title: String?
    let bounds: InputWindowBounds
}

enum AccessibilityWindowMatcher {
    private static let geometryTolerance = 2.0

    static func geometryMatchIndices(
        selectedBounds: InputWindowBounds,
        candidates: [AccessibilityWindowGeometry]
    ) -> [Int] {
        guard selectedBounds.isValid else { return [] }
        return candidates.indices.filter {
            geometricallyMatches(selectedBounds, candidates[$0].bounds)
        }
    }

    static func matchIndex(
        selectedBounds: InputWindowBounds,
        selectedTitle: String?,
        candidates: [AccessibilityWindowGeometry]
    ) -> Int? {
        let geometryMatches = geometryMatchIndices(
            selectedBounds: selectedBounds,
            candidates: candidates
        )
        guard !geometryMatches.isEmpty else { return nil }
        if geometryMatches.count == 1 {
            let index = geometryMatches[0]
            guard let expectedTitle = normalized(selectedTitle) else { return index }
            return normalized(candidates[index].title) == expectedTitle ? index : nil
        }

        guard let expectedTitle = normalized(selectedTitle) else { return nil }
        let titleMatches = geometryMatches.filter {
            normalized(candidates[$0].title) == expectedTitle
        }
        return titleMatches.count == 1 ? titleMatches[0] : nil
    }

    private static func geometricallyMatches(
        _ lhs: InputWindowBounds,
        _ rhs: InputWindowBounds
    ) -> Bool {
        abs(lhs.originX - rhs.originX) <= geometryTolerance &&
            abs(lhs.originY - rhs.originY) <= geometryTolerance &&
            abs(lhs.width - rhs.width) <= geometryTolerance &&
            abs(lhs.height - rhs.height) <= geometryTolerance
    }

    private static func normalized(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum HostInputSecureInputState: Equatable, Sendable {
    case inactive
    case active
    case unknown
}

enum HostInputEventDeliveryRoute: Equatable {
    case system
    case targetProcessCleanup

    static func resolve(
        focus: HostInputFocusState,
        isCleanupRelease: Bool
    ) -> Self? {
        if isCleanupRelease {
            switch focus {
            case .eligible, .notForeground, .backgroundEligible:
                return .targetProcessCleanup
            case .windowUnavailable, .lockedScreen, .secureInput, .unknown:
                return nil
            }
        }
        switch focus {
        case .eligible:
            return .system
        case .notForeground, .backgroundEligible, .windowUnavailable, .lockedScreen, .secureInput, .unknown:
            return nil
        }
    }
}

/// Posts only typed commands produced by `HostInputMapper`. Ordinary input
/// uses the public system event stream, where the cursor and normal hit-testing
/// select the recipient. PID-targeted posting is reserved for safe state
/// cleanup after foreground eligibility or authorization has been lost.
public final class CoreGraphicsAccessibilityInputAdapter: HostInputInjectionAdapter, @unchecked Sendable {
    private let contextProvider: any HostInputContextProvider

    public init(contextProvider: any HostInputContextProvider) {
        self.contextProvider = contextProvider
    }

    public func inject(_ command: HostInputCommand) throws {
        try perform(command, allowUnauthorizedStateRelease: false)
    }

    /// Best-effort cleanup for a state that this controller admitted before a
    /// session authorization or selection transition. It still requires the
    /// same live target, current bounds, PostEvent permission, and either
    /// eligible focus or the target's known-not-foreground state. It does not
    /// require the now-revoked session capability.
    public func release(_ command: HostInputCommand) throws {
        switch command {
        case let .pointerButton(_, _, _, pressed) where !pressed,
             let .key(_, _, _, pressed) where !pressed:
            break
        default:
            throw HostInputAdapterError.targetUnavailable
        }
        try perform(
            command,
            allowUnauthorizedStateRelease: true,
            allowNotForegroundStateRelease: true
        )
    }

    private func perform(
        _ command: HostInputCommand,
        allowUnauthorizedStateRelease: Bool,
        allowNotForegroundStateRelease: Bool = false
    ) throws {
        try validateTarget(
            for: command,
            allowUnauthorizedStateRelease: allowUnauthorizedStateRelease,
            allowNotForegroundStateRelease: allowNotForegroundStateRelease
        )
        guard CGPreflightPostEventAccess() else {
            throw HostInputAdapterError.permissionUnavailable
        }

        switch command {
        case let .focusIntent(target):
            // Focus is an eligibility precondition, not a remote command to
            // activate a background app. The next real event must pass the
            // same foreground check again.
            _ = try validateTarget(
                target,
                requiredCapability: .mouse,
                location: nil,
                allowUnauthorizedStateRelease: allowUnauthorizedStateRelease,
                allowNotForegroundStateRelease: allowNotForegroundStateRelease
            )
            return
        case let .pointerMove(target, location):
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: location.x, y: location.y),
                mouseButton: .left
            ) else {
                throw HostInputAdapterError.eventCreationFailed
            }
            try post(
                event,
                target: target,
                requiredCapability: .mouse,
                location: location,
                allowUnauthorizedStateRelease: allowUnauthorizedStateRelease,
                allowNotForegroundStateRelease: allowNotForegroundStateRelease
            )
        case let .pointerButton(target, location, button, pressed):
            let mouseButton = try mouseButton(for: button)
            let mouseType: CGEventType
            switch (mouseButton, pressed) {
            case (.left, true): mouseType = .leftMouseDown
            case (.left, false): mouseType = .leftMouseUp
            case (.right, true): mouseType = .rightMouseDown
            case (.right, false): mouseType = .rightMouseUp
            case (.center, true): mouseType = .otherMouseDown
            case (.center, false): mouseType = .otherMouseUp
            @unknown default:
                throw HostInputAdapterError.unsupportedButton
            }
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: mouseType,
                mouseCursorPosition: CGPoint(x: location.x, y: location.y),
                mouseButton: mouseButton
            ) else {
                throw HostInputAdapterError.eventCreationFailed
            }
            try post(
                event,
                target: target,
                requiredCapability: .mouse,
                location: location,
                allowUnauthorizedStateRelease: allowUnauthorizedStateRelease,
                allowNotForegroundStateRelease: allowNotForegroundStateRelease
            )
        case let .scroll(target, location, deltaX, deltaY):
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: deltaY,
                wheel2: deltaX,
                wheel3: 0
            ) else {
                throw HostInputAdapterError.eventCreationFailed
            }
            event.location = CGPoint(x: location.x, y: location.y)
            try post(
                event,
                target: target,
                requiredCapability: .mouse,
                location: location,
                allowUnauthorizedStateRelease: allowUnauthorizedStateRelease,
                allowNotForegroundStateRelease: allowNotForegroundStateRelease
            )
        case let .key(target, keyCode, modifiers, pressed):
            guard modifiers & ~HostInputModifierMask.allowedRawValue == 0 else {
                throw HostInputError.invalidModifierMask
            }
            guard let event = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(keyCode),
                keyDown: pressed
            ) else {
                throw HostInputAdapterError.eventCreationFailed
            }
            event.flags = CGEventFlags(rawValue: UInt64(modifiers))
            try post(
                event,
                target: target,
                requiredCapability: .keyboard,
                location: nil,
                allowUnauthorizedStateRelease: allowUnauthorizedStateRelease,
                allowNotForegroundStateRelease: allowNotForegroundStateRelease
            )
        }
    }

    private func post(
        _ event: CGEvent,
        target: HostInputTarget,
        requiredCapability: HostInputCapability?,
        location: InputScreenPoint?,
        allowUnauthorizedStateRelease: Bool,
        allowNotForegroundStateRelease: Bool = false
    ) throws {
        let context = try validateTarget(
            target,
            requiredCapability: requiredCapability,
            location: location,
            allowUnauthorizedStateRelease: allowUnauthorizedStateRelease,
            allowNotForegroundStateRelease: allowNotForegroundStateRelease
        )
        // This is the final live target, permission, generation, capability,
        // and focus check before dispatch. A normal event is never directed
        // to a PID: Quartz hit-tests it at its actual cursor location.
        let cleanupRelease = allowUnauthorizedStateRelease && allowNotForegroundStateRelease
        guard let route = HostInputEventDeliveryRoute.resolve(
            focus: context.focus,
            isCleanupRelease: cleanupRelease
        ) else {
            throw HostInputAdapterError.targetUnavailable
        }
        switch route {
        case .system:
            event.post(tap: .cghidEventTap)
        case .targetProcessCleanup:
            event.postToPid(target.processIdentifier)
        }
    }

    private func validateTarget(
        for command: HostInputCommand,
        allowUnauthorizedStateRelease: Bool,
        allowNotForegroundStateRelease: Bool = false
    ) throws {
        let target: HostInputTarget
        let requiredCapability: HostInputCapability
        let location: InputScreenPoint?
        switch command {
        case let .pointerMove(commandTarget, commandLocation):
            target = commandTarget
            requiredCapability = .mouse
            location = commandLocation
        case let .pointerButton(commandTarget, commandLocation, _, _):
            target = commandTarget
            requiredCapability = .mouse
            location = commandLocation
        case let .scroll(commandTarget, commandLocation, _, _):
            target = commandTarget
            requiredCapability = .mouse
            location = commandLocation
        case let .key(commandTarget, _, _, _):
            target = commandTarget
            requiredCapability = .keyboard
            location = nil
        case let .focusIntent(commandTarget):
            target = commandTarget
            requiredCapability = .mouse
            location = nil
        }
        _ = try validateTarget(
            target,
            requiredCapability: requiredCapability,
            location: location,
            allowUnauthorizedStateRelease: allowUnauthorizedStateRelease,
            allowNotForegroundStateRelease: allowNotForegroundStateRelease
        )
    }

    private func validateTarget(
        _ target: HostInputTarget,
        requiredCapability: HostInputCapability?,
        location: InputScreenPoint?,
        allowUnauthorizedStateRelease: Bool,
        allowNotForegroundStateRelease: Bool
    ) throws -> HostInputContext {
        var context = contextProvider.currentContext()
        if allowUnauthorizedStateRelease,
           !selectedTargetMatches(context, target) {
            // The selected-window provider may already describe a new target.
            // Cleanup is allowed to use only a provider-supplied live snapshot
            // for the originally admitted target; it never reuses the new
            // selection to release old state.
            guard let releaseContext = contextProvider.currentReleaseContext(for: target) else {
                throw HostInputAdapterError.targetUnavailable
            }
            context = releaseContext
        }
        guard context.permission == .authorized else {
            throw HostInputAdapterError.permissionUnavailable
        }

        guard selectedTargetMatches(context, target),
              context.currentWindowIdentifier == target.windowIdentifier,
              context.currentProcessIdentifier == target.processIdentifier,
              context.currentApplicationIdentifier == target.applicationIdentifier,
              let currentBounds = context.currentWindowBounds,
              currentBounds.isValid else {
            throw HostInputAdapterError.targetUnavailable
        }

        if context.focus != .eligible {
            guard allowUnauthorizedStateRelease, allowNotForegroundStateRelease else {
                throw HostInputAdapterError.targetUnavailable
            }
            switch context.focus {
            case .notForeground:
                break
            case .backgroundEligible where context.processTargetingAuthorized:
                break
            default:
                throw HostInputAdapterError.targetUnavailable
            }
        }

        if !allowUnauthorizedStateRelease {
            guard context.sessionAuthorized,
                  context.authorizedWindowGeneration == target.windowGeneration else {
                throw HostInputAdapterError.targetUnavailable
            }
        }
        if !allowUnauthorizedStateRelease, let requiredCapability {
            let enabled: Bool
            switch requiredCapability {
            case .mouse: enabled = context.mouseInputEnabled
            case .keyboard: enabled = context.keyboardInputEnabled
            }
            guard enabled else { throw HostInputAdapterError.targetUnavailable }
        }
        if let location,
           !locationIsInsideCurrentBounds(location, bounds: currentBounds) {
            throw HostInputAdapterError.targetUnavailable
        }
        return context
    }

    private func locationIsInsideCurrentBounds(
        _ location: InputScreenPoint,
        bounds: InputWindowBounds
    ) -> Bool {
        location.x.isFinite && location.y.isFinite &&
            location.x >= bounds.originX &&
            location.x < bounds.originX + bounds.width &&
            location.y >= bounds.originY &&
            location.y < bounds.originY + bounds.height
    }

    private func selectedTargetMatches(
        _ context: HostInputContext,
        _ target: HostInputTarget
    ) -> Bool {
        guard let selectedWindow = context.selectedWindow else { return false }
        return selectedWindow.windowIdentifier == target.windowIdentifier &&
            selectedWindow.processIdentifier == target.processIdentifier &&
            selectedWindow.applicationIdentifier == target.applicationIdentifier &&
            selectedWindow.generation == target.windowGeneration
    }

    private func mouseButton(for button: UInt8) throws -> CGMouseButton {
        switch button {
        case 0: return .left
        case 1: return .right
        case 2: return .center
        default: throw HostInputAdapterError.unsupportedButton
        }
    }
}
