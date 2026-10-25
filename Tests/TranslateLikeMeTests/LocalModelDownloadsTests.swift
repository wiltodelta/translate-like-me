import XCTest
@testable import TranslateLikeMe

@MainActor
final class LocalModelDownloadsTests: XCTestCase {
    func testRemovalAvailabilityTracksTheSelectedModel() {
        let downloads = LocalModelDownloads(removeModel: { _ in XCTFail("Availability must not remove files") })
        for selected in LocalModel.allCases {
            for model in LocalModel.allCases {
                XCTAssertEqual(downloads.canRemove(model, selected: selected), model != selected)
            }
        }
    }

    func testSwitchingModelsPersistsTheChoiceAndMovesRemovalProtection() {
        let defaults = UserDefaults.standard
        let savedModel = defaults.object(forKey: "localModel")
        let savedProvider = defaults.object(forKey: "provider")
        defer {
            defaults.set(savedModel, forKey: "localModel")
            defaults.set(savedProvider, forKey: "provider")
        }
        Settings.provider = .local
        let store = SettingsStore(refreshCatalog: { _ in })
        let downloads = LocalModelDownloads(removeModel: { _ in XCTFail("Switching must not remove files") })
        for model in LocalModel.allCases + LocalModel.allCases.reversed() {
            store.localModel = model
            XCTAssertEqual(Settings.localModel, model)
            XCTAssertEqual(SettingsStore(refreshCatalog: { _ in }).localModel, model)
            for candidate in LocalModel.allCases {
                XCTAssertEqual(downloads.canRemove(candidate, selected: store.localModel), candidate != model)
            }
        }
    }

    func testSelectedModelCannotBeRemoved() {
        let saved = UserDefaults.standard.object(forKey: "localModel")
        defer { UserDefaults.standard.set(saved, forKey: "localModel") }
        let downloads = LocalModelDownloads(removeModel: { _ in
            XCTFail("The selected model must never reach removal")
        })

        for model in LocalModel.allCases {
            Settings.localModel = model
            XCTAssertEqual(Settings.localModel, model)
            let state = downloads.state(of: model)
            downloads.remove(model)
            XCTAssertEqual(downloads.state(of: model), state, "Removal must be rejected synchronously")
        }
    }

    func testRemovalRechecksTheSelectionAfterConfirmation() {
        let saved = UserDefaults.standard.object(forKey: "localModel")
        defer { UserDefaults.standard.set(saved, forKey: "localModel") }
        let downloads = LocalModelDownloads(removeModel: { _ in XCTFail("A newly selected model must stay protected") })
        Settings.localModel = .gemma4E2B
        XCTAssertTrue(downloads.canRemove(.translateGemma12B, selected: Settings.localModel))
        let state = downloads.state(of: .translateGemma12B)

        // The selection changes after opening a confirmation for the other model.
        Settings.localModel = .translateGemma12B
        XCTAssertEqual(Settings.localModel, .translateGemma12B)
        downloads.remove(.translateGemma12B)
        XCTAssertEqual(downloads.state(of: .translateGemma12B), state)
    }
}
