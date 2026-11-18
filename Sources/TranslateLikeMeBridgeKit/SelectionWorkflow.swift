import Foundation

public struct CopiedSelection: Sendable {
    public let text: String?
    // nil means Copy made no observed change, so the app owns nothing to restore.
    public let changeCount: Int?

    public init(text: String?, changeCount: Int?) {
        self.text = text
        self.changeCount = changeCount
    }
}

// Adds the Copy that reads the selection.
public protocol SelectionAccess: PasteAccess {
    func copySelection() -> CopiedSelection
}

public enum SelectionOutcome: Equatable, Sendable {
    case noSelection
    case emptyClipboard
    case pasted
    case result(String)
}

public struct PreparedSelection<Access: SelectionAccess>: Sendable {
    public let access: Access
    public let original: Access.Snapshot
    public let mark: Int
    public let text: String

    public static func capture(using access: Access) -> Self? {
        let original = access.snapshot()
        let copied = access.copySelection()
        guard let selection = copied.text,
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let mark = copied.changeCount else {
            if let mark = copied.changeCount { access.restore(original, ifUnchangedSince: mark) }
            return nil
        }
        return Self(access: access, original: original, mark: mark, text: selection)
    }

    public func restore() {
        access.restore(original, ifUnchangedSince: mark)
    }

    public func deliver(_ replacement: String,
                        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async throws -> Bool {
        defer { restore() }
        return try await PasteDelivery(access: access, pause: pause)
            .deliver(replacement, restoring: original, ifUnchangedSince: mark)
    }
}

public struct SelectionWorkflow<Access: SelectionAccess>: Sendable {
    public let access: Access
    public var didProduceResult: @Sendable (String) async -> Void
    public var pause: @Sendable (Duration) async -> Void

    public init(access: Access,
                didProduceResult: @escaping @Sendable (String) async -> Void = { _ in },
                pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.access = access
        self.didProduceResult = didProduceResult
        self.pause = pause
    }

    public func run(transform: @Sendable (String) async throws -> String) async throws -> SelectionOutcome {
        guard let prepared = PreparedSelection.capture(using: access) else {
            return .noSelection
        }
        // Puts back the clipboard the Copy replaced when nothing was pasted or the
        // engine failed. A newer user copy moves the change count and is kept, as
        // is a paste, whose delivery has already restored the clipboard.
        defer { prepared.restore() }
        let result = try await transform(prepared.text)
        try Task.checkCancellation()
        await didProduceResult(result)
        let read = try await prepared.deliver(result, pause: pause)
        return read ? .pasted : .result(result)
    }
}
