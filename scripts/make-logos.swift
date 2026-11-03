import AppKit
import WebKit

// 把 SVG 渲染成透明背景的 PNG。用 WebKit 是因为有些图标带滤镜和遮罩，NSImage 画不对。
// 用法：make-logos <SVG 目录> <输出目录>，文件名里的 -color 后缀会去掉。
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("用法：make-logos <SVG 目录> <输出目录>")
    exit(2)
}
let source = URL(fileURLWithPath: arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
let pixels: CGFloat = 128

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var pending: [URL]

    init(files: [URL]) {
        pending = files
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        webView.setValue(false, forKey: "drawsBackground")
        super.init()
        webView.navigationDelegate = self
    }

    func next() {
        guard let file = pending.first else { exit(0) }
        guard let svg = try? String(contentsOf: file, encoding: .utf8) else {
            print("无法读取 \(file.lastPathComponent)")
            exit(1)
        }
        let style = "html,body{margin:0;padding:0;background:transparent}svg{display:block;width:\(Int(pixels))px;height:\(Int(pixels))px}"
        webView.loadHTMLString("<!doctype html><style>\(style)</style>\(svg)", baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(pixels))
        webView.takeSnapshot(with: configuration) { [self] image, error in
            guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                print("渲染失败：\(error?.localizedDescription ?? "未知错误")")
                exit(1)
            }
            let file = pending.removeFirst()
            let name = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-color", with: "")
            do {
                try png.write(to: output.appending(path: "\(name).png"))
            } catch {
                print("无法写入 \(name).png：\(error.localizedDescription)")
                exit(1)
            }
            print("\(name).png \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) \(png.count) 字节")
            next()
        }
    }
}

let files = ((try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "svg" }
    .sorted { $0.path < $1.path }
guard !files.isEmpty else {
    print("\(source.path) 里没有 SVG")
    exit(1)
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
MainActor.assumeIsolated {
    let renderer = Renderer(files: files)
    renderer.next()
    application.run()
}
