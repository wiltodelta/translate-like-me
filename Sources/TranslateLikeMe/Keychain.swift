import Foundation
import os
import Security

private let log = Logger.app("keychain")

// API keys as generic passwords in the login keychain, one item per account
// under the app's bundle identifier as the service. Items the app creates are
// readable by the same signed app without a prompt.
enum Keychain {
    static let service = "com.wiltodelta.translatelikeme"

    static func read(_ account: String, service: String = service) -> String? {
        var query = base(account, service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound { log.error("Keychain read \(account) failed: \(status)") }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // An empty value deletes the item.
    static func write(_ value: String, for account: String, service: String = service) {
        let query = base(account, service)
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                log.error("Keychain delete \(account) failed: \(status)")
            }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { log.error("Keychain write \(account) failed: \(status)") }
    }

    private static func base(_ account: String, _ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
