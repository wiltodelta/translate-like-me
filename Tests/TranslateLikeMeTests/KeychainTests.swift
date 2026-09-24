import XCTest
@testable import TranslateLikeMe

// Uses the real login keychain under a throwaway service name, removed after.
final class KeychainTests: XCTestCase {
    private let service = "com.wiltodelta.translatelikeme.tests.\(UUID().uuidString)"

    override func tearDown() {
        for key in ["anthropicKey", "openaiKey"] { Keychain.write("", for: key, service: service) }
        super.tearDown()
    }

    private func requireKeychain() throws {
        Keychain.write("probe", for: "anthropicKey", service: service)
        guard Keychain.read("anthropicKey", service: service) == "probe" else {
            throw XCTSkip("No writable keychain in this environment")
        }
        Keychain.write("", for: "anthropicKey", service: service)
    }

    func testWriteReadAndEmptyDeletes() throws {
        try requireKeychain()
        Keychain.write("sk-one", for: "openaiKey", service: service)
        Keychain.write("sk-two", for: "openaiKey", service: service) // update in place
        XCTAssertEqual(Keychain.read("openaiKey", service: service), "sk-two")
        Keychain.write("", for: "openaiKey", service: service)
        XCTAssertNil(Keychain.read("openaiKey", service: service))
    }

    func testPlainTextKeysMoveToTheKeychainAndLeaveTheDefaults() throws {
        try requireKeychain()
        let name = "KeychainTests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        store.set("sk-ant-old", forKey: "anthropicKey")
        store.set("sk-new-default", forKey: "openaiKey")
        Keychain.write("sk-kept", for: "openaiKey", service: service) // already moved earlier

        Settings.moveAPIKeysToKeychain(from: store, service: service)

        XCTAssertEqual(Keychain.read("anthropicKey", service: service), "sk-ant-old")
        XCTAssertEqual(Keychain.read("openaiKey", service: service), "sk-kept")
        XCTAssertNil(store.object(forKey: "anthropicKey"))
        XCTAssertNil(store.object(forKey: "openaiKey"))
    }
}
