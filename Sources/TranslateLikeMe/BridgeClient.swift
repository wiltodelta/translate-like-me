import AppKit
import Foundation
import Observation
import os
import SwiftUI

private let bridgeClientLog = Logger.app("bridge")

@MainActor
@Observable
final class BridgeClient {
    static let shared = BridgeClient()

    private(set) var state: BridgeConnectionClient.ConnectionState = .disconnected

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var isAccessibilityTrusted: Bool {
        if case .connected(let trusted, _) = state { return trusted }
        return false
    }

    var bridgeVersion: String? {
        if case .connected(_, let version) = state { return version }
        return nil
    }

    var canInsertDirectly: Bool { isAccessibilityTrusted }

    @ObservationIgnored private var transport: BridgeConnectionClient?
    @ObservationIgnored private let explicitSocketURL: URL?
    @ObservationIgnored private let policy: BridgePeerPolicy
    @ObservationIgnored private let readClipboardText: @MainActor () -> String?
    @ObservationIgnored var onAvailabilityChanged: (@MainActor () -> Void)?
    @ObservationIgnored var onOptionAction: (@MainActor (OptionKeyGesture.Action) -> Void)?

    init(socketURL: URL? = nil,
         policy: BridgePeerPolicy = .production,
         autoStart: Bool = false,
         readClipboardText: @escaping @MainActor () -> String? = { NSPasteboard.general.string(forType: .string) }) {
        self.explicitSocketURL = socketURL
        self.policy = policy
        self.readClipboardText = readClipboardText
        if autoStart { startTransport() }
    }

    func startIfNeeded() {
        guard AppEdition.current == .appStore else { return }
        startTransport()
    }

    private func startTransport() {
        if transport == nil {
            let url = explicitSocketURL ?? BridgeConfig.defaultSocketURL()
            transport = BridgeConnectionClient(
                socketURL: url,
                policy: policy,
                onStateChanged: { [weak self] next in
                    Task { @MainActor [weak self] in self?.applyState(next) }
                },
                onEvent: { [weak self] event in
                    Task { @MainActor [weak self] in self?.handleEvent(event) }
                }
            )
        }
        transport?.start()
    }

    func stop() {
        transport?.stop()
    }

    func openBridgeApp() {
        for bundleID in [BridgeConfig.bridgeBundleID, BridgeConfig.bridgeDevBundleID] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
                return
            }
        }
    }

    func setOptionHoldKey(_ keyCode: Int?) {
        guard canInsertDirectly, let transport else { return }
        Task { _ = await transport.call(.setOptionHoldKey(keyCode: keyCode), timeout: .seconds(1)) }
    }

    func setOutputMuted(_ muted: Bool) {
        guard isConnected, let transport else { return }
        Task { _ = await transport.call(.setOutputMuted(muted: muted), timeout: .seconds(1)) }
    }

    func fetchDictationSnapshot() async -> DictationDestinationSnapshot {
        if canInsertDirectly, let transport,
           let reply = await transport.call(.dictationSnapshot, timeout: .milliseconds(400)),
           case .dictationSnapshot(let snapshot) = reply {
            return snapshot
        }
        return DictationDestinationSnapshot(appName: NSWorkspace.shared.frontmostApplication?.localizedName)
    }

    func runSelection(recordResult: @escaping @Sendable (String) async -> Void,
                      transform: SelectionTransform) async throws -> SelectionOutcome {
        if canInsertDirectly, let transport {
            return try await runBridgedSelection(transport: transport, recordResult: recordResult, transform: transform)
        }
        return try await runClipboardFallback(recordResult: recordResult, transform: transform)
    }

    func deliverDictation(_ text: String, vocabulary: DictationVocabulary,
                          languageIdentifiers: [String]) async throws -> Bool {
        guard canInsertDirectly, let transport else { return false }
        try Task.checkCancellation()
        guard let targetReply = await transport.call(.dictationTarget, timeout: .seconds(1)),
              case .dictationTarget(let target?) = targetReply else {
            return false
        }
        try Task.checkCancellation()
        let formatted = DictationInsertion.format(text, context: target.context,
                                                  vocabulary: vocabulary,
                                                  languageIdentifiers: languageIdentifiers)
        guard let deliverReply = await transport.call(.deliverDictation(pid: target.pid, text: formatted),
                                                      timeout: .seconds(5)),
              case .delivered(let delivered) = deliverReply else {
            return false
        }
        return delivered
    }

    private func runBridgedSelection(transport: BridgeConnectionClient,
                                     recordResult: @escaping @Sendable (String) async -> Void,
                                     transform: SelectionTransform) async throws -> SelectionOutcome {
        guard let startReply = await transport.call(.beginSelection, timeout: .seconds(2)),
              case .selectionStarted(let id, let copiedText) = startReply,
              let selection = copiedText,
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noSelection
        }
        do {
            let result = try await transform(selection)
            try Task.checkCancellation()
            await recordResult(result)
            guard let finishReply = await transport.call(.finishSelection(id: id, replacement: result),
                                                         timeout: .seconds(5)),
                  case .delivered(let delivered) = finishReply else {
                return .result(result)
            }
            return delivered ? .pasted : .result(result)
        } catch {
            _ = await transport.call(.finishSelection(id: id, replacement: nil), timeout: .seconds(1))
            throw error
        }
    }

    private func runClipboardFallback(recordResult: @escaping @Sendable (String) async -> Void,
                                      transform: SelectionTransform) async throws -> SelectionOutcome {
        guard let copied = readClipboardText(),
              !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .emptyClipboard
        }
        let result = try await transform(copied)
        try Task.checkCancellation()
        await recordResult(result)
        return .result(result)
    }

    private func applyState(_ next: BridgeConnectionClient.ConnectionState) {
        let previousDirect = canInsertDirectly
        state = next
        if previousDirect != canInsertDirectly {
            bridgeClientLog.notice("Bridge direct insertion availability: \(self.canInsertDirectly)")
            onAvailabilityChanged?()
        }
    }

    private func handleEvent(_ event: BridgePushEvent) {
        if case .optionAction(let action) = event {
            onOptionAction?(action)
        }
    }
}

// Forwards capture-queue mute transitions to Bridge only when state changes.
final class BridgeDictationMute: DictationMuting {
    private var muted = false

    func engage() {
        guard !muted else { return }
        muted = true
        Task { @MainActor in BridgeClient.shared.setOutputMuted(true) }
    }

    func release() {
        guard muted else { return }
        muted = false
        Task { @MainActor in BridgeClient.shared.setOutputMuted(false) }
    }

    func recoverInterrupted() {}
}

struct BridgeIntegrationSection: View {
    let bridge: BridgeClient

    var body: some View {
        Section {
            LabeledContent("Direct insertion") {
                if bridge.isAccessibilityTrusted {
                    Text("Connected")
                        .foregroundStyle(Color.secondaryText)
                } else {
                    HStack(spacing: 8) {
                        Text("Needs Accessibility")
                            .foregroundStyle(Color.secondaryText)
                        Button("Open Bridge…") { bridge.openBridgeApp() }
                    }
                }
            }
        } header: {
            Text("System integration")
        }
    }
}
