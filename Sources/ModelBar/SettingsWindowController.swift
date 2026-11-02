import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show(page: SettingsPage?) {
        if let page {
            model.settingsPage = page
        } else if model.settingsPage == nil {
            model.settingsPage = model.state.activeEndpointID.map { .endpoint($0) }
                ?? model.state.endpoints.first.map { .endpoint($0.id) }
                ?? .tools
        }
        if model.state.endpoints.isEmpty, page == nil { model.isAddingEndpoint = true }

        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // 不让第一个输入框抢焦点并全选内容。
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.title = "ModelBar"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 620))
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        window.setFrameAutosaveName("ModelBarSettings")
        return window
    }
}
