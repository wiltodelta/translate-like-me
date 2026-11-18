import AppKit
import Carbon
import CoreAudio
import Foundation
import XCTest
@testable import TranslateLikeMe
import TranslateLikeMeBridgeKit

@MainActor
final class AppEditionAndBridgeTests: XCTestCase {
    func testEditionResolutionAndCapabilities() {
        XCTAssertEqual(
            AppEdition.resolve(bundleID: "com.wiltodelta.translatelikeme", argument: nil, compiledForAppStore: false),
            .direct
        )
        XCTAssertEqual(
            AppEdition.resolve(bundleID: "com.wiltodelta.translatelikeme.mas", argument: nil,
                               compiledForAppStore: false),
            .appStore
        )
        XCTAssertEqual(
            AppEdition.resolve(bundleID: "com.wiltodelta.translatelikeme.mas.dev", argument: nil,
                               compiledForAppStore: false),
            .appStore
        )
        XCTAssertEqual(
            AppEdition.resolve(bundleID: "com.wiltodelta.translatelikeme", argument: "mas",
                               compiledForAppStore: false),
            .appStore
        )
        XCTAssertEqual(
            AppEdition.resolve(bundleID: "com.wiltodelta.translatelikeme.mas", argument: "direct",
                               compiledForAppStore: true),
            .direct
        )

        XCTAssertTrue(AppEdition.direct.supportsCLIEngines)
        XCTAssertTrue(AppEdition.direct.supportsSelfUpdate)
        XCTAssertTrue(AppEdition.direct.requiresOwnAccessibility)

        XCTAssertFalse(AppEdition.appStore.supportsCLIEngines)
        XCTAssertFalse(AppEdition.appStore.supportsSelfUpdate)
        XCTAssertFalse(AppEdition.appStore.requiresOwnAccessibility)
        let appStoreDefault = KeyCombo(keyCode: 40, modifiers: Int(cmdKey | optionKey))
        let rightOption = KeyCombo(keyCode: 61, modifiers: Int(optionKey))
        XCTAssertEqual(AppEdition.appStore.defaultDictationShortcut, appStoreDefault)
        XCTAssertEqual(AppEdition.appStore.activeDictationShortcut(for: rightOption, canInsertDirectly: false),
                       appStoreDefault)
        XCTAssertEqual(AppEdition.appStore.activeDictationShortcut(for: rightOption, canInsertDirectly: true),
                       rightOption)
        XCTAssertEqual(AppEdition.direct.activeDictationShortcut(for: rightOption, canInsertDirectly: false),
                       rightOption)
    }

    func testStatusMenuOmitsCheckForUpdatesInAppStoreMode() {
        let controller = DictationController(
            enabled: false,
            engine: ControlledDictationEngine(),
            recorder: ControlledDictationRecorder(),
            interaction: DictationInteraction(endCapture: {}, showError: { _ in }, showResult: { _ in }, deliver: nil)
        )
        let masMenu = StatusMenu(dictation: { controller }, pendingUpdate: { "9.9.9" }, showsUpdates: false)
        masMenu.rebuild()
        let masTitles = masMenu.menu.items.map(\.title)
        XCTAssertFalse(masTitles.contains(String(localized: "Check for Updates…")))
        XCTAssertFalse(masTitles.contains(String(localized: "Install Update…")))
        XCTAssertTrue(masTitles.contains(String(localized: "Settings…")))

        let directMenu = StatusMenu(dictation: { controller }, pendingUpdate: { nil }, showsUpdates: true)
        directMenu.rebuild()
        XCTAssertTrue(directMenu.menu.items.map(\.title).contains(String(localized: "Check for Updates…")))
    }

    func testAppStoreOnboardingCompletesWithMicrophoneOnly() async {
        var mic = false
        var openedAccessibility = false
        var completed = false
        let flow = OnboardingFlow(
            effects: .init(
                speech: { $0(1) },
                translation: {},
                translationState: { .ready },
                cancelDownload: {},
                microphoneGranted: { mic },
                accessibilityGranted: { false },
                requestMicrophone: { mic = true; return true },
                openMicrophoneSettings: {},
                openAccessibilitySettings: { openedAccessibility = true },
                activateDictation: {},
                complete: { completed = true }
            ),
            requiresAccessibility: false
        )
        flow.prepare()
        await flow.operation?.value
        XCTAssertTrue(flow.modelsReady)
        flow.continueFromPreparation()
        XCTAssertEqual(flow.step, .permissions)

        flow.permissionAction()
        await flow.operation?.value
        XCTAssertTrue(flow.permissionsReady)

        flow.permissionAction()
        await flow.operation?.value
        XCTAssertEqual(flow.step, .usage)
        XCTAssertFalse(openedAccessibility)
        XCTAssertTrue(flow.finish())
        XCTAssertTrue(completed)
    }

