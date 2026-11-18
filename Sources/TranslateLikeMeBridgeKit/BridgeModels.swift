import Foundation

public struct DictationInsertionContext: Codable, Sendable, Equatable {
    public static let sliceLimit = 24

    public var beforeSlice: String?
    public var afterSlice: String?
    public var hasCompleteLinePrefix: Bool

    public var beforeCaret: Character? { beforeSlice?.last }
    public var afterCaret: Character? { afterSlice?.first }

    public init(beforeSlice: String? = nil, afterSlice: String? = nil, hasCompleteLinePrefix: Bool = true) {
        self.beforeSlice = beforeSlice
        self.afterSlice = afterSlice
        self.hasCompleteLinePrefix = hasCompleteLinePrefix
    }

    public init(beforeCaret: Character?) {
        self.beforeSlice = beforeCaret.map(String.init)
        self.afterSlice = nil
        self.hasCompleteLinePrefix = false
    }
}

public struct DictationInsertionTarget: Codable, Sendable, Equatable {
    public let pid: pid_t
    public let context: DictationInsertionContext

    public var beforeCaret: Character? { context.beforeCaret }

    public init(pid: pid_t, context: DictationInsertionContext = DictationInsertionContext()) {
        self.pid = pid
        self.context = context
    }
}

public struct DictationDestinationSnapshot: Codable, Sendable, Equatable {
    public var appName: String?
    public var windowTitle: String?
    public var surroundingText: String?

    public init(appName: String? = nil, windowTitle: String? = nil, surroundingText: String? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.surroundingText = surroundingText
    }
}

public enum TextCaretSlices {
    public static let beforeCaretLimit = 180
    public static let afterCaretLimit = 60

    public static func sanitized(_ text: String) -> String {
        // Remove angle brackets unconditionally so nested or truncated text can
        // never form Qwen chat-template or ASR control tokens (`<|...|>` / `<asr_text>`).
        String(text.filter { $0 != "<" && $0 != ">" })
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func insertionContext(
        in value: String, selection: NSRange,
        limit: Int = DictationInsertionContext.sliceLimit
    ) -> DictationInsertionContext {
        guard selection.length == 0, selection.location >= 0,
              let caret = scalarBoundary(at: selection.location, in: value) else {
            return DictationInsertionContext()
        }
        let beforePrefix = value[..<caret]
        let beforeSuffix = beforePrefix.suffix(limit)
        let beforeSlice = String(beforeSuffix)
        let afterSlice = String(value[caret...].prefix(limit))
        let completeLine = beforeSuffix.startIndex == value.startIndex || beforeSuffix.contains(where: \.isNewline)
        return DictationInsertionContext(beforeSlice: beforeSlice, afterSlice: afterSlice,
                                         hasCompleteLinePrefix: completeLine)
    }

    public static func surroundingText(in value: String, selection: NSRange) -> String? {
        guard selection.location >= 0, selection.length >= 0 else { return nil }
        let (endOffset, overflow) = selection.location.addingReportingOverflow(selection.length)
        guard !overflow,
              let start = scalarBoundary(at: selection.location, in: value),
              let end = scalarBoundary(at: endOffset, in: value) else { return nil }
        let prefix = String(value[..<start].suffix(beforeCaretLimit))
        let suffix = String(value[end...].prefix(afterCaretLimit))
        let joined = [prefix, suffix].map { cleaned($0, limit: 240, keepTail: true) }.filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    public static func cleaned(_ text: String?, limit: Int, keepTail: Bool) -> String {
        guard let text else { return "" }
        let compact = sanitized(text)
        guard compact.count > limit else { return compact }
        return keepTail ? String(compact.suffix(limit)) : String(compact.prefix(limit))
    }

    private static func scalarBoundary(at utf16Offset: Int, in value: String) -> String.Index? {
        guard utf16Offset >= 0 else { return nil }
        let utf16 = value.utf16
        guard let position = utf16.index(utf16.startIndex, offsetBy: utf16Offset, limitedBy: utf16.endIndex) else {
            return nil
        }
        return String.Index(position, within: value)
    }
}

public enum BridgeConfig {
    public static let teamID = "K2GT9Q4S6U"
    public static let appGroup = "K2GT9Q4S6U.tlm"
    public static let devAppGroup = "K2GT9Q4S6U.tlm.dev"
    public static let directDevBundleID = "com.wiltodelta.translatelikeme.dev"
    public static let masBundleID = "com.wiltodelta.translatelikeme.mas"
    public static let masDevBundleID = "com.wiltodelta.translatelikeme.mas.dev"
    public static let bridgeBundleID = "com.wiltodelta.translatelikeme.bridge"
    public static let bridgeDevBundleID = "com.wiltodelta.translatelikeme.bridge.dev"

    public static func defaultSocketURL(forBundleID bundleID: String? = Bundle.main.bundleIdentifier) -> URL {
        if let override = ProcessInfo.processInfo.environment["TLM_BRIDGE_SOCKET"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let isDev = bundleID?.hasSuffix(".dev") == true
        let group = isDev ? devAppGroup : appGroup
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/\(group)", isDirectory: true)
        return base.appendingPathComponent("s", isDirectory: false)
    }
}

public enum BridgeRequest: Codable, Sendable, Equatable {
    case hello
    case beginSelection
    case finishSelection(id: UUID, replacement: String?)
    case dictationTarget
    case deliverDictation(pid: Int32, text: String)
    case dictationSnapshot
    case setOptionHoldKey(keyCode: Int?)
    case setOutputMuted(muted: Bool)
}

public enum BridgeResponse: Codable, Sendable, Equatable {
    case status(accessibilityTrusted: Bool, version: String)
    case selectionStarted(id: UUID, text: String?)
    case delivered(Bool)
    case dictationTarget(DictationInsertionTarget?)
    case dictationSnapshot(DictationDestinationSnapshot)
    case ack
}

public enum BridgePushEvent: Codable, Sendable, Equatable {
    case statusChanged(accessibilityTrusted: Bool)
    case optionAction(OptionKeyGesture.Action)
}

public enum BridgeWireFrame: Codable, Sendable, Equatable {
    case request(id: UInt64, BridgeRequest)
    case response(id: UInt64, BridgeResponse)
    case event(BridgePushEvent)
}
