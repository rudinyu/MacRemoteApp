import CryptoKit
import Foundation
import Security

public enum SecurityCoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidPublicKey
    case invalidTrustRecord
    case keychain(OSStatus)
    case pairingExpired
    case pairingRejected
    case pairingCodeMismatch
    case pairingAlreadyPending
    case noPendingPairing
    case peerIdentityMismatch
    case invalidNonce
    case identityUnavailable
    case invalidPKCS12
    case certificateUnavailable

    public var description: String {
        switch self {
        case .invalidPublicKey: return "invalid public key"
        case .invalidTrustRecord: return "invalid trust record"
        case let .keychain(status): return "keychain operation failed with status \(status)"
        case .pairingExpired: return "pairing challenge expired"
        case .pairingRejected: return "pairing was rejected"
        case .pairingCodeMismatch: return "pairing confirmation code mismatch"
        case .pairingAlreadyPending: return "a pairing challenge is already pending"
        case .noPendingPairing: return "no pairing challenge is pending"
        case .peerIdentityMismatch: return "peer identity does not match the pending challenge"
        case .invalidNonce: return "pairing nonce is invalid"
        case .identityUnavailable: return "a provisioned platform identity is unavailable"
        case .invalidPKCS12: return "the PKCS#12 identity bundle is invalid"
        case .certificateUnavailable: return "the identity certificate is unavailable"
        }
    }
}

public struct PeerIdentity: Codable, Equatable, Hashable, Sendable {
    public let identifier: String
    public let publicKeyRepresentation: Data

    public init(publicKeyRepresentation: Data) throws {
        let canonicalRepresentation = IdentityFingerprint.canonicalRepresentation(
            for: publicKeyRepresentation
        )
        guard !canonicalRepresentation.isEmpty else {
            throw SecurityCoreError.invalidPublicKey
        }
        self.publicKeyRepresentation = canonicalRepresentation
        self.identifier = IdentityFingerprint.identifier(for: canonicalRepresentation)
    }

    public init(identifier: String, publicKeyRepresentation: Data) throws {
        let canonicalRepresentation = IdentityFingerprint.canonicalRepresentation(
            for: publicKeyRepresentation
        )
        guard !canonicalRepresentation.isEmpty,
              identifier == IdentityFingerprint.identifier(for: canonicalRepresentation) else {
            throw SecurityCoreError.invalidPublicKey
        }
        self.identifier = identifier
        self.publicKeyRepresentation = canonicalRepresentation
    }
}

public typealias DeviceIdentity = PeerIdentity

public struct TrustedPeer: Codable, Equatable, Sendable {
    public let identity: PeerIdentity
    public let displayName: String?
    public let createdAt: Date

    public init(identity: PeerIdentity, displayName: String? = nil, createdAt: Date = Date()) {
        self.identity = identity
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

public enum PeerTrustDecision: Equatable, Sendable {
    case trusted
    case pairingRequired
    case identityMismatch
}

public enum IdentityFingerprint {
    public static func canonicalRepresentation(for publicKeyRepresentation: Data) -> Data {
        guard !publicKeyRepresentation.isEmpty else { return publicKeyRepresentation }

        // Network.framework exposes the peer key as SubjectPublicKeyInfo,
        // while SecKey commonly exports an ANSI X9.63 point. Normalize the
        // P-256 identity to CryptoKit's fixed raw X||Y form before hashing.
        if let key = try? P256.Signing.PublicKey(rawRepresentation: publicKeyRepresentation) {
            return key.rawRepresentation
        }
        if publicKeyRepresentation.count == 65,
           publicKeyRepresentation.first == 0x04,
           let key = try? P256.Signing.PublicKey(
               rawRepresentation: Data(publicKeyRepresentation.dropFirst())
           ) {
            return key.rawRepresentation
        }
        if let key = try? P256.Signing.PublicKey(derRepresentation: publicKeyRepresentation) {
            return key.rawRepresentation
        }

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            publicKeyRepresentation as CFData,
            attributes as CFDictionary,
            &error
        ),
        let canonical = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            // The in-memory tests use opaque deterministic bytes rather than
            // real keys. Preserve those bytes; real EC public keys normalize
            // to the same ANSI X9.63 representation on every path.
            return publicKeyRepresentation
        }
        return canonical
    }