    func testSandboxedFallbacksWithoutBridgeConnected() async throws {
        let socketURL = URL(fileURLWithPath: "/tmp/tlm-absent-\(UUID().uuidString.prefix(8)).sock")
        let clipboard = FakeClipboardBox("Bonjour")
        let client = BridgeClient(socketURL: socketURL, policy: .sameUserOnly, autoStart: false,
                                  readClipboardText: { clipboard.text })
        defer { client.stop() }

        var recorded: String?
        let outcome = try await client.runSelection(
            recordResult: { text in await MainActor.run { recorded = text } },
            transform: { "Translated: \($0)" }
        )
        XCTAssertEqual(outcome, .result("Translated: Bonjour"))
        XCTAssertEqual(recorded, "Translated: Bonjour")

        clipboard.text = "   "
        let emptyOutcome = try await client.runSelection(
            recordResult: { _ in },
            transform: { $0 }
        )
        XCTAssertEqual(emptyOutcome, .emptyClipboard)

        let delivered = try await client.deliverDictation(
            "Hello world.",
            vocabulary: .empty,
            languageIdentifiers: ["en"]
        )
        XCTAssertFalse(delivered)
    }

    func testLiveBridgeSelectionDictationAndSnapshotOverUnixSocket() async throws {
        let harness = try LiveBridgeHarness()
        defer { harness.tearDown() }

        try await waitUntil { harness.client.isConnected }
        XCTAssertFalse(harness.client.canInsertDirectly)
        XCTAssertEqual(harness.client.bridgeVersion, "3.7.21")

        harness.trusted = true
        harness.coordinator.broadcastTrustIfChanged(true)
        try await waitUntil { harness.client.canInsertDirectly }

        let selectionOutcome = try await harness.client.runSelection(
            recordResult: { _ in },
            transform: { "Polished: \($0)" }
        )
        XCTAssertEqual(selectionOutcome, .pasted)
        XCTAssertEqual(harness.finishedReplacement, .some("Polished: Rough notes"))

        let inserted = try await harness.client.deliverDictation(
            "Schnell erledigt.",
            vocabulary: .empty,
            languageIdentifiers: ["de", "en"]
        )
        XCTAssertTrue(inserted)
        XCTAssertEqual(harness.deliveredDictation?.0, 4242)
        XCTAssertEqual(harness.deliveredDictation?.1, "schnell erledigt.")

        let snapshot = await harness.client.fetchDictationSnapshot()
        XCTAssertEqual(snapshot.appName, "Notes")
        XCTAssertEqual(snapshot.windowTitle, "Draft")
    }

    func testLiveBridgeOptionEventsAndDisconnectMuteCleanup() async throws {
        let harness = try LiveBridgeHarness()
        defer { harness.tearDown() }
        harness.trusted = true
        try await waitUntil { harness.client.isConnected }
        harness.coordinator.broadcastTrustIfChanged(true)
        try await waitUntil { harness.client.canInsertDirectly }

        let secondClient = BridgeClient(socketURL: harness.socketURL, policy: .sameUserOnly, autoStart: true,
                                        readClipboardText: { nil })
        defer { secondClient.stop() }
        try await waitUntil { secondClient.isConnected && harness.connectedCount == 2 }

        harness.coordinator.sendEvent(.optionAction(.press))
        harness.coordinator.sendEvent(.optionAction(.release))
        try await waitUntil { harness.receivedOptionActions == [.press, .release] }

        harness.client.setOutputMuted(true)
        try await waitUntil { harness.muteControl.mutedState == true }
        harness.client.stop()
        try await waitUntil { harness.connectedCount == 1 && harness.muteControl.mutedState == false }
    }

    func testSystemServicesProviderReplacesSelectionInPlace() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("Hello service", forType: .string)

