#if DEBUG
import AppKit
import ModelBarCore

/// 调试版专用：按脚本在进程内点击、输入并给自己的窗口截图。
/// 用法：MODELBAR_HOME=<沙盒目录> ModelBar --dev-script <脚本> --dev-output <目录>
@MainActor
final class DevDriver {
    private let statusBar: StatusBarController
    private let settings: SettingsWindowController
    private let output: URL

    init(statusBar: StatusBarController, settings: SettingsWindowController, output: URL) {
        self.statusBar = statusBar
        self.settings = settings
        self.output = output
        statusBar.hidesOnOutsideClick = false
    }

    func run(script: URL) async {
        let text = (try? String(contentsOf: script, encoding: .utf8)) ?? ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            await perform(parts[0], parts.count > 1 ? parts[1] : "")
        }
        NSApp.terminate(nil)
    }

    private func perform(_ command: String, _ argument: String) async {
        print("dev> \(command) \(argument)")
        let arguments = argument.split(separator: " ").map(String.init)
        switch command {
        case "wait":
            try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
        case "panel":
            statusBar.showPanel()
        case "hide-panel":
            statusBar.hidePanel()
        case "settings":
            settings.show(page: nil)
        case "page":
            settings.show(page: page(named: argument))
        case "snap":
            snapshot(window(named: arguments[0]), name: arguments[1])
        case "snap-shadow":
            snapshot(window(named: arguments[0]), name: arguments[1], includingShadow: true)
        case "click":
            click(window(named: arguments[0]), x: Double(arguments[1]) ?? 0, y: Double(arguments[2]) ?? 0)
        case "type":
            guard let target = NSApp.keyWindow, let input = target.firstResponder as? NSTextInputClient else {
                print("dev> no text input focused")
                return
            }
            input.insertText(argument, replacementRange: NSRange(location: NSNotFound, length: 0))
        case "select-all":
            // 走真实的按键路径，确认隐藏菜单能响应 ⌘ 快捷键。
            guard let target = NSApp.keyWindow, let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: target.windowNumber,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            ) else { return }
            NSApp.sendEvent(event)
        case "focused":
            let responder = NSApp.keyWindow?.firstResponder
            let selected = (responder as? NSTextView)?.selectedRange()
            print("dev> focused \(type(of: responder as Any)) string=\((responder as? NSTextView)?.string ?? "") selected=\(String(describing: selected))")
        case "icon":
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let scale: CGFloat = 8
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(18 * scale), pixelsHigh: Int(18 * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 18 * scale, height: 18 * scale).fill()
            StatusIcon.make().draw(in: NSRect(x: 0, y: 0, width: 18 * scale, height: 18 * scale))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: output.appending(path: "status-icon.png"))
        case "appearance":
            NSApp.appearance = NSAppearance(named: argument == "dark" ? .darkAqua : .aqua)
        case "windows":
            print("dev> screens \(NSScreen.screens.map { "\($0.localizedName) frame=\($0.frame) safeTop=\($0.safeAreaInsets.top)" })")
            for window in NSApp.windows where window.isVisible {
                print("dev> window \(window.title) level=\(window.level.rawValue) frame=\(window.frame)")
            }
        default:
            print("dev> unknown command \(command)")
        }
    }

    private func page(named name: String) -> SettingsPage? {
        switch name {
        case "tools": .tools
        case "general": .general
        case "about": .about
        default: nil
        }
    }

    private func window(named name: String) -> NSWindow? {
        NSApp.windows.first { window in
            guard window.isVisible else { return false }
            switch name {
            case "panel": return window is NSPanel
            case "sheet": return window.isSheet
            default: return !(window is NSPanel) && !window.isSheet && window.frame.width > 200
            }
        }
    }

    private func click(_ window: NSWindow?, x: Double, y: Double) {
        guard let window else {
            print("dev> no such window")
            return
        }
        let location = NSPoint(x: x, y: window.frame.height - y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else { continue }
            NSApp.sendEvent(event)
        }
    }

    /// 窗口服务器合成的画面更接近真实效果，取不到时退回视图缓存。
    private func snapshot(_ window: NSWindow?, name: String, includingShadow: Bool = false) {
        guard let window else {
            print("dev> no window for \(name)")
            return
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = output.appending(path: "\(name).png")
        let rep = composited(window, includingShadow: includingShadow) ?? cached(window)
        guard let rep, let data = rep.representation(using: .png, properties: [:]) else {
            print("dev> snapshot failed \(name)")
            return
        }
        try? data.write(to: url)
        print("dev> wrote \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    private func composited(_ window: NSWindow, includingShadow: Bool) -> NSBitmapImageRep? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageDefault = 0（含阴影）, kCGWindowImageBoundsIgnoreFraming = 1
        guard let image = capture(.null, 8, UInt32(window.windowNumber), includingShadow ? 0 : 1)?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    private func cached(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
#endif