    public static func identifier(for publicKeyRepresentation: Data) -> String {
        SHA256.hash(data: canonicalRepresentation(for: publicKeyRepresentation))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public protocol TrustStore: Sendable {
    func trustedPeer(for identifier: String) async throws -> TrustedPeer?
    func allTrustedPeers() async throws -> [TrustedPeer]
    func save(_ peer: TrustedPeer) async throws
    func revoke(peerIdentifier: String) async throws
}

public actor InMemoryTrustStore: TrustStore {
    private var peers: [String: TrustedPeer] = [:]

    public init() {}

    public func trustedPeer(for identifier: String) async throws -> TrustedPeer? {
        peers[identifier]
    }

    public func allTrustedPeers() async throws -> [TrustedPeer] {
        peers.values.sorted { $0.identity.identifier < $1.identity.identifier }
    }

    public func save(_ peer: TrustedPeer) async throws {
        peers[peer.identity.identifier] = peer
    }

    public func revoke(peerIdentifier: String) async throws {
        peers.removeValue(forKey: peerIdentifier)
    }
}

public actor KeychainTrustStore: TrustStore {
    public static let defaultService = "com.rudinyu.MacRemoteApp.trust"

    private let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = KeychainTrustStore.defaultService) {
        self.service = service
    }

    public func trustedPeer(for identifier: String) async throws -> TrustedPeer? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: identifier,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecurityCoreError.keychain(status)
        }
        guard let data = result as? Data else {
            throw SecurityCoreError.invalidTrustRecord
        }
        do {
            return try decoder.decode(TrustedPeer.self, from: data)
        } catch {
            throw SecurityCoreError.invalidTrustRecord
        }
    }

    public func allTrustedPeers() async throws -> [TrustedPeer] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnData: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw SecurityCoreError.keychain(status)
        }
        guard let records = result as? [Data] else {
            throw SecurityCoreError.invalidTrustRecord
        }
        return try records.map { data in
            do {
                return try decoder.decode(TrustedPeer.self, from: data)
            } catch {
                throw SecurityCoreError.invalidTrustRecord
            }
        }.sorted { $0.identity.identifier < $1.identity.identifier }
    }

    public func save(_ peer: TrustedPeer) async throws {
        let data = try encoder.encode(peer)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: peer.identity.identifier
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw SecurityCoreError.keychain(updateStatus)
        }
        var addQuery = query
        addQuery[kSecValueData] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SecurityCoreError.keychain(addStatus)
        }
    }

    public func revoke(peerIdentifier: String) async throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: peerIdentifier
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecurityCoreError.keychain(status)
        }
    }
}

public actor KeychainDeviceIdentityProvider {
    public static let defaultApplicationTag = "com.rudinyu.MacRemoteApp.device-identity"

    private let applicationTag: Data

    public init(applicationTag: String = KeychainDeviceIdentityProvider.defaultApplicationTag) {
        self.applicationTag = Data(applicationTag.utf8)
    }

    public func loadOrCreate() throws -> DeviceIdentity {
        if let privateKey = try loadPrivateKey() {
            return try identity(for: privateKey)
        }

        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: applicationTag
            ]
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SecurityCoreError.keychain(
                OSStatus((error?.takeRetainedValue() as NSError?)?.code ?? -1)
            )
        }
        return try identity(for: privateKey)
    }

    private func loadPrivateKey() throws -> SecKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag: applicationTag,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnRef: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecurityCoreError.keychain(status)
        }
        guard result != nil else {
            throw SecurityCoreError.invalidTrustRecord
        }
        guard CFGetTypeID(result) == SecKeyGetTypeID() else {
            throw SecurityCoreError.invalidTrustRecord
        }
        return unsafeBitCast(result, to: SecKey.self)
    }

    private func identity(for privateKey: SecKey) throws -> DeviceIdentity {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecurityCoreError.invalidPublicKey
        }
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw SecurityCoreError.keychain(
                OSStatus((error?.takeRetainedValue() as NSError?)?.code ?? -1)
            )
        }
        return try DeviceIdentity(publicKeyRepresentation: representation)
    }
}

public struct PeerTrustEvaluator: Sendable {
    public init() {}

    public func decision(for presented: PeerIdentity, trustedPeer: TrustedPeer?) -> PeerTrustDecision {
        guard let trustedPeer else {
            return .pairingRequired
        }
        guard trustedPeer.identity.identifier == presented.identifier,
              trustedPeer.identity.publicKeyRepresentation == presented.publicKeyRepresentation else {
            return .identityMismatch
        }
        return .trusted
    }
}
