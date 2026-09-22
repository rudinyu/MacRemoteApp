import Darwin
import Foundation
import Security

let trustService = "com.rudinyu.MacRemoteApp.trust"
let deviceIdentityTag = Data("com.rudinyu.MacRemoteApp.device-identity".utf8)
let localTLSIdentityPrefix = "com.rudinyu.MacRemoteApp.local-tls-identity."
let localTLSCertificateService = "com.rudinyu.MacRemoteApp.local-tls-certificate"
let localTLSKeyReferenceService = "com.rudinyu.MacRemoteApp.local-tls-key-reference"
var failures = 0

@discardableResult
func deleteItems(_ query: [CFString: Any], description: String) -> Bool {
    let status = SecItemDelete(query as CFDictionary)
    switch status {
    case errSecSuccess:
        print("Removed Keychain \(description)")
        return true
    case errSecItemNotFound:
        print("No Keychain \(description) found")
        return true
    default:
        fputs("Unable to remove Keychain \(description) (OSStatus \(status))\n", stderr)
        failures += 1
        return false
    }
}

deleteItems(
    [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: trustService
    ],
    description: "MacRemoteApp trust records"
)

deleteItems(
    [
        kSecClass: kSecClassKey,
        kSecAttrApplicationTag: deviceIdentityTag
    ],
    description: "MacRemoteApp device identity key"
)

func matchingAttributes(_ query: [CFString: Any], description: String) -> [[String: Any]]? {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
        return []
    }
    guard status == errSecSuccess else {
        fputs("Unable to inspect Keychain \(description) (OSStatus \(status))\n", stderr)
        failures += 1
        return nil
    }
    guard let values = result as? [[String: Any]] else {
        fputs("Unable to inspect Keychain \(description) (unexpected result)\n", stderr)
        failures += 1
        return nil
    }
    return values
}

let certificateRecords = matchingAttributes(
    [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: localTLSCertificateService,
        kSecMatchLimit: kSecMatchLimitAll,
        kSecReturnAttributes: true,
        kSecReturnData: true
    ],
    description: "local TLS certificate records"
)

func certificatePublicKeyRepresentation(_ record: [String: Any]) -> Data? {
    guard let account = record[kSecAttrAccount as String] as? String,
          account.hasPrefix(localTLSIdentityPrefix),
          let certificateData = record[kSecValueData as String] as? Data,
          let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
          let publicKey = SecCertificateCopyKey(certificate) else {
        return nil
    }
    var error: Unmanaged<CFError>?
    return SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
}

func certificatePublicKeysByAccount(_ records: [[String: Any]]) -> [String: Data]? {
    var result: [String: Data] = [:]
    for record in records {
        guard let account = record[kSecAttrAccount as String] as? String,
              account.hasPrefix(localTLSIdentityPrefix) else {
            continue
        }
        guard let publicKey = certificatePublicKeyRepresentation(record) else {
            fputs("Unable to validate generated local TLS certificate \(account); leaving its Keychain records in place\n", stderr)
            failures += 1
            return nil
        }
        guard result[account] == nil else {
            fputs("Multiple generated local TLS certificates match Keychain account \(account); leaving its records in place\n", stderr)
            failures += 1
            return nil
        }
        result[account] = publicKey
    }
    return result
}

func generatedPrivateKeys() -> [SecKey]? {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(
        [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true
        ] as CFDictionary,
        &result
    )
    if status == errSecItemNotFound {
        return []
    }
    guard status == errSecSuccess, let result else {
        fputs("Unable to inspect local TLS identity keys (OSStatus \(status))\n", stderr)
        failures += 1
        return nil
    }
    if CFGetTypeID(result) == SecKeyGetTypeID() {
        return [unsafeDowncast(result, to: SecKey.self)]
    }
    guard let values = result as? [Any] else {
        fputs("Unable to inspect local TLS identity keys (unexpected result)\n", stderr)
        failures += 1
        return nil
    }
    return values.compactMap { value in
        guard CFGetTypeID(value as CFTypeRef) == SecKeyGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value as CFTypeRef, to: SecKey.self)
    }
}

func deleteGeneratedLocalTLSKeys(_ publicKeysByAccount: [String: Data]) -> Bool {
    let publicKeys = Set(publicKeysByAccount.values)
    guard !publicKeys.isEmpty else { return true }
    guard let privateKeys = generatedPrivateKeys() else {
        return false
    }

    var succeeded = true
    for privateKey in privateKeys {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { continue }
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              publicKeys.contains(representation) else {
            continue
        }
        if !deleteItems(
            [kSecValueRef: privateKey],
            description: "MacRemoteApp local TLS identity key"
        ) {
            succeeded = false
        }
    }
    return succeeded
}

