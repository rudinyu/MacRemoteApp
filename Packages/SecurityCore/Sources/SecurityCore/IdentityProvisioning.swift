import CryptoKit
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

/// A deliberately unchecked wrapper used only by isolated tests and other
/// tightly scoped Keychain callers. Production identity enrollment leaves this
/// nil and uses the user's login Keychain through Security.framework defaults.
public final class KeychainReference: @unchecked Sendable {
    public let raw: SecKeychain

    public init(_ raw: SecKeychain) {
        self.raw = raw
    }
}

/// Loads an identity already provisioned in the macOS Keychain, or enrolls a
/// new local TLS identity on first use. PKCS#12 import remains available for
/// the physical M2 diagnostic workflow only; production callers should use
/// `loadOrCreate()` so a user never has to copy a private key between Macs.
public actor KeychainIdentityProvider {
    public static let defaultLabel = "MacRemoteApp"
    public static let defaultApplicationTag = "com.rudinyu.MacRemoteApp.local-tls-identity"
    public static let defaultCertificateService = "com.rudinyu.MacRemoteApp.local-tls-certificate"
    public static let defaultKeyReferenceService = "com.rudinyu.MacRemoteApp.local-tls-key-reference"

    private let label: String?
    private let applicationTag: Data
    private let certificateAccount: String
    private let keychain: KeychainReference?

    public init(
        label: String? = KeychainIdentityProvider.defaultLabel,
        applicationTag: String? = nil,
        keychain: KeychainReference? = nil
    ) {
        self.label = label
        let tag = applicationTag ?? "\(Self.defaultApplicationTag).\(label ?? "unlabeled")"
        self.applicationTag = Data(tag.utf8)
        self.certificateAccount = tag
        self.keychain = keychain
    }

    public func load() throws -> ProvisionedIdentity {
        guard let label else {
            throw SecurityCoreError.identityUnavailable
        }

        let query = scoped([
            kSecClass: kSecClassIdentity,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
            kSecReturnRef: true
        ])

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result else {
            if status == errSecItemNotFound {
                throw SecurityCoreError.identityUnavailable
            }
            throw SecurityCoreError.keychain(status)
        }

        let values: [Any]
        if let array = result as? [Any] {
            values = array
        } else {
            values = [result]
        }

        // Security.framework may ignore kSecAttrLabel in an identity query on
        // some macOS Keychain stores. Filter the returned attribute/ref pairs
        // ourselves so an unrelated imported identity can never be selected.
        // The certificate CN is intentionally not part of this decision: a
        // legacy identity may use an operator-selected CN.
        var candidates: [(label: String, identity: SecIdentity)] = []
        for value in values {
            guard let attributes = value as? [String: Any],
                  let candidateLabel = attributes[kSecAttrLabel as String] as? String,
                  let identityValue = attributes[kSecValueRef as String],
                  CFGetTypeID(identityValue as CFTypeRef) == SecIdentityGetTypeID() else {
                continue
            }
            candidates.append(
                (
                    label: candidateLabel,
                    identity: unsafeDowncast(identityValue as CFTypeRef, to: SecIdentity.self)
                )
            )
        }
        let identity = try Self.selectIdentity(from: candidates, label: label)
        return try ProvisionedIdentity(secIdentity: identity)
    }

    /// Applies the fail-closed label selection rule after Keychain has
    /// returned candidate identity records. The label is descriptive rather
    /// than a unique identity key, so enumeration order must never select a
    /// different paired endpoint when duplicates exist.
    static func selectIdentity(
        from candidates: [(label: String, identity: SecIdentity)],
        label: String
    ) throws -> SecIdentity {
        let matches = candidates.filter { $0.label == label }
        guard !matches.isEmpty else {
            throw SecurityCoreError.identityUnavailable
        }
        guard matches.count == 1, let identity = matches.first?.identity else {
            throw SecurityCoreError.identityAmbiguous
        }
        return identity
    }

    /// Loads an existing identity or creates one locally in the login
    /// Keychain. The private key is generated by Security.framework and is
    /// never exported. The certificate is only the public half needed to
    /// present that key through Network.framework; peer trust is still
    /// established by the explicit pairing coordinator.
    public func loadOrCreate() throws -> ProvisionedIdentity {
        // Preserve the identity created by the previous provisioning path.
        // Peer trust records are keyed by its public-key fingerprint, so
        // silently rotating to a new generated key during an app upgrade
        // would force every paired device to re-pair.
        do {
            return try load()
        } catch SecurityCoreError.identityUnavailable {
            // No compatible legacy identity exists; continue with local
            // enrollment below.
        }

        let existingCertificateData = try loadGeneratedCertificateData()
        let expectedIdentity = try existingCertificateData.map(certificateIdentity(from:))
        let existingPrivateKey: SecKey?
        if expectedIdentity != nil {
            existingPrivateKey = try loadGeneratedPrivateKey(expectedIdentity: expectedIdentity)
        } else {
            existingPrivateKey = try loadGeneratedPrivateKeyWithoutCertificate()
        }
        guard existingCertificateData == nil || existingPrivateKey != nil else {
            throw SecurityCoreError.identityEnrollmentFailed
        }

        let createdPrivateKey = existingPrivateKey == nil
        let privateKey = try existingPrivateKey ?? createGeneratedPrivateKey()
        var certificateClaimed = false
        defer {
            if createdPrivateKey && !certificateClaimed {
                try? deleteKey(privateKey)
            }
        }
        let certificateData: Data
        if let existingCertificateData {
            certificateData = existingCertificateData
        } else {
            certificateData = try LocalIdentityCertificate.make(
                privateKey: privateKey,
                commonName: label ?? Self.defaultLabel
            )
        }

        let identity = try makeIdentity(
            privateKey: privateKey,
            certificateData: certificateData
        )
        if let existingCertificateData {
            if try certificateIdentity(from: existingCertificateData) != identity.peerIdentity {
                throw SecurityCoreError.identityEnrollmentFailed
            }
            return identity
        }

        // SecItemAdd is the enrollment claim. If another process wins the
        // same account between our initial read and this add, adopt its
        // certificate and matching private key instead of overwriting the
        // winner with a newly generated identity.
        if try saveGeneratedCertificateDataIfAbsent(certificateData) {
            certificateClaimed = true
            try saveGeneratedKeyReference(for: privateKey)
            return identity
        }

        guard let winningCertificateData = try loadGeneratedCertificateData(),
              let winningIdentity = try? certificateIdentity(from: winningCertificateData),
              let winningPrivateKey = try findGeneratedPrivateKey(expectedIdentity: winningIdentity) else {
            throw SecurityCoreError.identityEnrollmentFailed
        }
        try saveGeneratedKeyReference(for: winningPrivateKey)
        return try makeIdentity(
            privateKey: winningPrivateKey,
            certificateData: winningCertificateData
        )
    }

    /// Removes only the local identity generated by `loadOrCreate()`. It does
    /// not remove an imported PKCS#12 identity or any peer trust records.
    public func removeGeneratedIdentity() throws {
        guard let certificateData = try loadGeneratedCertificateData() else {
            // A persistent reference without its certificate cannot be
            // safely associated with a public key. Leave both records in
            // place rather than risking deletion of an unrelated key.
            guard try loadGeneratedKeyReference() == nil else {
                throw SecurityCoreError.identityEnrollmentFailed
            }
            return
        }
        let expectedIdentity = try certificateIdentity(from: certificateData)
        var removedPrivateKey = false
        if let keyReference = try loadGeneratedKeyReference() {
            if let privateKey = try loadPrivateKey(persistentReference: keyReference) {
                let matchesExpectedIdentity = (try? identity(for: privateKey)) == expectedIdentity
                if matchesExpectedIdentity {
                    try deleteKey(privateKey)
                    removedPrivateKey = true
                }
            }
        }
        if !removedPrivateKey,
           let privateKey = try findGeneratedPrivateKey(expectedIdentity: expectedIdentity) {
            try deleteKey(privateKey)
            removedPrivateKey = true
        }

        let keyReferenceStatus = SecItemDelete(scoped(generatedKeyReferenceQuery()) as CFDictionary)
        guard keyReferenceStatus == errSecSuccess || keyReferenceStatus == errSecItemNotFound else {
            throw SecurityCoreError.keychain(keyReferenceStatus)
        }

        let certificateStatus = SecItemDelete(scoped(generatedCertificateQuery()) as CFDictionary)
        guard certificateStatus == errSecSuccess || certificateStatus == errSecItemNotFound else {
            throw SecurityCoreError.keychain(certificateStatus)
        }
    }

    private func deleteKey(_ privateKey: SecKey) throws {
        let status = SecItemDelete(
            [kSecValueRef: privateKey] as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecurityCoreError.keychain(status)
        }
    }

    private func loadGeneratedPrivateKey(expectedIdentity: DeviceIdentity?) throws -> SecKey? {
        guard let expectedIdentity else {
            if try loadGeneratedKeyReference() != nil {
                throw SecurityCoreError.identityEnrollmentFailed
            }
            return nil
        }

        // The persistent reference is the normal recovery path, but it can
        // become stale after a Keychain migration or restore. Fall back to
        // the retained certificate's public key and repair the reference
        // instead of rotating a paired identity or failing permanently.
        if let keyReference = try loadGeneratedKeyReference(),
           let privateKey = try loadPrivateKey(persistentReference: keyReference),
           let actualIdentity = try? identity(for: privateKey),
           actualIdentity == expectedIdentity {
            return privateKey
        }

        guard let privateKey = try findGeneratedPrivateKey(expectedIdentity: expectedIdentity) else {
            return nil
        }
        try saveGeneratedKeyReference(for: privateKey)
        return privateKey
    }

    /// Recovers a key left behind if enrollment failed before its certificate
    /// or persistent-reference record was saved. The application tag is the
    /// provider's exact namespace; unlike a human-readable label it is not
    /// treated as a fuzzy selector.
    private func loadGeneratedPrivateKeyWithoutCertificate() throws -> SecKey? {
        // If only the certificate metadata was lost, the persistent reference
        // still gives us a continuity-preserving recovery path. The lookup is
        // constrained to this provider's exact private-key namespace below;
        // a stale reference simply falls through to the application-tag scan.
        if let keyReference = try loadGeneratedKeyReference(),
           let privateKey = try loadPrivateKey(persistentReference: keyReference) {
            return privateKey
        }

        let query = scoped([
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag: applicationTag,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true
        ])
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let result else {
            throw SecurityCoreError.keychain(status)
        }

        let candidates: [SecKey]
        if CFGetTypeID(result) == SecKeyGetTypeID() {
            candidates = [unsafeDowncast(result, to: SecKey.self)]
        } else if let values = result as? [Any] {
            candidates = values.compactMap { value in
                guard CFGetTypeID(value as CFTypeRef) == SecKeyGetTypeID() else {
                    return nil
                }
                return unsafeDowncast(value as CFTypeRef, to: SecKey.self)
            }
        } else {
            candidates = []
        }
        guard candidates.count <= 1 else {
            throw SecurityCoreError.identityAmbiguous
        }
        return candidates.first
    }

    // Older generated identities did not store a persistent reference. Find
    // their private key by matching the public key in the retained
    // certificate instead of trusting a broad Keychain attribute query.
    private func findGeneratedPrivateKey(expectedIdentity: DeviceIdentity) throws -> SecKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let result else {
            throw SecurityCoreError.keychain(status)
        }

        let candidates: [SecKey]
        if CFGetTypeID(result) == SecKeyGetTypeID() {
            candidates = [unsafeDowncast(result, to: SecKey.self)]
        } else if let values = result as? [Any] {
            candidates = values.compactMap { value in
                guard CFGetTypeID(value as CFTypeRef) == SecKeyGetTypeID() else {
                    return nil
                }
                return unsafeDowncast(value as CFTypeRef, to: SecKey.self)
            }
        } else {
            candidates = []
        }

        for privateKey in candidates where (try? identity(for: privateKey)) == expectedIdentity {
            return privateKey
        }
        return nil
    }

    private func loadPrivateKey(persistentReference: Data) throws -> SecKey? {
        let query = scoped([
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag: applicationTag,
            kSecValuePersistentRef: persistentReference,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnRef: true
        ])
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let result,
              CFGetTypeID(result) == SecKeyGetTypeID() else {
            throw SecurityCoreError.keychain(status)
        }
        return unsafeDowncast(result, to: SecKey.self)
    }

    private func identity(for privateKey: SecKey) throws -> DeviceIdentity {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecurityCoreError.invalidPublicKey
        }
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw SecurityCoreError.invalidPublicKey
        }
        return try DeviceIdentity(publicKeyRepresentation: representation)
    }

    private func loadGeneratedKeyReference() throws -> Data? {
        var query = scoped(generatedKeyReferenceQuery())
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecurityCoreError.keychain(status)
        }
        guard let data = result as? Data else {
            throw SecurityCoreError.identityEnrollmentFailed
        }
        return data
    }

    private func saveGeneratedKeyReference(for privateKey: SecKey) throws {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            scoped([
                kSecClass: kSecClassKey,
                kSecValueRef: privateKey,
                kSecReturnPersistentRef: true
            ]) as CFDictionary,
            &result
        )
        guard status == errSecSuccess, let reference = result as? Data else {
            throw SecurityCoreError.identityEnrollmentFailed
        }
        var query = scopedForAdd(generatedKeyReferenceQuery())
        query[kSecValueData] = reference
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw SecurityCoreError.keychain(addStatus)
        }
        let updateStatus = SecItemUpdate(
            scoped(generatedKeyReferenceQuery()) as CFDictionary,
            [kSecValueData: reference] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw SecurityCoreError.keychain(updateStatus)
        }
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

    private func createGeneratedPrivateKey() throws -> SecKey {
        var attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrLabel: generatedKeyLabel,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: applicationTag,
                kSecAttrLabel: generatedKeyLabel,
                kSecAttrIsSensitive: true,
                kSecAttrIsExtractable: false
            ]
        ]
        if let keychain {
            attributes[kSecUseKeychain] = keychain.raw
        }
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SecurityCoreError.keychain(
                OSStatus((error?.takeRetainedValue() as NSError?)?.code ?? Int(errSecParam))
            )
        }
        return privateKey
    }

    private func loadGeneratedPrivateKey() throws -> SecKey? {
        for query in [generatedPrivateKeyQuery(), legacyGeneratedPrivateKeyQuery()] {
            var query = query
            query[kSecReturnRef] = true

            var result: CFTypeRef?
            let status = SecItemCopyMatching(scoped(query) as CFDictionary, &result)
            if status == errSecItemNotFound {
                continue
            }
            guard status == errSecSuccess else {
                throw SecurityCoreError.keychain(status)
            }
            guard let result, CFGetTypeID(result) == SecKeyGetTypeID() else {
                throw SecurityCoreError.identityEnrollmentFailed
            }
            return unsafeDowncast(result, to: SecKey.self)
        }
        return nil
    }

    private func generatedPrivateKeyQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrLabel: generatedKeyLabel,
            kSecMatchLimit: kSecMatchLimitOne
        ]
    }

    private func legacyGeneratedPrivateKeyQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag: applicationTag,
            kSecAttrLabel: label ?? Self.defaultLabel,
            kSecMatchLimit: kSecMatchLimitOne
        ]
    }

    private func scoped(_ query: [CFString: Any]) -> [CFString: Any] {
        // kSecUseKeychain selects the destination for SecItemAdd on macOS;
        // it is not a search filter for SecItemCopyMatching/Update/Delete.
        // Read operations use the process keychain search list instead.
        query
    }

    private func scopedForAdd(_ query: [CFString: Any]) -> [CFString: Any] {
        guard let keychain else { return query }
        var scopedQuery = query
        scopedQuery[kSecUseKeychain] = keychain.raw
        return scopedQuery
    }

    private var generatedKeyLabel: String {
        let digest = SHA256.hash(data: applicationTag)
            .map { String(format: "%02x", $0) }
            .joined()
        return "MacRemoteApp TLS Identity \(digest)"
    }

    private func loadGeneratedCertificateData() throws -> Data? {
        var query = scoped(generatedCertificateQuery())
        query[kSecReturnData] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecurityCoreError.keychain(status)
        }
        guard let data = result as? Data else {
            throw SecurityCoreError.certificateUnavailable
        }
        return data
    }

    private func generatedCertificateQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.defaultCertificateService,
            kSecAttrAccount: certificateAccount,
            kSecMatchLimit: kSecMatchLimitOne
        ]
    }

    private func generatedKeyReferenceQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.defaultKeyReferenceService,
            kSecAttrAccount: certificateAccount,
            kSecMatchLimit: kSecMatchLimitOne
        ]
    }

    /// Attempts to claim the certificate metadata record exactly once.
    ///
    /// The Keychain add is intentionally not followed by an update. A
    /// duplicate means another process already owns this provider namespace;
    /// the caller must reload and adopt that identity.
    private func saveGeneratedCertificateDataIfAbsent(_ data: Data) throws -> Bool {
        var query = scopedForAdd(generatedCertificateQuery())
        query[kSecValueData] = data
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return true
        }
        if addStatus == errSecDuplicateItem {
            return false
        }
        throw SecurityCoreError.keychain(addStatus)
    }

    private func makeIdentity(
        privateKey: SecKey,
        certificateData: Data
    ) throws -> ProvisionedIdentity {
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
              let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw SecurityCoreError.identityEnrollmentFailed
        }
        return try ProvisionedIdentity(secIdentity: identity)
    }

    private func certificateIdentity(from data: Data) throws -> DeviceIdentity {
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData),
              let publicKey = SecCertificateCopyKey(certificate) else {
            throw SecurityCoreError.certificateUnavailable
        }
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw SecurityCoreError.invalidPublicKey
        }
        return try DeviceIdentity(publicKeyRepresentation: representation)
    }

}
