import Foundation
import Security

package enum Keychain {
    private static let service = "com.reolens.cameraPassword"

    package static func set(password: String, for id: UUID) {
        let account = id.uuidString
        guard let data = password.data(using: .utf8) else { return }
        deletePassword(for: id)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            // Belt-and-suspenders: passwords are device-local by design
            // (AGENTS.md §4). Setting `kSecAttrSynchronizable` to false
            // explicitly ensures the item never lands in iCloud Keychain
            // even if the user enables Keychain sync system-wide.
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    package static func password(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    package static func deletePassword(for id: UUID) {
        // Match on `kSecAttrSynchronizableAny` so a possible legacy item
        // (pre-0.3.0, when we didn't set the attribute explicitly) is
        // also removed when the user updates their password.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(query as CFDictionary)
    }
}
