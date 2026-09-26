import Foundation

public struct ApplicationMetadata: Equatable, Sendable {
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = Self.normalized(version, fallback: "Development")
        self.build = Self.normalized(build, fallback: "unbundled")
    }

    public init(
        bundle: Bundle = .main,
        fallbackVersion: String = "Development",
        fallbackBuild: String = "unbundled"
    ) {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        self.version = Self.normalized(version, fallback: fallbackVersion)
        self.build = Self.normalized(build, fallback: fallbackBuild)
    }

    /// MacRemoteApp uses major.minor.build for its user-facing release identity.
    /// If a conventional three-component short version is supplied later, keep it
    /// intact instead of producing an invalid four-component display string.
    public var displayVersion: String {
        version.split(separator: ".").count == 2
            ? "\(version).\(build)"
            : version
    }

    public var displayVersionDetails: String {
        "\(displayVersion) (Build \(build))"
    }

    private static func normalized(_ value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
