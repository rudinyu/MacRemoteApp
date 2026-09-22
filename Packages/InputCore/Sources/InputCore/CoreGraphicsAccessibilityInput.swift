@preconcurrency import ApplicationServices
@preconcurrency import CoreGraphics
import AppKit
import Foundation

/// The real macOS context source. It checks Accessibility and post-event
/// permission, the current on-screen window identity, foreground ordering, and
/// the console/lock state for every snapshot. It never attempts to activate a
/// background window.
public struct CoreGraphicsAccessibilityContextProvider: HostInputContextProvider, @unchecked Sendable {
    public typealias SessionStateProvider = @Sendable () -> HostInputSessionState
    public typealias SelectionProvider = @Sendable () -> HostInputWindowSelection?
    public typealias SecureInputStateProvider = @Sendable () -> HostInputSecureInputState

    private let sessionStateProvider: SessionStateProvider
    private let selectionProvider: SelectionProvider
    private let secureInputStateProvider: SecureInputStateProvider

    /// The public macOS API does not expose a general secure-input status
    /// query. The default is therefore `.unknown`, which remains fail-closed.
    /// A Host UI/adapter may provide a trustworthy, local safe-app signal for
    /// the selected test application; it must never infer safety from Viewer
    /// input or a remote message.
    public init(
        sessionStateProvider: @escaping SessionStateProvider,
        selectionProvider: @escaping SelectionProvider,
        secureInputStateProvider: @escaping SecureInputStateProvider = Self.detectSecureInputState
    ) {
        self.sessionStateProvider = sessionStateProvider
        self.selectionProvider = selectionProvider
        self.secureInputStateProvider = secureInputStateProvider
    }

    /// Best-effort local secure-input signal. macOS does not expose a single
    /// public global secure-input flag, so the provider checks the focused
    /// Accessibility element for the secure-text-field role and fails closed
    /// when Accessibility cannot provide a trustworthy answer. This is a
    /// local host fact only; it never uses Viewer input as evidence.
    public static func detectSecureInputState() -> HostInputSecureInputState {
        guard AXIsProcessTrusted() else { return .unknown }

        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .unknown
        }
        let focused = unsafeDowncast(focusedValue, to: AXUIElement.self)

        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
        let role = roleValue as? String else {
            return .unknown
        }

        if role == "AXSecureTextField" {
            return .active
        }

