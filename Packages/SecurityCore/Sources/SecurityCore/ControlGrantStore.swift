import Foundation
import Security

/// Durable, per-authenticated-Viewer consent for process-targeted input.
/// The peer fingerprint is the Keychain account; display names are never keys.
public protocol ControlGrantStore: Sendable {
    func contains(peerIdentifier: String) async throws -> Bool
    func grant(peerIdentifier: String) async throws
    func revoke(peerIdentifier: String) async throws
    func removeAll() async throws -> Int
}

public actor KeychainControlGrantStore: ControlGrantStore {
    public static let defaultService = "com.rudinyu.MacRemoteApp.Host.control-grants"

    private let service: String

    public init(service: String = KeychainControlGrantStore.defaultService) {
        self.service = service
    }

    public func contains(peerIdentifier: String) async throws -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: try Self.validated(peerIdentifier),
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnAttributes: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw SecurityCoreError.keychain(status) }
        return true
    }

    public func grant(peerIdentifier: String) async throws {
        let identifier = try Self.validated(peerIdentifier)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: identifier
        ]
        let data = Data([1])
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecurityCoreError.keychain(update) }
        var add = query
        add[kSecValueData] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecurityCoreError.keychain(status) }
    }

    public func revoke(peerIdentifier: String) async throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: try Self.validated(peerIdentifier)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecurityCoreError.keychain(status)
        }
    }

    public func removeAll() async throws -> Int {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true
        ]
        var result: CFTypeRef?
        let lookup = SecItemCopyMatching(query as CFDictionary, &result)
        let count: Int
        if lookup == errSecItemNotFound {
            count = 0
        } else if lookup == errSecSuccess {
            count = (result as? [Any])?.count ?? (result == nil ? 0 : 1)
        } else {
            throw SecurityCoreError.keychain(lookup)
        }
        let deletion: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service
        ]
        let status = SecItemDelete(deletion as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecurityCoreError.keychain(status)
        }
        return count
    }

    private static func validated(_ identifier: String) throws -> String {
        guard !identifier.isEmpty, identifier.utf8.count <= 256,
              identifier.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw SecurityCoreError.invalidTrustRecord
        }
        return identifier
    }
}
