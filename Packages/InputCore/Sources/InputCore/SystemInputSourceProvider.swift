@preconcurrency import Carbon.HIToolbox
import AppKit
import Foundation

/// Public Carbon Text Input Sources adapter. TextInputSources is not thread
/// safe, so every TIS read and selection is serialized onto the main thread.
/// It only enumerates already-enabled/selectable keyboard sources and never
/// enables or installs an input method.
public struct SystemInputSourceProvider: InputSourceProvider, @unchecked Sendable {
    public init() {}

    @MainActor
    public func currentInputSource() -> InputSourceDescriptor? {
        Self.currentInputSourceOnMainThread()
    }

    @MainActor
    public func enabledInputSources() -> [InputSourceDescriptor] {
        Self.enabledInputSourcesOnMainThread()
    }

    @MainActor
    public func selectInputSource(
        _ descriptor: InputSourceDescriptor
    ) -> InputSourceSelectionOutcome {
        selectInputSource(descriptor, validatingImmediatelyBeforeSelection: { true })
    }

    @MainActor
    public func selectInputSource(
        _ descriptor: InputSourceDescriptor,
        validatingImmediatelyBeforeSelection isStillEligible: @MainActor () -> Bool
    ) -> InputSourceSelectionOutcome {
        guard descriptor.isValid else { return .unavailable }
        let sources = Self.enabledSelectableSourcesOnMainThread()
        guard let source = sources.first(where: {
            Self.descriptor(for: $0) == descriptor &&
                Self.booleanProperty(kTISPropertyInputSourceIsEnabled, of: $0) &&
                Self.booleanProperty(kTISPropertyInputSourceIsSelectCapable, of: $0)
        }) else {
            return .unavailable
        }
        guard isStillEligible() else { return .denied }
        let status = TISSelectInputSource(source)
        if status == noErr {
            return .applied
        }
        if status == OSStatus(paramErr) {
            return .unavailable
        }
        return .failed
    }

    @MainActor
    private static func currentInputSourceOnMainThread() -> InputSourceDescriptor? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return descriptor(for: source)
    }

    @MainActor
    private static func enabledInputSourcesOnMainThread() -> [InputSourceDescriptor] {
        enabledSelectableSourcesOnMainThread().compactMap(descriptor(for:))
    }

    @MainActor
    private static func enabledSelectableSourcesOnMainThread() -> [TISInputSource] {
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsEnabled as String: true,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ]
        guard let sources = TISCreateInputSourceList(filter as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return sources
    }

    @MainActor
    private static func descriptor(for source: TISInputSource) -> InputSourceDescriptor? {
        guard let identifier = stringProperty(kTISPropertyInputSourceID, of: source),
              let languages = arrayProperty(kTISPropertyInputSourceLanguages, of: source),
              let kind = InputSourceKind(primaryLanguageCodes: languages) else {
            return nil
        }
        let descriptor = InputSourceDescriptor(identifier: identifier, kind: kind)
        return descriptor.isValid ? descriptor : nil
    }

    @MainActor
    private static func stringProperty(_ key: CFString, of source: TISInputSource) -> String? {
        guard let value = property(key, of: source) else { return nil }
        return value as? String
    }

    @MainActor
    private static func arrayProperty(_ key: CFString, of source: TISInputSource) -> [String]? {
        guard let value = property(key, of: source) else { return nil }
        return value as? [String]
    }

    @MainActor
    private static func booleanProperty(_ key: CFString, of source: TISInputSource) -> Bool {
        guard let value = property(key, of: source) as? NSNumber else { return false }
        return value.boolValue
    }

    @MainActor
    private static func property(_ key: CFString, of source: TISInputSource) -> CFTypeRef? {
        guard let rawValue = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(rawValue).takeUnretainedValue()
    }

}

private extension InputSourceKind {
    init?(primaryLanguageCodes: [String]) {
        guard let primaryCode = primaryLanguageCodes.first else { return nil }
        let language = primaryCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "-", maxSplits: 1)
            .first?
            .lowercased()
        switch language {
        case "en": self = .english
        case "zh": self = .chinese
        default: return nil
        }
    }
}

/// Observes the two public TIS distributed notifications. The callback is
/// delivered on the main queue and contains only a coarse change category.
public final class SystemInputSourceObserver: @unchecked Sendable {
    private let center: DistributedNotificationCenter
    private let observers: [NSObjectProtocol]

    public init(onChange: @escaping @Sendable (InputSourceChange) -> Void) {
        let center = DistributedNotificationCenter.default()
        self.center = center
        self.observers = [
            center.addObserver(
                forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                object: nil,
                queue: .main
            ) { _ in
                onChange(.selectedSourceChanged)
            },
            center.addObserver(
                forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                object: nil,
                queue: .main
            ) { _ in
                onChange(.enabledSourcesChanged)
            }
        ]
    }

    deinit {
        observers.forEach(center.removeObserver)
    }
}
