import Darwin
import Foundation
import Security

let trustService = "com.rudinyu.MacRemoteApp.trust"
let deviceIdentityTag = Data("com.rudinyu.MacRemoteApp.device-identity".utf8)
var failures = 0

func deleteItems(_ query: [CFString: Any], description: String) {
    let status = SecItemDelete(query as CFDictionary)
    switch status {
    case errSecSuccess:
        print("Removed Keychain \(description)")
    case errSecItemNotFound:
        print("No Keychain \(description) found")
    default:
        fputs("Unable to remove Keychain \(description) (OSStatus \(status))\n", stderr)
        failures += 1
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

if failures > 0 {
    exit(1)
}
