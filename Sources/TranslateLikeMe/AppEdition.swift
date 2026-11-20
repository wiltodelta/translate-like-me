@_exported import TranslateLikeMeBridgeKit
import Carbon
import Foundation

enum AppEdition: String, Equatable, Sendable {
    case direct
    case appStore

    static let current: Self = {
        let domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let argument = domain["appEdition"] as? String
        return resolve(bundleID: Bundle.main.bundleIdentifier, argument: argument,
                       compiledForAppStore: isCompiledForAppStore)
    }()

    static var isCompiledForAppStore: Bool {
        #if APP_STORE
        true
        #else
        false
        #endif
    }

    static func resolve(bundleID: String?, argument: String?, compiledForAppStore: Bool) -> Self {
        if let argument {
            if argument == "mas" || argument == "appStore" { return .appStore }
            if argument == "direct" { return .direct }
        }
        if compiledForAppStore { return .appStore }
        if let bundleID, bundleID == BridgeConfig.masBundleID || bundleID == BridgeConfig.masDevBundleID {
            return .appStore
        }
        return .direct
    }

    var supportsCLIEngines: Bool { self == .direct }
    var supportsSelfUpdate: Bool { self == .direct }
    var requiresOwnAccessibility: Bool { self == .direct }

    static let privacyURL = URL(string: "https://wiltodelta.com/projects/translate-like-me/privacy/")!
    static let supportURL = URL(string: "https://wiltodelta.com/projects/translate-like-me/support/")!

    func showsDirectInsertionHelp(canInsertDirectly: Bool) -> Bool {
        self == .appStore && !canInsertDirectly
    }

    // ⌥⌘K sits beside ⌥⌘J (Improve Text) and avoids macOS Dock's ⌥⌘D symbolic hotkey.
    static let appStoreDefaultDictationShortcut = KeyCombo(keyCode: 40, modifiers: Int(cmdKey | optionKey))

    var defaultDictationShortcut: KeyCombo {
        switch self {
        case .direct: KeyCombo(keyCode: 61, modifiers: Int(optionKey))
        case .appStore: Self.appStoreDefaultDictationShortcut
        }
    }

    func activeDictationShortcut(for combo: KeyCombo?, canInsertDirectly: Bool) -> KeyCombo? {
        guard let combo else { return nil }
        if self == .appStore, Shortcut.isOptionOnly(combo), !canInsertDirectly {
            return Self.appStoreDefaultDictationShortcut
        }
        return combo
    }
}
