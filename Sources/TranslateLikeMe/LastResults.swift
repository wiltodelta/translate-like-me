import Foundation

// One completed result per action, in memory for this app session only.
// Record before delivery so a failed paste cannot lose generated text.
@MainActor
final class LastResults {
    static let shared = LastResults()
    private var values: [PopupController.ResultKind: String] = [:]

    subscript(kind: PopupController.ResultKind) -> String? { values[kind] }

    func record(_ text: String, kind: PopupController.ResultKind) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        values[kind] = text
    }
}
