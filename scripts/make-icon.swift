// 用法：swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon Resources/AppIcon.iconset
import AppKit

func drawIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let scale = CGFloat(pixels) / 1024
    cg.scaleBy(x: scale, y: scale)

    // macOS 图标网格：1024 画布内 824 的主体，上下留出投影空间。
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let radius: CGFloat = 186
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.34).cgColor)
    cg.addPath(shape)
    cg.setFillColor(NSColor.black.cgColor)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let background = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.235, green: 0.247, blue: 0.290, alpha: 1).cgColor,
        NSColor(srgbRed: 0.078, green: 0.082, blue: 0.106, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let sheen = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.13).cgColor,
        NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(sheen, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                          endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
    cg.setLineWidth(3)
    cg.strokePath()
    cg.restoreGState()

    let source = CGPoint(x: 300, y: 512)
    let top = CGPoint(x: 724, y: 684)
    let bottom = CGPoint(x: 724, y: 340)
    let control: CGFloat = 512

    cg.setLineCap(.round)
    cg.setLineWidth(46)

    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.26).cgColor)
    cg.move(to: source)
    cg.addCurve(to: bottom, control1: CGPoint(x: control, y: 512), control2: CGPoint(x: control, y: 340))
    cg.strokePath()

    cg.saveGState()
    let route = CGMutablePath()
    route.move(to: source)
    route.addCurve(to: top, control1: CGPoint(x: control, y: 512), control2: CGPoint(x: control, y: 684))
    cg.addPath(route.copy(strokingWithWidth: 46, lineCap: .round, lineJoin: .round, miterLimit: 10))
    cg.clip()
    let accent = CGGradient(colorsSpace: space, colors: [
        NSColor.white.cgColor,
        NSColor(srgbRed: 1.0, green: 0.70, blue: 0.36, alpha: 1).cgColor,
    ] as CFArray, locations: [0.15, 1])!
    cg.drawLinearGradient(accent, start: source, end: top, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()

    cg.setFillColor(NSColor.white.cgColor)
    cg.fillEllipse(in: CGRect(x: source.x - 62, y: source.y - 62, width: 124, height: 124))

    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 60, color: NSColor(srgbRed: 1, green: 0.55, blue: 0.2, alpha: 0.75).cgColor)
    cg.setFillColor(NSColor(srgbRed: 1, green: 0.62, blue: 0.27, alpha: 1).cgColor)
    cg.fillEllipse(in: CGRect(x: top.x - 66, y: top.y - 66, width: 132, height: 132))
    cg.restoreGState()

    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.42).cgColor)
    cg.setLineWidth(26)
    cg.strokeEllipse(in: CGRect(x: bottom.x - 48, y: bottom.y - 48, width: 96, height: 96))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try drawIcon(pixels: size).write(to: output.appending(path: "icon_\(size)x\(size).png"))
    try drawIcon(pixels: size * 2).write(to: output.appending(path: "icon_\(size)x\(size)@2x.png"))
}
