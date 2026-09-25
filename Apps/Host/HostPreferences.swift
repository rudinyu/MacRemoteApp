import Foundation

/// User-facing Host settings that are safe to keep outside the Keychain.
///
/// The Bonjour instance name is discovery metadata, not an identity or a
/// trust decision. It is deliberately bounded because it is advertised to
/// every device that can browse the local service.
enum HostPreferences {
    private static let legacyDefaultServiceName = "MacRemoteApp-Host"
    private static let fallbackServiceName = "MacRemoteApp Host"
    static let serviceNameKey = "MacRemoteApp.Host.serviceName"
    static let maximumServiceNameUTF8Bytes = 63

    /// Bonjour's default display name follows this Mac's short system host
    /// name. The old product-generic default is migrated transparently, while
    /// an explicitly renamed value continues to take precedence.
    static var localDeviceName: String {
        shortHostName(ProcessInfo.processInfo.hostName)
    }

    static var defaultServiceName: String { localDeviceName }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        hostName: String = ProcessInfo.processInfo.hostName
    ) -> String {
        if let configured = environment["MACREMOTEAPP_SERVICE_NAME"],
           let validated = validatedServiceName(configured) {
            return validated
        }
        if let saved = defaults.string(forKey: serviceNameKey),
           let validated = validatedServiceName(saved) {
            if validated == legacyDefaultServiceName {
                return shortHostName(hostName)
            }
            return validated
        }
        return shortHostName(hostName)
    }

    static func save(_ serviceName: String, defaults: UserDefaults = .standard) {
        guard let validated = validatedServiceName(serviceName) else { return }
        defaults.set(validated, forKey: serviceNameKey)
    }

    static func validatedServiceName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumServiceNameUTF8Bytes,
              trimmed.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return trimmed
    }

    static func shortHostName(_ hostName: String) -> String {
        let shortName = hostName
            .split(separator: ".", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return validatedServiceName(shortName) ?? fallbackServiceName
    }
}
