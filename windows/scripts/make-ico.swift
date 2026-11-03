// 把 PNG 打包成 Windows .ico。小尺寸用 DIB，兼容 NotifyIcon；256 用 PNG。
// 用法：swiftc scripts/make-ico.swift -o /tmp/make-ico && /tmp/make-ico <iconset 目录> <输出.ico>
import AppKit

let arguments = CommandLine.arguments
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: arguments[2])

func littleEndian16(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]) }
func littleEndian32(_ value: Int) -> Data {
    Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
}

func dibFrame(_ size: Int, from file: URL) -> Data {
    let image = NSImage(contentsOf: file)!
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    var data = Data()
    data += littleEndian32(40) + littleEndian32(size) + littleEndian32(size * 2)
    data += littleEndian16(1) + littleEndian16(32) + littleEndian32(0)
    data += littleEndian32(size * size * 4) + littleEndian32(0) + littleEndian32(0) + littleEndian32(0) + littleEndian32(0)
    for y in stride(from: size - 1, through: 0, by: -1) {
        for x in 0..<size {
            let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .clear
            // DIB 用未预乘的 BGRA。
            data.append(UInt8(c.blueComponent * 255))
            data.append(UInt8(c.greenComponent * 255))
            data.append(UInt8(c.redComponent * 255))
            data.append(UInt8(c.alphaComponent * 255))
        }
    }
    data.append(Data(count: size * ((size + 31) / 32 * 4)))
    return data
}

let frames: [(Int, Data)] = [
    (16, dibFrame(16, from: directory.appending(path: "icon_16x16@2x.png"))),
    (20, dibFrame(20, from: directory.appending(path: "icon_32x32.png"))),
    (24, dibFrame(24, from: directory.appending(path: "icon_32x32.png"))),
    (32, dibFrame(32, from: directory.appending(path: "icon_32x32@2x.png"))),
    (48, dibFrame(48, from: directory.appending(path: "icon_128x128.png"))),
    (64, dibFrame(64, from: directory.appending(path: "icon_128x128.png"))),
    (256, try! Data(contentsOf: directory.appending(path: "icon_256x256.png"))),
]

var ico = littleEndian16(0) + littleEndian16(1) + littleEndian16(frames.count)
var offset = 6 + frames.count * 16
for (size, data) in frames {
    ico.append(UInt8(size == 256 ? 0 : size))
    ico.append(UInt8(size == 256 ? 0 : size))
    ico += Data([0, 0]) + littleEndian16(1) + littleEndian16(32) + littleEndian32(data.count) + littleEndian32(offset)
    offset += data.count
}
for (_, data) in frames { ico += data }
try! ico.write(to: output)
