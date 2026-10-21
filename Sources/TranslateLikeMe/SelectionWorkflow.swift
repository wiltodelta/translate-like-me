import Foundation
import os

private let workflowLog = Logger.app("selection")

struct CopiedSelection: Sendable {
    let text: String?
    // nil means Copy made no observed change, so the app owns nothing to restore.
    let changeCount: Int?
}

struct PasteAttempt: Sendable {
    let changeCount: Int
    let posted: Bool
}

// The native adapter owns AX, key posting and the pasteboard. This seam lets
// tests run the complete await/validate/paste/restore flow without real input.
protocol SelectionAccess: Sendable {
    associatedtype Target: Sendable
    associatedtype Snapshot: Sendable
    var changeCount: Int { get }
    func snapshot() -> Snapshot
    func restore(_ snapshot: Snapshot, ifUnchangedSince mark: Int)
    func captureTarget() -> Target?
    func copySelection() -> CopiedSelection
    func isCurrent(_ target: Target) -> Bool
    func paste(_ text: String, into target: Target, ifUnchangedSince mark: Int) -> PasteAttempt?
    func replacementLanded(_ text: String, in target: Target) -> Bool
    func copyResult(_ text: String, ifUnchangedSince mark: Int) -> Bool
}

enum SelectionOutcome: Equatable, Sendable {
    case noSelection
    case pasted
    case result(String, copied: Bool)
}

struct SelectionWorkflow<Access: SelectionAccess>: Sendable {
    let access: Access
    var pause: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    func run(transform: @Sendable (String) async throws -> String) async throws -> SelectionOutcome {
        let original = access.snapshot()
        let target = access.captureTarget()
        let copied = access.copySelection()
        guard let selection = copied.text,
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let mark = copied.changeCount else {
            if let mark = copied.changeCount { access.restore(original, ifUnchangedSince: mark) }
            return .noSelection
        }
        do {
            let result = try await transform(selection)
            try Task.checkCancellation()
            // A changed target or a newer user copy wins over automatic insertion.
            let clipboardUnchanged = access.changeCount == mark
            guard let target, clipboardUnchanged, access.isCurrent(target),
                  let pasted = access.paste(result, into: target, ifUnchangedSince: mark) else {
                workflowLog.notice("""
                    Insertion skipped: original target available \(target != nil), \
                    clipboard unchanged \(clipboardUnchanged)
                    """)
                access.restore(original, ifUnchangedSince: mark)
                return .result(result, copied: false)
            }
            guard pasted.posted else {
                access.restore(original, ifUnchangedSince: pasted.changeCount)
                return .result(result, copied: false)
            }
            await pause(.milliseconds(120))
            if access.replacementLanded(result, in: target) {
                await pause(.milliseconds(600))
                access.restore(original, ifUnchangedSince: pasted.changeCount)
                return .pasted
            }
            // No recopy: Cmd+C here could destroy something the user copied
            // since the paste. Only replace clipboard contents we still own.
            let kept = access.copyResult(result, ifUnchangedSince: pasted.changeCount)
            return .result(result, copied: kept)
        } catch {
            access.restore(original, ifUnchangedSince: mark)
            throw error
        }
    }
}
