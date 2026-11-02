import AppKit
import ModelBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusBar: StatusBarController?
    private var settings: SettingsWindowController?

    /// 菜单栏放不下时图标会被刘海挡住，这时再次打开应用也要能看到界面。
    private static let reopenNotification = Notification.Name("com.local.modelbar.reopen")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = AppPaths.current()
        if !paths.isSandboxed, activateExistingInstance() {
            NSApp.terminate(nil)
            return
        }

        NSApp.mainMenu = MainMenu.make()

        let model = AppModel(paths: paths)
        let settings = SettingsWindowController(model: model)
        let statusBar = StatusBarController(model: model) { page in
            settings.show(page: page)
        }
        self.model = model
        self.settings = settings
        self.statusBar = statusBar
        model.start()

        DistributedNotificationCenter.default().addObserver(
            forName: Self.reopenNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showMainInterface() }
        }

        #if DEBUG
        let defaults = UserDefaults.standard
        if let script = defaults.string(forKey: "dev-script"), let output = defaults.string(forKey: "dev-output") {
            let driver = DevDriver(statusBar: statusBar, settings: settings, output: URL(fileURLWithPath: output))
            Task { await driver.run(script: URL(fileURLWithPath: script)) }
            return
        }
        #endif
        if model.state.endpoints.isEmpty {
            settings.show(page: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainInterface()
        return true
    }

    private func showMainInterface() {
        if model?.state.endpoints.isEmpty == true {
            settings?.show(page: nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            statusBar?.showPanel()
        }
    }

    private func activateExistingInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        guard let existing = others.first else { return false }
        existing.activate()
        DistributedNotificationCenter.default().postNotificationName(
            Self.reopenNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
        return true
    }
}

/// 辅助应用的菜单栏不显示，但文本框的 ⌘C、⌘V 依赖这份菜单。
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 ModelBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)

        return main
    }
}
