import AppKit
import os

private let coordinatorLog = Logger.app("bridge")

@MainActor
public protocol BridgeSelectionSessionHandling {
    var copiedText: String { get }
    func finish(replacement: String?) async -> Bool
}

@MainActor
final class LiveBridgeSelectionSession: BridgeSelectionSessionHandling {
    let copiedText: String
    private let prepared: PreparedSelection<LiveSelectionAccess>
    private let stopMonitoring: () -> Void
    private var finished = false

    init?() async {
        let copyKey = KeyboardLayout.copyKey
        let pasteKey = KeyboardLayout.pasteKey
        let activity = SelectionActivity()
        let stop = activity.monitor()
        let pid = await Task.detached(priority: .userInitiated) { SelectionTarget.focusedPID ?? 0 }.value
        let access = LiveSelectionAccess(pid: pid, activity: activity, copyKey: copyKey, pasteKey: pasteKey)
        let captured = await Task.detached(priority: .userInitiated) {
            PreparedSelection.capture(using: access)
        }.value
        guard let captured else {
            stop()
            return nil
        }
        self.copiedText = captured.text
        self.prepared = captured
        self.stopMonitoring = stop
    }

    func finish(replacement: String?) async -> Bool {
        guard !finished else { return false }
        finished = true
        defer { stopMonitoring() }
        guard let replacement else {
            prepared.restore()
            return false
        }
        return (try? await prepared.deliver(replacement)) ?? false
    }
}

@MainActor
public final class BridgeHostCoordinator {
    public struct Dependencies {
        public var version: () -> String
        public var isTrusted: () -> Bool
        public var startSelection: @MainActor () async -> (any BridgeSelectionSessionHandling)?
        public var dictationTarget: @Sendable () -> DictationInsertionTarget?
        public var deliverDictation: @MainActor (pid_t, String) async -> Bool
        public var dictationSnapshot: @Sendable () -> DictationDestinationSnapshot
        public var mute: DictationOutputMute

        public init(version: @escaping () -> String,
                    isTrusted: @escaping () -> Bool,
                    startSelection: @escaping @MainActor () async -> (any BridgeSelectionSessionHandling)?,
                    dictationTarget: @escaping @Sendable () -> DictationInsertionTarget?,
                    deliverDictation: @escaping @MainActor (pid_t, String) async -> Bool,
                    dictationSnapshot: @escaping @Sendable () -> DictationDestinationSnapshot,
                    mute: DictationOutputMute) {
            self.version = version
            self.isTrusted = isTrusted
            self.startSelection = startSelection
            self.dictationTarget = dictationTarget
            self.deliverDictation = deliverDictation
            self.dictationSnapshot = dictationSnapshot
            self.mute = mute
        }

        public static func live() -> Self {
            Self(
                version: { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" },
                isTrusted: { AXIsProcessTrusted() },
                startSelection: { await LiveBridgeSelectionSession() },
                dictationTarget: { SelectionTarget.dictationTarget() },
                deliverDictation: { pid, formatted in
                    let access = LiveDictationAccess(pasteKey: KeyboardLayout.pasteKey)
                    return (try? await PasteDelivery(access: access).insertPreformatted(formatted, to: pid)) ?? false
                },
                dictationSnapshot: { SelectionTarget.dictationSnapshot() },
                mute: DictationOutputMute()
            )
        }
    }

    private let dependencies: Dependencies
    private var sessions: [UUID: (clientID: UUID, session: any BridgeSelectionSessionHandling)] = [:]
    private let optionMonitor = OptionHoldMonitor()
    private var optionClientID: UUID?
    private var mutedClientID: UUID?
    public var sendEvent: (BridgePushEvent) -> Void = { _ in }

    public init(dependencies: Dependencies = .live()) {
        self.dependencies = dependencies
        dependencies.mute.recoverInterrupted()
    }

    public func handle(clientID: UUID, request: BridgeRequest) async -> BridgeResponse {
        switch request {
        case .hello:
            return .status(accessibilityTrusted: dependencies.isTrusted(), version: dependencies.version())
        case .beginSelection:
            return await beginSelection(clientID: clientID)
        case .finishSelection(let id, let replacement):
            guard let entry = sessions.removeValue(forKey: id) else { return .delivered(false) }
            return .delivered(await entry.session.finish(replacement: replacement))
        case .dictationTarget:
            return await lookupDictationTarget()
        case .deliverDictation(let pid, let text):
            guard dependencies.isTrusted() else { return .delivered(false) }
            return .delivered(await dependencies.deliverDictation(pid, text))
        case .dictationSnapshot:
            return await lookupDictationSnapshot()
        case .setOptionHoldKey(let keyCode):
            updateOptionHold(clientID: clientID, keyCode: keyCode)
            return .ack
        case .setOutputMuted(let muted):
            setMuted(clientID: clientID, muted: muted)
            return .ack
        }
    }

    private func beginSelection(clientID: UUID) async -> BridgeResponse {
        let id = UUID()
        guard dependencies.isTrusted(), let session = await dependencies.startSelection() else {
            return .selectionStarted(id: id, text: nil)
        }
        sessions[id] = (clientID, session)
        return .selectionStarted(id: id, text: session.copiedText)
    }

    private func lookupDictationTarget() async -> BridgeResponse {
        guard dependencies.isTrusted() else { return .dictationTarget(nil) }
        let targetFn = dependencies.dictationTarget
        return .dictationTarget(await Task.detached(priority: .userInitiated) { targetFn() }.value)
    }

    private func lookupDictationSnapshot() async -> BridgeResponse {
        guard dependencies.isTrusted() else { return .dictationSnapshot(DictationDestinationSnapshot()) }
        let snapshotFn = dependencies.dictationSnapshot
        return .dictationSnapshot(await Task.detached(priority: .userInitiated) { snapshotFn() }.value)
    }

    public func clientDisconnected(_ clientID: UUID) {
        let abandoned = sessions.filter { $0.value.clientID == clientID }.map(\.key)
        for id in abandoned {
            if let entry = sessions.removeValue(forKey: id) {
                Task { _ = await entry.session.finish(replacement: nil) }
            }
        }
        if optionClientID == clientID {
            optionClientID = nil
            optionMonitor.stop()
        }
        if mutedClientID == clientID {
            setMuted(clientID: clientID, muted: false)
        }
    }

    public func broadcastTrustIfChanged(_ trusted: Bool) {
        sendEvent(.statusChanged(accessibilityTrusted: trusted))
    }

    private func setMuted(clientID: UUID, muted: Bool) {
        if muted {
            mutedClientID = clientID
            dependencies.mute.engage()
        } else {
            if mutedClientID == clientID { mutedClientID = nil }
            dependencies.mute.release()
        }
    }

    private func updateOptionHold(clientID: UUID, keyCode: Int?) {
        optionMonitor.stop()
        optionClientID = nil
        guard let keyCode, dependencies.isTrusted() else { return }
        optionClientID = clientID
        optionMonitor.start(keyCode: keyCode) { [weak self] action in
            self?.sendEvent(.optionAction(action))
        }
        coordinatorLog.notice("Bridge Option hold monitor active for key \(keyCode)")
    }
}