func deleteGeneratedLocalTLSCertificates(_ records: [[String: Any]]) {
    for attributes in records {
        guard let account = attributes[kSecAttrAccount as String] as? String,
              account.hasPrefix(localTLSIdentityPrefix) else {
            continue
        }
        deleteItems(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: localTLSCertificateService,
                kSecAttrAccount: account
            ],
            description: "MacRemoteApp local TLS certificate \(account)"
        )
    }
}

func deleteGeneratedLocalTLSKeyReferences(
    _ values: [[String: Any]],
    certificatePublicKeys: [String: Data]
) -> Bool {
    var succeeded = true
    for attributes in values {
        guard let account = attributes[kSecAttrAccount as String] as? String,
              account.hasPrefix(localTLSIdentityPrefix),
              let persistentReference = attributes[kSecValueData as String] as? Data,
              let expectedPublicKey = certificatePublicKeys[account] else {
            fputs("Unable to validate a generated local TLS key reference; leaving it in place\n", stderr)
            failures += 1
            succeeded = false
            continue
        }

        var keyResult: CFTypeRef?
        let keyLookupStatus = SecItemCopyMatching(
            [
                kSecClass: kSecClassKey,
                kSecValuePersistentRef: persistentReference,
                kSecMatchLimit: kSecMatchLimitOne,
                kSecReturnRef: true
            ] as CFDictionary,
            &keyResult
        )
        if keyLookupStatus == errSecItemNotFound {
            // The key is already gone; deleting only this stale metadata is
            // safe because no private key can be affected.
        } else {
            guard keyLookupStatus == errSecSuccess,
                  let keyResult,
                  CFGetTypeID(keyResult) == SecKeyGetTypeID() else {
                fputs("Unable to inspect the private key for generated local TLS key reference \(account) (OSStatus \(keyLookupStatus)); leaving its records in place\n", stderr)
                failures += 1
                succeeded = false
                continue
            }
            let privateKey = unsafeDowncast(keyResult, to: SecKey.self)
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                fputs("Unable to inspect the public key for generated local TLS key reference \(account); leaving its records in place\n", stderr)
                failures += 1
                succeeded = false
                continue
            }
            var keyError: Unmanaged<CFError>?
            guard let actualPublicKey = SecKeyCopyExternalRepresentation(
                publicKey,
                &keyError
            ) as Data?, actualPublicKey == expectedPublicKey else {
                fputs("Generated local TLS key reference \(account) does not match its certificate; leaving its records in place\n", stderr)
                failures += 1
                succeeded = false
                continue
            }
            guard deleteItems(
                [kSecValueRef: privateKey],
                description: "MacRemoteApp local TLS identity key \(account)"
            ) else {
                succeeded = false
                continue
            }
        }

        guard deleteItems(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: localTLSKeyReferenceService,
                kSecAttrAccount: account
            ],
            description: "MacRemoteApp local TLS key reference \(account)"
        ) else {
            succeeded = false
        }
    }
    return succeeded
}

let keyReferenceRecords = matchingAttributes(
    [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: localTLSKeyReferenceService,
        kSecMatchLimit: kSecMatchLimitAll,
        kSecReturnAttributes: true,
        kSecReturnData: true
    ],
    description: "local TLS key references"
)

let certificatePublicKeys: [String: Data]?
if let certificateRecords {
    certificatePublicKeys = certificatePublicKeysByAccount(certificateRecords)
} else {
    certificatePublicKeys = nil
}

let legacyKeyCleanupSucceeded: Bool
if let certificatePublicKeys {
    legacyKeyCleanupSucceeded = deleteGeneratedLocalTLSKeys(certificatePublicKeys)
} else {
    legacyKeyCleanupSucceeded = false
}

let keyReferenceCleanupSucceeded: Bool
if let keyReferenceRecords, let certificatePublicKeys {
    keyReferenceCleanupSucceeded = deleteGeneratedLocalTLSKeyReferences(
        keyReferenceRecords,
        certificatePublicKeys: certificatePublicKeys
    )
} else {
    keyReferenceCleanupSucceeded = false
}

// Certificate records are removed only after both the legacy public-key
// cleanup and the persistent-reference cleanup have completed. If either
// inspection or deletion failed, retaining the certificate lets a later run
// still identify and remove the private key safely.
if let certificateRecords,
   legacyKeyCleanupSucceeded,
   keyReferenceCleanupSucceeded {
    deleteGeneratedLocalTLSCertificates(certificateRecords)
}

if failures > 0 {
    exit(1)
}
