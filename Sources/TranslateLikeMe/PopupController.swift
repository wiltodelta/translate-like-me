import AppKit
import SwiftUI
import Observation

@MainActor
@Observable
final class PopupModel {
    var header: String = ""
    var body: String = ""
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

    private init() {}

    func showError(_ message: String) {
        model.header = "Error"
        model.body = message
        present()
    }

    // Shown when the selection could not be replaced in place (a read-only field).
    // The translation is on the clipboard by the time this appears, so the header
    // tells the user they can paste it or select it straight from the popup.
    func showTranslation(_ text: String) {
        model.header = "Couldn't replace the selection. Translation copied to clipboard."
        model.body = text
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
        let total = min(max(bodyHeight + 44, minHeight), maxHeight)
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
