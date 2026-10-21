import Foundation

struct CopiedSelection: Sendable {
    let text: String?
    // nil means Copy made no observed change, so the app owns nothing to restore.
    let changeCount: Int?
}

// Adds the Copy that reads the selection.
protocol SelectionAccess: PasteAccess {
    func copySelection() -> CopiedSelection
}

enum SelectionOutcome: Equatable, Sendable {
    case noSelection
    case pasted
    case result(String)
}

struct SelectionWorkflow<Access: SelectionAccess>: Sendable {
    let access: Access
    var pause: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    func run(transform: @Sendable (String) async throws -> String) async throws -> SelectionOutcome {
        let original = access.snapshot()
        let copied = access.copySelection()
        guard let selection = copied.text,
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let mark = copied.changeCount else {
            if let mark = copied.changeCount { access.restore(original, ifUnchangedSince: mark) }
            return .noSelection
        }
        // Puts back the clipboard the Copy replaced when nothing was pasted or the
        // engine failed. A newer user copy moves the change count and is kept, as
        // is a paste, whose delivery has already restored the clipboard.
        defer { access.restore(original, ifUnchangedSince: mark) }
        let result = try await transform(selection)
        try Task.checkCancellation()
        let read = try await PasteDelivery(access: access, pause: pause)
            .deliver(result, restoring: original, ifUnchangedSince: mark)
        return read ? .pasted : .result(result)
    }
}
