import Foundation
import Security

/// A platform identity paired with the public identity used by the protocol.
/// The private key never leaves the Keychain/Security framework object.
public final class ProvisionedIdentity: @unchecked Sendable {
    public let secIdentity: SecIdentity
    public let peerIdentity: DeviceIdentity

    public init(secIdentity: SecIdentity) throws {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(secIdentity, &certificate)
        guard status == errSecSuccess, let certificate else {
            throw SecurityCoreError.certificateUnavailable
        }
        guard let publicKey = SecCertificateCopyKey(certificate) else {
            throw SecurityCoreError.invalidPublicKey
        }
        var error: Unmanaged<CFError>?
        guard let publicKeyRepresentation = SecKeyCopyExternalRepresentation(
            publicKey,
            &error
        ) as Data? else {
            throw SecurityCoreError.invalidPublicKey
        }

        self.secIdentity = secIdentity
        self.peerIdentity = try DeviceIdentity(
            publicKeyRepresentation: publicKeyRepresentation
        )
    }
}

/// Loads only the public identity from a DER-encoded X.509 certificate.
///
/// Physical M2 smoke tests exchange these public certificates so each device
/// can pin its peer without ever copying the peer's private key. Production
/// enrollment may use a different certificate delivery mechanism, but the
/// identity derivation stays in SecurityCore so it remains identical to the
/// PKCS#12 and Network.framework paths.
public enum PublicCertificateIdentity {
    public static func load(from url: URL) throws -> DeviceIdentity {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw SecurityCoreError.certificateUnavailable
        }
        guard let publicKey = SecCertificateCopyKey(certificate) else {
            throw SecurityCoreError.invalidPublicKey
        }
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(
            publicKey,
            &error
        ) as Data? else {
            throw SecurityCoreError.invalidPublicKey
        }
        return try DeviceIdentity(publicKeyRepresentation: representation)
    }
}

/// Loads an identity already provisioned in the macOS Keychain or imports a
/// PKCS#12 bundle supplied by a provisioning/test workflow. Production code
/// should obtain the PKCS#12 data from its installer or enrollment flow; no
/// private key or certificate is stored in this repository.
public actor KeychainIdentityProvider {
    public static let defaultLabel = "MacRemoteApp"

    private let label: String?

    public init(label: String? = KeychainIdentityProvider.defaultLabel) {
        self.label = label
    }

    public func load() throws -> ProvisionedIdentity {
        var query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnRef: true
        ]
        if let label {
            query[kSecAttrLabel] = label
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result else {
            if status == errSecItemNotFound {
                throw SecurityCoreError.identityUnavailable
            }
            throw SecurityCoreError.keychain(status)
        }
        guard CFGetTypeID(result) == SecIdentityGetTypeID() else {
            throw SecurityCoreError.identityUnavailable
        }
        let identity = unsafeDowncast(result, to: SecIdentity.self)
        return try ProvisionedIdentity(secIdentity: identity)
    }

    public func importPKCS12(data: Data, password: String) throws -> ProvisionedIdentity {
        var items: CFArray?
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]
        let status = SecPKCS12Import(
            data as CFData,
            options as CFDictionary,
            &items
        )
        guard status == errSecSuccess,
              let items,
              let imported = items as? [[String: Any]],
              let first = imported.first,
              let identityValue = first[kSecImportItemIdentity as String],
              CFGetTypeID(identityValue as CFTypeRef) == SecIdentityGetTypeID() else {
            if status == errSecAuthFailed || status == errSecDecode {
                throw SecurityCoreError.invalidPKCS12
            }
            throw SecurityCoreError.keychain(status)
        }
        let identity = unsafeBitCast(identityValue as AnyObject, to: SecIdentity.self)
        return try ProvisionedIdentity(secIdentity: identity)
    }

    public func importPKCS12(at url: URL, password: String) throws -> ProvisionedIdentity {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try importPKCS12(data: data, password: password)
    }
}
