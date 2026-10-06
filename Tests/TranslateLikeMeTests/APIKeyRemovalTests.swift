import Security
import XCTest
@testable import TranslateLikeMe

// The API-key mode was dropped; launch removes what it stored.
final class APIKeyRemovalTests: XCTestCase {
    private let service = "TranslateLikeMeTests-\(UUID().uuidString)"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func stored(_ account: String) -> Bool {
        SecItemCopyMatching(query(account) as CFDictionary, nil) == errSecSuccess
    }

    func testKeysModeAndPlainTextCopiesAreRemoved() {
        let name = "APIKeyRemovalTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer {
            suite.removePersistentDomain(forName: name)
            for account in ["anthropicKey", "openaiKey"] { SecItemDelete(query(account) as CFDictionary) }
        }
        for account in ["anthropicKey", "openaiKey"] {
            var add = query(account)
            add[kSecValueData as String] = Data("sk-test".utf8)
            XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        }
        suite.set("apiKey", forKey: "authMode")
        suite.set("sk-plain", forKey: "openaiKey")
        suite.set("anthropic", forKey: "provider")
        XCTAssertTrue(stored("anthropicKey"))

        Settings.removeAPIKeys(from: suite, service: service)

        XCTAssertFalse(stored("anthropicKey"))
        XCTAssertFalse(stored("openaiKey"))
        XCTAssertNil(suite.object(forKey: "authMode"))
        XCTAssertNil(suite.object(forKey: "openaiKey"))
        XCTAssertEqual(suite.string(forKey: "provider"), "anthropic")
    }
}