        let results = LastResults.shared
        SystemServicesProvider.shared.performService(on: board, kind: .translation, error: nil) { input in
            "Привет: \(input)"
        }
        XCTAssertEqual(board.string(forType: .string), "Привет: Hello service")
        XCTAssertEqual(results[.translation], "Привет: Hello service")
    }

    private func waitUntil(timeout: Duration = .seconds(3),
                           condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
}

@MainActor
private final class LiveBridgeHarness {
    let dir: URL
    let socketURL: URL
    let muteSuiteName: String
    let muteDefaults: UserDefaults
    let muteControl = FakeMuteControl()
    var trusted = false
    var connectedCount = 0
    var finishedReplacement: String??
    var deliveredDictation: (pid_t, String)?
    var receivedOptionActions: [OptionKeyGesture.Action] = []
    private(set) var coordinator: BridgeHostCoordinator!
    private(set) var server: BridgeServer!
    private(set) var client: BridgeClient!

    init() throws {
        let shortID = String(UUID().uuidString.prefix(8))
        dir = URL(fileURLWithPath: "/tmp/tlm-b-\(shortID)", isDirectory: true)
        socketURL = dir.appendingPathComponent("s")
        muteSuiteName = "BridgeMute-\(shortID)"
        muteDefaults = try XCTUnwrap(UserDefaults(suiteName: muteSuiteName))
        coordinator = BridgeHostCoordinator(
            dependencies: .init(
                version: { "3.7.21" },
                isTrusted: { [weak self] in self?.trusted ?? false },
                startSelection: { [weak self] in
                    FakeBridgeSelectionSession(copiedText: "Rough notes") { replacement in
                        self?.finishedReplacement = replacement
                        return replacement != nil
                    }
                },
                dictationTarget: {
                    DictationInsertionTarget(
                        pid: 4242,
                        context: DictationInsertionContext(beforeSlice: "Bitte, ", afterSlice: "")
                    )
                },
                deliverDictation: { [weak self] pid, formatted in
                    self?.deliveredDictation = (pid, formatted)
                    return true
                },
                dictationSnapshot: {
                    DictationDestinationSnapshot(appName: "Notes", windowTitle: "Draft", surroundingText: "Context")
                },
                mute: DictationOutputMute(control: muteControl, store: muteDefaults)
            )
        )
        let host = coordinator!
        server = BridgeServer(
            socketURL: socketURL,
            policy: .sameUserOnly,
            onClientCountChanged: { [weak self] count in
                Task { @MainActor in self?.connectedCount = count }
            },
            onClientDisconnected: { clientID in
                Task { @MainActor in host.clientDisconnected(clientID) }
            },
            onRequest: { clientID, request in
                await host.handle(clientID: clientID, request: request)
            }
        )
        coordinator.sendEvent = { [weak server] event in server?.broadcast(event) }
        XCTAssertTrue(server.start())
        client = BridgeClient(socketURL: socketURL, policy: .sameUserOnly, autoStart: true,
                              readClipboardText: { nil })
        client.onOptionAction = { [weak self] in self?.receivedOptionActions.append($0) }
    }

    func tearDown() {
        client.stop()
        server.stop()
        muteDefaults.removePersistentDomain(forName: muteSuiteName)
        try? FileManager.default.removeItem(at: dir)
    }
}

@MainActor
private final class FakeClipboardBox {
    var text: String?
    init(_ text: String?) { self.text = text }
}

@MainActor
private struct FakeBridgeSelectionSession: BridgeSelectionSessionHandling {
    let copiedText: String
    let onFinish: @MainActor (String?) async -> Bool

    func finish(replacement: String?) async -> Bool {
        await onFinish(replacement)
    }
}

private final class FakeMuteControl: DictationOutputControl, @unchecked Sendable {
    var mutedState = false
    func defaultOutput() -> AudioObjectID? { 77 }
    func isMuted(_ device: AudioObjectID) -> Bool? { mutedState }
    func setMuted(_ device: AudioObjectID, _ muted: Bool) -> Bool {
        mutedState = muted
        return true
    }
    func uid(of device: AudioObjectID) -> String? { "fake-speakers" }
    func device(uid: String) -> AudioObjectID? { uid == "fake-speakers" ? 77 : nil }
}
