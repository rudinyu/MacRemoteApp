import RemoteProtocol

public enum SessionUXPrimaryState: Equatable, Sendable {
    case discovered
    case connecting
    case pairingRequired
    case paired
    case authenticated
    case authorized
    case streaming
    case reconnecting
    case stopping
    case failed
}

public enum SessionUXIndicator: Equatable, Hashable, Sendable {
    case discovered
    case paired
    case authenticated
    case authorized
    case streaming
    case inputReady
    case clipboardEnabled
    case degraded
    case reconnecting
    case stopping
    case failed
}

/// A redacted state projection for Host and Viewer UI. It contains no peer
/// names, clipboard text, input values, or transport error strings.
public struct SessionUXSnapshot: Equatable, Sendable {
    public let primary: SessionUXPrimaryState
    public let indicators: Set<SessionUXIndicator>
    public let permission: PermissionState
    public let clipboard: ClipboardSyncStatus

    public init(
        primary: SessionUXPrimaryState,
        indicators: Set<SessionUXIndicator>,
        permission: PermissionState,
        clipboard: ClipboardSyncStatus
    ) {
        self.primary = primary
        self.indicators = indicators
        self.permission = permission
        self.clipboard = clipboard
    }

    public var inputReady: Bool {
        indicators.contains(.inputReady)
    }

    public var clipboardEnabled: Bool {
        indicators.contains(.clipboardEnabled)
    }
}

/// Converts the package session snapshot plus app-owned stream, permission,
/// and input facts into the explicit states required by M7. The projection is
/// shared so Host and Viewer cannot silently disagree about what "connected"
/// or "ready" means; only the app layer decides how to render it.
public enum SessionUXProjection {
    public static func make(
        session: SessionSnapshot,
        permission: PermissionState,
        streamReady: Bool,
        inputReady: Bool,
        clipboard: ClipboardSyncStatus,
        degraded: Bool = false
    ) -> SessionUXSnapshot {
        let primary = primaryState(for: session.state, streamReady: streamReady, authorized: session.authorized)
        var indicators = Set<SessionUXIndicator>()

        if session.state == .discovered {
            indicators.insert(.discovered)
        }
        let authenticated: Bool
        let paired: Bool
        switch session.state {
        case .authenticated, .trusted, .capabilitiesNegotiated,
             .windowSelectionAuthorized, .streaming:
            authenticated = true
        default:
            authenticated = false
        }
        switch session.state {
        case .trusted, .capabilitiesNegotiated,
             .windowSelectionAuthorized, .streaming:
            paired = true
        default:
            paired = false
        }
        if paired { indicators.insert(.paired) }
        if authenticated { indicators.insert(.authenticated) }
        if session.authorized { indicators.insert(.authorized) }
        if streamReady && session.authorized { indicators.insert(.streaming) }

        let isDegraded = degraded || permission == .missing || permission == .revoked
        if isDegraded { indicators.insert(.degraded) }

        if inputReady && session.authorized && permission == .granted && !isDegraded {
            indicators.insert(.inputReady)
        }
        if clipboard.isEnabledForSession &&
            session.authorized &&
            session.authorizedCapabilities.contains(.textClipboard) &&
            !isDegraded {
            indicators.insert(.clipboardEnabled)
        }
        if session.state == .reconnecting { indicators.insert(.reconnecting) }
        if session.state == .stopping { indicators.insert(.stopping) }
        if session.state == .failed { indicators.insert(.failed) }

        return SessionUXSnapshot(
            primary: primary,
            indicators: indicators,
            permission: permission,
            clipboard: clipboard
        )
    }

    private static func primaryState(
        for state: SessionState,
        streamReady: Bool,
        authorized: Bool
    ) -> SessionUXPrimaryState {
        switch state {
        case .discovered: return .discovered
        case .connecting: return .connecting
        case .pairingRequired: return .pairingRequired
        case .authenticated: return .authenticated
        case .trusted, .capabilitiesNegotiated: return .paired
        case .windowSelectionAuthorized:
            return streamReady && authorized ? .streaming : .authorized
        case .streaming: return .streaming
        case .reconnecting: return .reconnecting
        case .stopping: return .stopping
        case .failed: return .failed
        }
    }
}

/// Pure capability gates used by the app UI. Keeping these checks in the
/// shared package makes partial authorization fail closed in both app targets
/// and gives the permission/clipboard states deterministic coverage.
public struct SessionInputAvailability: Equatable, Sendable {
    public let mouseInputEnabled: Bool
    public let keyboardInputEnabled: Bool

    public init(mouseInputEnabled: Bool, keyboardInputEnabled: Bool) {
        self.mouseInputEnabled = mouseInputEnabled
        self.keyboardInputEnabled = keyboardInputEnabled
    }

    public static let none = SessionInputAvailability(
        mouseInputEnabled: false,
        keyboardInputEnabled: false
    )

    public var anyInputEnabled: Bool {
        mouseInputEnabled || keyboardInputEnabled
    }
}

public enum SessionCapabilityProjection {
    public static let interactiveInputCapabilities: Set<Capability> = [
        .mouseInput,
        .keyboardInput
    ]

    public static func inputReady(
        for session: SessionSnapshot,
        selectedWindowGeneration: UInt64?,
        selectedStreamGeneration: UInt64?
    ) -> Bool {
        inputAvailability(
            for: session,
            selectedWindowGeneration: selectedWindowGeneration,
            selectedStreamGeneration: selectedStreamGeneration
        ).anyInputEnabled
    }

    public static func inputAvailability(
        for session: SessionSnapshot,
        selectedWindowGeneration: UInt64?,
        selectedStreamGeneration: UInt64?
    ) -> SessionInputAvailability {
        guard session.authorized,
              let selectedWindowGeneration,
              let selectedStreamGeneration,
              session.authorizedWindowGeneration == selectedWindowGeneration,
              selectedStreamGeneration == selectedWindowGeneration else {
            return .none
        }
        return SessionInputAvailability(
            mouseInputEnabled: session.authorizedCapabilities.contains(.mouseInput),
            keyboardInputEnabled: session.authorizedCapabilities.contains(.keyboardInput)
        )
    }

    public static func clipboardAvailable(for session: SessionSnapshot) -> Bool {
        session.authorized && session.authorizedCapabilities.contains(.textClipboard)
    }
}
