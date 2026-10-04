import Foundation

/// The bounded language family used for Viewer-led input-source following.
public enum InputSourceKind: String, Equatable, Hashable, Sendable {
    case english
    case chinese
}

/// A process-independent description of a selectable macOS keyboard source.
/// The identifier is the exact TIS input-source ID; TIS uses distinct IDs for
/// input modes, so a Chinese mode is not collapsed to its parent IME.
public struct InputSourceDescriptor: Equatable, Hashable, Sendable {
    public let identifier: String
    public let kind: InputSourceKind

    public init(identifier: String, kind: InputSourceKind) {
        self.identifier = identifier
        self.kind = kind
    }

    /// Matches the ADR-0007 wire bound and excludes identifiers containing
    /// control characters before they reach a platform selection API.
    public var isValid: Bool {
        !identifier.isEmpty &&
            identifier.utf8.count <= 256 &&
            !identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// Stable result categories. Platform error codes and input-source names are
/// intentionally not exposed to callers or logs.
public enum InputSourceSelectionOutcome: Equatable, Sendable {
    case applied
    case unavailable
    case denied
    case failed
}

/// A plan separates a safe no-op, an exact source change, and an unavailable
/// request so the policy can be tested without touching macOS input state.
public enum InputSourceSelectionPlan: Equatable, Sendable {
    case alreadyMatches
    case select(InputSourceDescriptor)
    case unavailable
}

/// TIS change notifications exposed without the selected source's identifier
/// or localized name.
public enum InputSourceChange: Equatable, Sendable {
    case selectedSourceChanged
    case enabledSourcesChanged
}

/// Read and select only currently enabled keyboard input sources. Concrete
/// providers must not enable or install sources as a side effect.
@MainActor
public protocol InputSourceProvider: Sendable {
    func currentInputSource() -> InputSourceDescriptor?
    func enabledInputSources() -> [InputSourceDescriptor]
    func selectInputSource(_ descriptor: InputSourceDescriptor) -> InputSourceSelectionOutcome
    func selectInputSource(
        _ descriptor: InputSourceDescriptor,
        validatingImmediatelyBeforeSelection isStillEligible: @MainActor () -> Bool
    ) -> InputSourceSelectionOutcome
}

public extension InputSourceProvider {
    /// Providers with a preparation step should override this method and call
    /// the validator after preparation, immediately before changing the OS
    /// source. Simple providers inherit this synchronous final gate.
    func selectInputSource(
        _ descriptor: InputSourceDescriptor,
        validatingImmediatelyBeforeSelection isStillEligible: @MainActor () -> Bool
    ) -> InputSourceSelectionOutcome {
        guard descriptor.isValid else { return .unavailable }
        guard isStillEligible() else { return .denied }
        return selectInputSource(descriptor)
    }
}

/// Pure Viewer-to-Host matching policy. English follows the language family,
/// preferring the requested enabled source and then the first enabled English
/// source in stable identifier order. Chinese follows only the exact source
/// identifier, which includes the selected input mode.
public enum InputSourceSelectionPolicy {
    public static func plan(
        requested: InputSourceDescriptor,
        current: InputSourceDescriptor?,
        enabled: [InputSourceDescriptor]
    ) -> InputSourceSelectionPlan {
        guard requested.isValid else { return .unavailable }

        if requested.kind == .english, current?.kind == .english {
            return .alreadyMatches
        }
        if requested.kind == .chinese, current == requested {
            return .alreadyMatches
        }

        let selectable = enabled.filter(\.isValid)
        switch requested.kind {
        case .chinese:
            guard let exact = selectable.first(where: {
                $0.identifier == requested.identifier && $0.kind == .chinese
            }) else {
                return .unavailable
            }
            return .select(exact)
        case .english:
            if let exact = selectable.first(where: {
                $0.identifier == requested.identifier && $0.kind == .english
            }) {
                return .select(exact)
            }
            guard let fallback = selectable
                .filter({ $0.kind == .english })
                .sorted(by: { $0.identifier < $1.identifier })
                .first else {
                return .unavailable
            }
            return .select(fallback)
        }
    }
}
