import AppKit
import SwiftUI

// Borderless panel that can take key focus so the hosted SwiftUI controls (the
// language pickers, the Return/Escape default actions) work like they did inside
// the old MenuBarExtra window.
final class MenuBarPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// Near-opaque window-background tint laid over the vibrancy. The public `.menu`
// material lets more of the backdrop through than a real NSMenu, so this keeps
// the panel bright over dark windows; it re-resolves its colour on light/dark
// switches so the tint never goes stale.
private final class TintView: NSView {
    private let alpha: CGFloat
    init(alpha: CGFloat) {
        self.alpha = alpha
        super.init(frame: .zero)
        wantsLayer = true
        applyColor()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(alpha).cgColor
        }
    }
}

// Hosts the SwiftUI content over an AppKit vibrant, tinted, rounded backing.
//
// The vibrancy and tint are AppKit siblings behind the SwiftUI hosting view,
// deliberately kept out of the measured SwiftUI tree - an NSVisualEffectView
// embedded inside a self-sizing NSHostingController recurses through Auto Layout
// and overflows the stack. The window height is driven from the inner content's
// exact sizeThatFits, so the panel resizes to fit as the content changes.
private final class PanelHostController: NSViewController {
    private let host: NSHostingController<AnyView>
    private let fixedWidth: CGFloat

    init<Content: View>(rootView: Content, width: CGFloat) {
        // Pin the width so only the height is dynamic; without a fixed width the
        // greedy `maxWidth: .infinity` content collapses to its minimum and the
        // panel comes out too narrow.
        fixedWidth = width
        host = NSHostingController(rootView: AnyView(rootView.frame(width: width)))
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 12
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        view = clip
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active

        let tint = TintView(alpha: 0.82)

        addChild(host)
        for sub in [effect, tint, host.view] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
            NSLayoutConstraint.activate([
                sub.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                sub.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                sub.topAnchor.constraint(equalTo: view.topAnchor),
                sub.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }

        resizeToFitContent()
    }

    // Drive the window height from the SwiftUI content's exact fitting size.
    // NSHostingController.preferredContentSize undercounts tall content here, so
    // measure explicitly instead.
    override func viewDidLayout() {
        super.viewDidLayout()
        resizeToFitContent()
    }

    private func resizeToFitContent() {
        let target = host.sizeThatFits(
            in: NSSize(width: fixedWidth, height: .greatestFiniteMagnitude)
        )
        // Guard against a feedback loop: only push a genuinely new size.
        if abs(target.height - preferredContentSize.height) > 0.5
            || abs(target.width - preferredContentSize.width) > 0.5 {
            preferredContentSize = target
        }
    }
}

// Arrowless dropdown anchored under a status-bar item.
//
// Reproduces NSPopover.behavior = .transient (open on click, close on any click
// outside) without the dated triangular arrow. The content is a SwiftUI view
// hosted in a rounded, material-backed borderless window.
final class MenuBarPanelController {
    private let panel: MenuBarPanelWindow
    private weak var anchorButton: NSStatusBarButton?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var resizeObserver: NSObjectProtocol?
    // Screen-space top-left the panel grows down from, so it stays pinned under
    // the menu bar when the content height changes.
    private var anchorTopLeft: NSPoint?

    // Gap between the menu bar and the top of the panel, in points.
    private let verticalGap: CGFloat = 6
    // Minimum inset kept from the screen edges when clamping horizontally.
    private let screenEdgeInset: CGFloat = 8

    var isShown: Bool { panel.isVisible }

    init<Content: View>(rootView: Content, size: NSSize) {
        panel = MenuBarPanelWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure(rootView: rootView, size: size)
    }

    private func configure<Content: View>(rootView: Content, size: NSSize) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.setContentSize(size)
        panel.contentViewController = PanelHostController(rootView: rootView, width: size.width)
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        anchorButton = button

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        let size = panel.frame.size

        var origin = NSPoint(
            x: screenRect.midX - size.width / 2,
            y: screenRect.minY - size.height - verticalGap
        )

        // Keep the panel on screen when the icon sits near a screen edge.
        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + screenEdgeInset),
                           visible.maxX - size.width - screenEdgeInset)
        }

        panel.setFrameOrigin(origin)
        anchorTopLeft = NSPoint(x: origin.x, y: origin.y + size.height)
        startObservingResize()

        // A non-activating panel takes key focus (so the SwiftUI pickers and
        // Return/Escape default actions work) without bringing the whole accessory
        // app to the foreground.
        panel.makeKeyAndOrderFront(nil)
        startMonitoring()
    }

    func close() {
        stopMonitoring()
        stopObservingResize()
        anchorButton = nil
        panel.orderOut(nil)
    }

    // Keep the panel's top edge fixed under the menu bar as its height changes.
    private func startObservingResize() {
        stopObservingResize()
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, let topLeft = self.anchorTopLeft else { return }
            self.panel.setFrameOrigin(NSPoint(x: topLeft.x, y: topLeft.y - self.panel.frame.height))
        }
    }

    private func stopObservingResize() {
        if let observer = resizeObserver {
            NotificationCenter.default.removeObserver(observer)
            resizeObserver = nil
        }
    }

    // MARK: - Transient dismissal

    private func startMonitoring() {
        stopMonitoring()

        // Clicks in other apps (or on the desktop) close the panel.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.close()
        }

        // Clicks in our own app close the panel unless they land inside it or on
        // the status item itself (the button action handles its own toggle).
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.window != self.panel, event.window != self.anchorButton?.window {
                self.close()
            }
            return event
        }
    }

    private func stopMonitoring() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}
