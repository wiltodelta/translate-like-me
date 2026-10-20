import AppKit
import SwiftUI
import Observation

@MainActor
@Observable
final class PopupModel {
    var header: String = ""
    var body: String = ""
    // Optional trailing action (e.g. "Open Settings" on a limit error). Set and
    // cleared as one value so the title and handler cannot drift apart.
    var action: (title: String, handler: () -> Void)?
    // The body is taller than the capped popup, so part of it is below the fold.
    var overflows = false
}

// A floating, cursor-anchored popup for errors and for a translation that could
// not replace a selection. An opaque semantic backing keeps text readable
// across the full Liquid Glass tint range and arbitrary desktop content.
struct PopupView: View {
    let model: PopupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.header)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondaryText)
            // A capped popup scrolls; with overlay scrollers hidden until scrolled, a
            // long translation read as complete at its seventh paragraph. The last
            // lines fade out when more is below (UX-T05).
            ScrollView {
                Text(model.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .mask {
                LinearGradient(
                    stops: [.init(color: .black, location: 0),
                            .init(color: .black, location: model.overflows ? 0.82 : 1),
                            .init(color: .black.opacity(model.overflows ? 0.15 : 1), location: 1)],
                    startPoint: .top, endPoint: .bottom)
            }
            if let action = model.action {
                Button(action.title, action: action.handler)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    // The panel never becomes key (it must not take focus from the
                    // app being translated in), and an inactive window draws a
                    // prominent button gray: keep the one action looking like one.
                    .environment(\.controlActiveState, .key)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// A panel that can show without stealing focus from the app you're translating in.
private final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

@MainActor
final class PopupController {
    static let shared = PopupController()

    private let model = PopupModel()
    private var panel: PopupPanel?
    private var clickMonitor: Any?

    private let width: CGFloat = 460
    private let maxHeight: CGFloat = 520
    // Vertical chrome around the body text, without / with the action row.
    private let bodyChrome: CGFloat = 44
    private let bodyChromeWithAction: CGFloat = 80

    private init() {}

    func showError(_ message: String) {
        model.header = String(localized: "Error", comment: "Popup header")
        model.body = message
        model.action = nil
        present()
    }

    // A dedicated presentation for exhausted engine limits: the reset time
    // from the engine, plus a direct route to Settings where the engine can
    // be switched to the other provider or auth mode.
    func showLimitReached(_ message: String) {
        model.header = String(localized: "Limit reached", comment: "Popup header")
        model.body = message + "\n\n" + String(localized: "Switch engines in Settings, or wait for the limit to reset.")
        model.action = (String(localized: "Open Settings"), { [weak self] in
            self?.hide()
            NotificationCenter.default.post(name: .openSettings, object: nil)
        })
        present()
    }

    // What a result is, for the popup's header: whole sentences, since many
    // languages agree the verb ("copied") with the noun.
    enum ResultKind {
        case translation
        case message
        case dictation

        func header(copied: Bool) -> String {
            switch (self, copied) {
            case (.translation, true):
                String(localized: "Couldn't replace the selection. Translation copied to clipboard.")
            case (.translation, false):
                String(localized: "Couldn't safely replace the selection. Translation ready to copy.")
            case (.message, true):
                String(localized: "Couldn't replace the selection. Message copied to clipboard.")
            case (.message, false):
                String(localized: "Couldn't safely replace the selection. Message ready to copy.")
            case (.dictation, true):
                String(localized: "Couldn't replace the selection. Dictation copied to clipboard.")
            case (.dictation, false):
                String(localized: "Couldn't safely replace the selection. Dictation ready to copy.")
            }
        }
    }

    // Skipped insertion never overwrites a newer clipboard. The header states
    // whether the result is already copied; Copy is an explicit user action.
    func showResult(_ text: String, kind: ResultKind, copied: Bool = true) {
        model.header = kind.header(copied: copied)
        model.body = text
        model.action = (String(localized: "Copy", comment: "Button that copies the result"), { [weak self] in
            SelectionService.copyToClipboard(text)
            self?.model.action = (String(localized: "Copied", comment: "The Copy button after a click"), {})
        })
        present()
    }

    func hide() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        panel?.orderOut(nil)
    }

    private func present() {
        let panel = ensurePanel()

        let bodyHeight = measuredBodyHeight(model.body)
        let chrome = model.action == nil ? bodyChrome : bodyChromeWithAction
        // Only as tall as the content (HIG Popovers: "Avoid making a popover too
        // big"), capped so a long translation scrolls.
        let total = min(bodyHeight + chrome, maxHeight)
        model.overflows = bodyHeight + chrome > maxHeight
        panel.setContentSize(NSSize(width: width, height: total))

        positionNearCursor(panel)
        panel.orderFrontRegardless()
        installClickMonitor()
    }

    private func ensurePanel() -> PopupPanel {
        if let panel { return panel }

        let panel = PopupPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true

        let hosting = NSHostingView(rootView: PopupView(model: model))
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = panel.contentView?.bounds ?? .zero
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    private func measuredBodyHeight(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width - 24, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(bounds.height)
    }

    private func positionNearCursor(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 12)

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.x + size.width > visible.maxX { origin.x = visible.maxX - size.width - 8 }
            if origin.x < visible.minX { origin.x = visible.minX + 8 }
            if origin.y < visible.minY { origin.y = mouse.y + 12 }
            if origin.y + size.height > visible.maxY { origin.y = visible.maxY - size.height - 8 }
        }
        panel.setFrameOrigin(origin)
    }

    private func installClickMonitor() {
        if clickMonitor != nil { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }
}
