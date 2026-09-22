import Foundation
import Security

/// Creates the small self-signed certificate needed to present a Keychain
/// generated P-256 key through Network.framework. The certificate is a local
/// transport identity only; peer trust is established by SecurityCore's
/// explicit two-sided pairing flow.
enum LocalIdentityCertificate {
    private static let ecdsaWithSHA256OID: [UInt8] = [
        0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02
    ]
    private static let ecPublicKeyOID: [UInt8] = [
        0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01
    ]
    private static let prime256v1OID: [UInt8] = [
        0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07
    ]
    private static let commonNameOID: [UInt8] = [0x55, 0x04, 0x03]
    private static let basicConstraintsOID: [UInt8] = [0x55, 0x1D, 0x13]
    private static let keyUsageOID: [UInt8] = [0x55, 0x1D, 0x0F]
    private static let extendedKeyUsageOID: [UInt8] = [0x55, 0x1D, 0x25]
    private static let serverAuthOID: [UInt8] = [
        0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01
    ]
    private static let clientAuthOID: [UInt8] = [
        0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02
    ]

    static func make(
        privateKey: SecKey,
        commonName: String,
        now: Date = Date()
    ) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecurityCoreError.invalidPublicKey
        }

        var keyError: Unmanaged<CFError>?
        guard let publicKeyRepresentation = SecKeyCopyExternalRepresentation(
            publicKey,
            &keyError
        ) as Data?,
        publicKeyRepresentation.count == 65,
        publicKeyRepresentation.first == 0x04 else {
            throw SecurityCoreError.invalidPublicKey
        }

        let signatureAlgorithm = DER.sequence(
            DER.oid(ecdsaWithSHA256OID)
        )
        let subjectPublicKeyInfo = DER.sequence(
            DER.sequence(
                DER.oid(ecPublicKeyOID),
                DER.oid(prime256v1OID)
            ),
            DER.bitString(publicKeyRepresentation)
        )
        let subject = distinguishedName(commonName: commonName)
        let extensions = DER.sequence(
            DER.sequence(
                DER.oid(basicConstraintsOID),
                DER.boolean(true),
                DER.octetString(DER.sequence())
            ),
            DER.sequence(
                DER.oid(keyUsageOID),
                DER.boolean(true),
                DER.octetString(DER.bitString(Data([0x80]), unusedBitCount: 7))
            ),
            DER.sequence(
                DER.oid(extendedKeyUsageOID),
                DER.octetString(
                    DER.sequence(
                        DER.oid(serverAuthOID),
                        DER.oid(clientAuthOID)
                    )
                )
            )
        )

        let notBefore = now.addingTimeInterval(-300)
        let notAfter = now.addingTimeInterval(10 * 365 * 24 * 60 * 60)
        let tbsCertificate = DER.sequence(
            DER.explicit(tag: 0xA0, DER.integer(Data([0x02]))),
            DER.integer(serialNumber()),
            signatureAlgorithm,
            subject,
            DER.sequence(
                DER.generalizedTime(notBefore),
                DER.generalizedTime(notAfter)
            ),
            subject,
            subjectPublicKeyInfo,
            DER.explicit(tag: 0xA3, extensions)
        )

        var signatureError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsCertificate as CFData,
            &signatureError
        ) as Data? else {
            throw SecurityCoreError.identityEnrollmentFailed
        }

        return DER.sequence(
            tbsCertificate,
            signatureAlgorithm,
            DER.bitString(signature)
        )
    }

    private static func serialNumber() -> Data {
        let uuid = UUID().uuid
        let bytes = withUnsafeBytes(of: uuid) { Data($0) }
        return bytes
    }

    private static func distinguishedName(commonName: String) -> Data {
        let safeScalars = commonName.unicodeScalars.filter {
            $0.value >= 0x20 && $0.value != 0x7F
        }
        let boundedName = String(safeScalars.prefix(64).map { Character(String($0)) })
        let name = boundedName.isEmpty ? "MacRemoteApp" : boundedName
        return DER.sequence(
            DER.set(
                DER.sequence(
                    DER.oid(commonNameOID),
                    DER.utf8String(name)
                )
            )
        )
    }
}

private enum DER {
    static func element(tag: UInt8, _ value: Data) -> Data {
        Data([tag]) + length(value.count) + value
    }

    static func sequence(_ values: Data...) -> Data {
        element(tag: 0x30, values.reduce(into: Data()) { $0.append($1) })
    }

    static func set(_ values: Data...) -> Data {
        element(tag: 0x31, values.reduce(into: Data()) { $0.append($1) })
    }

    static func explicit(tag: UInt8, _ value: Data) -> Data {
        element(tag: tag, value)
    }

    static func integer(_ value: Data) -> Data {
        var bytes = Data(value.drop { $0 == 0 })
        if bytes.isEmpty {
            bytes = Data([0])
        }
        if bytes[bytes.startIndex] & 0x80 != 0 {
            bytes.insert(0, at: bytes.startIndex)
        }
        return element(tag: 0x02, bytes)
    }

    static func oid(_ value: [UInt8]) -> Data {
        element(tag: 0x06, Data(value))
    }

    static func utf8String(_ value: String) -> Data {
        element(tag: 0x0C, Data(value.utf8))
    }

    static func generalizedTime(_ value: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return element(tag: 0x18, Data(formatter.string(from: value).utf8))
    }

    static func boolean(_ value: Bool) -> Data {
        element(tag: 0x01, Data([value ? 0xFF : 0x00]))
    }

    static func octetString(_ value: Data) -> Data {
        element(tag: 0x04, value)
    }

    static func bitString(_ value: Data, unusedBitCount: UInt8 = 0) -> Data {
        element(tag: 0x03, Data([unusedBitCount]) + value)
    }

    private static func length(_ value: Int) -> Data {
        precondition(value >= 0)
        if value < 0x80 {
            return Data([UInt8(value)])
        }

        var value = value
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }
}
