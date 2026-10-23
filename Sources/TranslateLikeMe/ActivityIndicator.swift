import AppKit
import SwiftUI

// Shared by dictation, translation and Rewrite, with the same geometry and focus behavior.
struct ActivityIndicatorContent: View {
    let title: LocalizedStringKey
    var symbol: String?
    var level: Double?
    let cancelTitle: LocalizedStringKey
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.title3)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 20)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.medium))
                if let level {
                    ProgressView(value: level)
                        .accessibilityLabel("Microphone level")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: cancel) {
                Image(systemName: "xmark").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(cancelTitle)
            .accessibilityIdentifier("activity-cancel")
        }
        .padding(16)
        .frame(width: 280, height: 80)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }
}

private final class ActivityPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ActivityIndicator {
    static let translation = ActivityIndicator(title: String(localized: "Translation"))
    private var title: String
    private var panel: ActivityPanel?

    init(title: String) { self.title = title }

    func show(kind: PopupController.ResultKind, cancel: @escaping () -> Void) {
        title = kind.copyTitle
        show(ActivityIndicatorContent(title: kind == .message ? "Rewriting…" : "Translating…",
                                      cancelTitle: kind == .message ? "Cancel Rewrite" : "Cancel Translation",
                                      cancel: cancel))
    }

    func hide() { panel?.orderOut(nil) }

    func show(_ content: some View) {
        if panel == nil {
            let window = ActivityPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 80),
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            window.title = title
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.hidesOnDeactivate = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = window
        }
        guard let panel else { return }
        panel.title = title
        panel.contentView = NSHostingView(rootView: content)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 140, y: frame.minY + 24))
        }
        panel.orderFrontRegardless()
    }
}
