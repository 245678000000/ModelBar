import AppKit
import SwiftUI
import ModelBarCore

/// 系统菜单栏面板的样子：无箭头、圆角、玻璃材质。
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusBarController: NSObject {
    private let model: AppModel
    private let openSettings: (SettingsPage?) -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: FloatingPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var monitors: [Any] = []
    private var contentSize = CGSize(width: StatusPanelMetrics.width, height: 420)
    private var clickLocation: NSPoint?
    private var outsideDismissal: (location: NSPoint, time: TimeInterval)?
    var hidesOnOutsideClick = true

    init(model: AppModel, openSettings: @escaping (SettingsPage?) -> Void) {
        self.model = model
        self.openSettings = openSettings
        super.init()

        if let button = statusItem.button {
            button.image = StatusIcon.make()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "ModelBar"
        }
        model.onChange = { [weak self] in self?.refreshStatusItem() }
        refreshStatusItem()
    }

    func showPanel() {
        guard panel?.isVisible != true else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        model.refreshStatuses()
        position(panel, size: contentSize)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    func hidePanel() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    // MARK: 状态栏图标

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let model = self.model.activeEndpoint?.selectedModel
        if self.model.state.showModelInMenuBar, let model {
            let short = model.split(separator: "/").last.map(String.init) ?? model
            button.title = " " + (short.count > 22 ? String(short.prefix(21)) + "…" : short)
            button.font = .systemFont(ofSize: 12, weight: .medium)
        } else {
            button.title = ""
        }
    }

    @objc private func statusItemClicked() {
        let dismissal = outsideDismissal
        outsideDismissal = nil
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else if panel?.isVisible == true {
            hidePanel()
        } else if let dismissal, isSamePress(as: dismissal) {
            return
        } else {
            clickLocation = NSEvent.mouseLocation
            showPanel()
        }
    }

    /// 图标窗口由系统托管时，按下图标也算点在面板外，面板在按下时就关了，松开才轮到这里。
    /// 这次松开如果属于同一次点击，就不能再把面板打开。
    private func isSamePress(as dismissal: (location: NSPoint, time: TimeInterval)) -> Bool {
        guard let event = NSApp.currentEvent, event.timestamp - dismissal.time < 1 else { return false }
        let location = NSEvent.mouseLocation
        return abs(location.x - dismissal.location.x) <= 4 && abs(location.y - dismissal.location.y) <= 4
    }

    private func dismissForOutsideClick(at time: TimeInterval) {
        hidePanel()
        outsideDismissal = (NSEvent.mouseLocation, time)
    }

    private func showContextMenu() {
        hidePanel()
        let menu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 ModelBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettingsFromMenu() {
        openSettings(nil)
    }

    // MARK: 面板

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let root = PanelView(
            model: model,
            openSettings: { [weak self] page in
                self?.hidePanel()
                self?.openSettings(page)
            },
            quit: { NSApp.terminate(nil) },
            onSize: { [weak self] size in self?.resizePanel(to: size) }
        )
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        // 玻璃材质会画到圆角外面，不裁掉的话，窗口的方形边界和系统阴影都会露出来。
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = StatusPanelMetrics.cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        hostingView = hosting
        panel.contentView = hosting
        return panel
    }

    private func resizePanel(to size: CGSize) {
        guard size.height > 0, let panel, size != contentSize else { return }
        contentSize = size
        position(panel, size: size)
    }

    private func position(_ panel: NSPanel, size: CGSize) {
        let frame = statusItemFrame()
        let reference = frame.map { NSPoint(x: $0.midX, y: $0.midY) } ?? clickLocation
        let screen = reference.flatMap { point in NSScreen.screens.first { $0.frame.contains(point) } } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        // 新版 macOS 的图标窗口由系统托管，取不到坐标时用点击位置，再不行退回右上角。
        let midX = reference?.x ?? (visible.maxX - size.width / 2 - 8)
        let x = min(max(midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = visible.maxY - size.height - 6
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func statusItemFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window, window.isVisible else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let isOnScreen = NSScreen.screens.contains { $0.frame.insetBy(dx: 0, dy: -1).contains(NSPoint(x: rect.midX, y: rect.midY)) }
        guard isOnScreen, rect.width > 0 else { return nil }
        // 真正显示在菜单栏里的图标贴着屏幕顶部。
        let nearTop = NSScreen.screens.contains { abs($0.frame.maxY - rect.maxY) < 40 && $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
        return nearTop ? rect : nil
    }

    private func installMonitors() {
        removeMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let time = event.timestamp
            MainActor.assumeIsolated {
                if self?.hidesOnOutsideClick == true { self?.dismissForOutsideClick(at: time) }
            }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, self.panel?.isVisible == true {
                    self.hidePanel()
                    return nil
                }
                return event
            }
            if event.window !== self.panel, event.window !== self.statusItem.button?.window {
                self.dismissForOutsideClick(at: event.timestamp)
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

enum StatusPanelMetrics {
    static let width: CGFloat = 348
    static let cornerRadius: CGFloat = 22
}

enum StatusIcon {
    /// 模板图标，由系统按菜单栏明暗自动着色。
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let source = NSPoint(x: 3.6, y: 9)
            let top = NSPoint(x: 14.4, y: 4.4)
            let bottom = NSPoint(x: 14.4, y: 13.6)

            let active = NSBezierPath()
            active.lineWidth = 1.7
            active.lineCapStyle = .round
            active.move(to: source)
            active.curve(to: top, controlPoint1: NSPoint(x: 8.5, y: 9), controlPoint2: NSPoint(x: 8.5, y: 4.4))
            active.stroke()

            let inactive = NSBezierPath()
            inactive.lineWidth = 1.7
            inactive.lineCapStyle = .round
            inactive.move(to: source)
            inactive.curve(to: bottom, controlPoint1: NSPoint(x: 8.5, y: 9), controlPoint2: NSPoint(x: 8.5, y: 13.6))
            NSColor.black.withAlphaComponent(0.42).setStroke()
            inactive.stroke()

            NSBezierPath(ovalIn: NSRect(x: source.x - 2.3, y: source.y - 2.3, width: 4.6, height: 4.6)).fill()
            NSBezierPath(ovalIn: NSRect(x: top.x - 2.3, y: top.y - 2.3, width: 4.6, height: 4.6)).fill()
            let ring = NSBezierPath(ovalIn: NSRect(x: bottom.x - 1.75, y: bottom.y - 1.75, width: 3.5, height: 3.5))
            ring.lineWidth = 1.2
            NSColor.black.setStroke()
            ring.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
