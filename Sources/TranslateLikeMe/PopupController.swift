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
}

// A floating, cursor-anchored popup for error messages, rendered in SwiftUI with
// a Liquid Glass background (falls back to a material on older macOS).
struct PopupView: View {
    let model: PopupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.header)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(model.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let action = model.action {
                Button(action.title, action: action.handler)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassy()
    }
}

private extension View {
    @ViewBuilder
    func glassy() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
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
    private let minHeight: CGFloat = 160
    private let maxHeight: CGFloat = 520
    // Vertical chrome around the body text, without / with the action row.
    private let bodyChrome: CGFloat = 44
    private let bodyChromeWithAction: CGFloat = 80

    private init() {}

    func showError(_ message: String) {
        model.header = "Error"
        model.body = message
        model.action = nil
        present()
    }

    // A dedicated presentation for exhausted engine limits: the reset time
    // from the engine, plus a direct route to Settings where the engine can
    // be switched to the other provider or auth mode.
    func showLimitReached(_ message: String) {
        model.header = "Limit reached"
        model.body = message + "\n\nSwitch engines in Settings, or wait for the limit to reset."
        model.action = ("Open Settings", { [weak self] in
            self?.hide()
            NotificationCenter.default.post(name: .openSettings, object: nil)
        })
        present()
    }

    // Shown when the selection could not be replaced in place (a read-only field).
    // The translation is on the clipboard by the time this appears, so the header
    // tells the user they can paste it or select it straight from the popup.
    func showTranslation(_ text: String) {
        model.header = "Couldn't replace the selection. Translation copied to clipboard."
        model.body = text
        model.action = nil
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
        let total = min(max(bodyHeight + chrome, minHeight), maxHeight)
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
