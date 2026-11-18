import AppKit
import CoreFoundation
import Foundation
import os

private let servicesLog = Logger.app("services")

// Exposes Translate and Rewrite in the macOS Services menu (NSServices) so
// sandboxed Mac App Store installs can replace selected text in place even
// without Translate Like Me Bridge.
@MainActor
final class SystemServicesProvider: NSObject {
    static let shared = SystemServicesProvider()

    @objc func translateSelectionService(_ pasteboard: NSPasteboard,
                                         userData: String,
                                         error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let pair = Settings.languagePairs.first(where: \.isComplete) else {
            let message = String(localized: "Choose two different languages for this pair in Settings first.")
            error.pointee = message as NSString
            PopupController.shared.showError(message)
            return
        }
        performService(on: pasteboard, kind: .translation, error: error) { text in
            try await Translator.translate(text, pair: pair)
        }
    }

    @objc func rewriteSelectionService(_ pasteboard: NSPasteboard,
                                       userData: String,
                                       error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let preset = Settings.rewritePresets.first else {
            let message = String(localized: "Add a Rewrite preset in Settings first.")
            error.pointee = message as NSString
            PopupController.shared.showError(message)
            return
        }
        performService(on: pasteboard, kind: .message, error: error) { text in
            try await Translator.rewrite(text, preset: preset)
        }
    }

    func performService(on pasteboard: NSPasteboard,
                        kind: PopupController.ResultKind,
                        error: AutoreleasingUnsafeMutablePointer<NSString?>?,
                        transform: @escaping SelectionTransform) {
        guard let input = pasteboard.string(forType: .string),
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard !TranslationActivity.shared.isBusy else { return }
        TranslationActivity.shared.isBusy = true
        var outcome: Result<String, Error>?
        let runLoop = CFRunLoopGetCurrent()
        let task = Task {
            do {
                let output = try await transform(input)
                LastResults.shared.record(output, kind: kind)
                outcome = .success(output)
            } catch {
                outcome = .failure(error)
            }
            CFRunLoopStop(runLoop)
        }
        ActivityIndicator.translation.show(kind: kind) {
            task.cancel()
            CFRunLoopStop(runLoop)
        }
        let deadline = Date().addingTimeInterval(120)
        while outcome == nil && !task.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            _ = CFRunLoopRunInMode(.defaultMode, min(remaining, 0.5), true)
        }
        ActivityIndicator.translation.hide()
        TranslationActivity.shared.isBusy = false
        switch outcome {
        case .success(let output):
            pasteboard.clearContents()
            pasteboard.setString(output, forType: .string)
            servicesLog.notice("NSServices completed \(String(describing: kind), privacy: .public)")
        case .failure(let failure):
            if !(failure is CancellationError) {
                let message = failure.localizedDescription
                error?.pointee = message as NSString
                PopupController.shared.showError(message)
            }
        case nil:
            task.cancel()
        }
    }
}