        var subroleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focused,
            kAXSubroleAttribute as CFString,
            &subroleValue
        ) == .success,
           let subrole = subroleValue as? String,
           subrole == "AXSecureTextField" {
            return .active
        }

        return .inactive
    }

    /// Returns the current local permission state without presenting a
    /// consent prompt. Hosts use this to keep remote input capabilities in
    /// sync with macOS TCC state.
    public static func currentPermissionState() -> HostInputPermissionState {
        permissionState()
    }

    /// Requests the two local permissions required for post-event input.
    /// The request is intentionally initiated by the signed Host bundle so
    /// TCC records the decision against MacRemoteApp, not a launching shell.
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
                keyboardInputEnabled: session.keyboardInputEnabled
            )
        }

        let windows = onScreenApplicationWindows()
        return HostInputContext(
            sessionAuthorized: session.authorized,
            authorizedWindowGeneration: session.authorizedWindowGeneration,
            selectedWindow: selection,
            currentWindowIdentifier: currentWindowIdentifier(for: selection, windows: windows),
            currentProcessIdentifier: currentProcessIdentifier(windows: windows),
            currentApplicationIdentifier: currentApplicationIdentifier(windows: windows),
            currentWindowBounds: currentWindowBounds(for: selection, windows: windows),
            permission: Self.permissionState(),
            focus: focusState(for: selection, windows: windows),
            mouseInputEnabled: session.mouseInputEnabled,
            keyboardInputEnabled: session.keyboardInputEnabled
        )
    }

    public func currentReleaseContext(for target: HostInputTarget) -> HostInputContext? {
        let session = sessionStateProvider()
        let windows = onScreenApplicationWindows()
        guard let liveWindow = windows.first(where: {
            $0.windowIdentifier == target.windowIdentifier &&
                $0.processIdentifier == target.processIdentifier &&
                $0.applicationIdentifier == target.applicationIdentifier
        }) else {
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
            currentWindowIdentifier: currentWindowIdentifier(for: selection, windows: windows),
            currentProcessIdentifier: currentProcessIdentifier(windows: windows),
            currentApplicationIdentifier: currentApplicationIdentifier(windows: windows),
            currentWindowBounds: liveWindow.bounds,
            permission: Self.permissionState(),
            focus: focusState(for: selection, windows: windows),
            mouseInputEnabled: session.mouseInputEnabled,
            keyboardInputEnabled: session.keyboardInputEnabled
        )
    }

    private static func permissionState() -> HostInputPermissionState {
        guard CGPreflightPostEventAccess(), AXIsProcessTrusted() else {
            return .missing
        }
        return .authorized
    }

    private func focusState(
        for selection: HostInputWindowSelection,
        windows: [OnScreenWindow]
    ) -> HostInputFocusState {
        switch secureInputStateProvider() {
        case .active:
            return .secureInput
        case .unknown:
            return .unknown
        case .inactive:
            break
        }
        if let consoleState = consoleFocusState() {
            return consoleState
        }

        guard !windows.isEmpty else { return .windowUnavailable }
        // An unresolved owner can be a security/authentication surface. It
        // must remain a blocker; filtering it out would make a covered app
        // look foreground-eligible.
        guard windows.first?.applicationIdentifier != nil else { return .unknown }
        guard let selected = windows.first(where: {
            $0.windowIdentifier == selection.windowIdentifier &&
                $0.processIdentifier == selection.processIdentifier &&
                $0.applicationIdentifier == selection.applicationIdentifier
        }) else {
            return .windowUnavailable
        }
        guard selected.bounds.isValid else { return .windowUnavailable }

        // CGWindowList is ordered front-to-back, but its first entry may be a
        // WindowServer/menu-bar surface rather than the frontmost regular
        // application window. Ignore known non-regular system surfaces while
        // retaining unresolved/security surfaces as blockers above.
        guard let frontmostApplication = frontmostApplicationWindow(in: windows),
              frontmostApplication.windowIdentifier == selection.windowIdentifier,
              frontmostApplication.processIdentifier == selection.processIdentifier,
              frontmostApplication.applicationIdentifier == selection.applicationIdentifier else {
            return .notForeground
        }
        return .eligible
    }

    private func currentWindowIdentifier(
        for selection: HostInputWindowSelection,
        windows: [OnScreenWindow]
    ) -> UInt64? {
        frontmostApplicationWindow(in: windows)?.windowIdentifier
    }

    private func currentProcessIdentifier(windows: [OnScreenWindow]) -> Int32? {
        frontmostApplicationWindow(in: windows)?.processIdentifier
    }

    private func currentApplicationIdentifier(windows: [OnScreenWindow]) -> String? {
        frontmostApplicationWindow(in: windows)?.applicationIdentifier
    }

    private func currentWindowBounds(
        for selection: HostInputWindowSelection,
        windows: [OnScreenWindow]
    ) -> InputWindowBounds? {
        windows.first(where: {
            $0.windowIdentifier == selection.windowIdentifier &&
                $0.processIdentifier == selection.processIdentifier &&
                $0.applicationIdentifier == selection.applicationIdentifier
        })?.bounds
    }

    private struct OnScreenWindow: Sendable {
        let windowIdentifier: UInt64
        let processIdentifier: Int32
        /// `nil` means WindowServer reported an on-screen owner that this
        /// process could not resolve. Unknown windows remain in the ordered
        /// list as blockers; dropping them could make a covered selected
        /// window look foreground-eligible.
        let applicationIdentifier: String?
        let isRegularApplication: Bool
        let bounds: InputWindowBounds
    }

    private func frontmostApplicationWindow(
        in windows: [OnScreenWindow]
    ) -> OnScreenWindow? {
        windows.first(where: {
            $0.applicationIdentifier != nil && $0.isRegularApplication
        })
    }

    private func onScreenApplicationWindows() -> [OnScreenWindow] {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
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
            return OnScreenWindow(
                windowIdentifier: windowNumber,
                processIdentifier: processIdentifier,
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

public enum HostInputSecureInputState: Equatable, Sendable {
    case inactive
    case active
    case unknown
}

/// Posts only the typed commands produced by `HostInputMapper`. The adapter
/// repeats the selected-window, focus, and Accessibility checks immediately
/// before each event is posted, then routes the event to the validated target
/// process rather than to the global frontmost application.
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
    /// same live target, current bounds, Accessibility permission, and either
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
        guard CGPreflightPostEventAccess(), AXIsProcessTrusted() else {
            throw HostInputAdapterError.permissionUnavailable
        }

        switch command {
        case let .focusIntent(target):
            // Focus is an eligibility precondition, not a remote command to
            // activate a background app. The next real event must pass the
            // same foreground check again.
            try validateTarget(
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
        try validateTarget(
            target,
            requiredCapability: requiredCapability,
            location: location,
            allowUnauthorizedStateRelease: allowUnauthorizedStateRelease,
            allowNotForegroundStateRelease: allowNotForegroundStateRelease
        )
        // Re-read the foreground/target facts as the last operation before the
        // OS post. Target-bound posting prevents redirection to another PID,
        // while this final fail-closed check preserves the foreground-only
        // policy as far as the public CoreGraphics API permits.
        try validateTarget(
            target,
            requiredCapability: requiredCapability,
            location: location,
            allowUnauthorizedStateRelease: allowUnauthorizedStateRelease,
            allowNotForegroundStateRelease: allowNotForegroundStateRelease
        )
        event.postToPid(target.processIdentifier)
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
        try validateTarget(
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
    ) throws {
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
              let currentBounds = context.currentWindowBounds,
              currentBounds.isValid else {
            throw HostInputAdapterError.targetUnavailable
        }

        if context.focus == .eligible {
            guard context.currentWindowIdentifier == target.windowIdentifier,
                  context.currentProcessIdentifier == target.processIdentifier,
                  context.currentApplicationIdentifier == target.applicationIdentifier else {
                throw HostInputAdapterError.targetUnavailable
            }
        } else if !(allowNotForegroundStateRelease && context.focus == .notForeground) {
            throw HostInputAdapterError.targetUnavailable
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
