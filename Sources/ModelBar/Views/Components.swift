import SwiftUI
import ModelBarCore

/// 接口的图标：有官方图标时放在白底上，否则用名称的第一个字。
struct EndpointGlyph: View {
    let name: String
    var host: String? = nil
    /// 列表里由 AppModel 分配，避免撞色。
    var colorIndex: Int? = nil
    var size: CGFloat = 28

    @Environment(\.colorScheme) private var colorScheme

    @MainActor private static var logos: [String: NSImage] = [:]

    @MainActor private static func image(for logo: String) -> NSImage? {
        if let image = logos[logo] { return image }
        guard let url = Bundle.main.url(forResource: logo, withExtension: "png", subdirectory: "Logos"),
              let image = NSImage(contentsOf: url) else { return nil }
        logos[logo] = image
        return image
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
    }

    var body: some View {
        Group {
            if let logo = EndpointLogo.match(name: name, host: host), let image = Self.image(for: logo) {
                logoTile(image)
            } else {
                letterTile
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// 暗色模式下也用白底，否则黑色的 Logo 会看不见。
    private func logoTile(_ image: NSImage) -> some View {
        shape
            .fill(.white)
            .overlay { shape.strokeBorder(.black.opacity(0.1), lineWidth: 0.5) }
            .overlay {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size * 0.68, height: size * 0.68)
            }
    }

    private var letterTile: some View {
        let isDark = colorScheme == .dark
        let hue = (0.58 + Double(colorIndex ?? EndpointGlyphColors.index(for: name)) / Double(EndpointGlyphColors.count))
            .truncatingRemainder(dividingBy: 1)
        return shape
            .fill(Color(hue: hue, saturation: 0.7, brightness: 0.85).opacity(isDark ? 0.3 : 0.16))
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(hue: hue, saturation: isDark ? 0.4 : 0.8, brightness: isDark ? 0.98 : 0.55))
            }
    }
}

struct ToolTile: View {
    let tool: ToolID
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: tool.symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var colors: [Color] {
        switch tool {
        case .claudeCode: [Color(red: 0.91, green: 0.55, blue: 0.40), Color(red: 0.78, green: 0.38, blue: 0.25)]
        case .codex: [Color(red: 0.32, green: 0.55, blue: 1.0), Color(red: 0.17, green: 0.34, blue: 0.86)]
        case .opencode: [Color(white: 0.34), Color(white: 0.16)]
        case .pi: [Color(red: 0.25, green: 0.78, blue: 0.68), Color(red: 0.08, green: 0.56, blue: 0.50)]
        case .grok: [Color(white: 0.20), Color(white: 0.05)]
        case .droid: [Color(red: 0.62, green: 0.50, blue: 0.96), Color(red: 0.40, green: 0.28, blue: 0.80)]
        case .kilo: [Color(red: 0.98, green: 0.72, blue: 0.27), Color(red: 0.90, green: 0.50, blue: 0.10)]
        }
    }
}

struct PanelModule<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 5)
            VStack(spacing: 1) { content }
                .padding(5)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                        }
                }
        }
    }
}

/// 面板里的可点击行：悬停时高亮。
struct RowButtonStyle: ButtonStyle {
    var isSelected = false
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fill(pressed: configuration.isPressed))
            }
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovering)
    }

    private func fill(pressed: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(pressed ? 0.28 : 0.2) }
        if pressed { return Color.primary.opacity(0.12) }
        return isHovering ? Color.primary.opacity(0.07) : .clear
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var isSpinning = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if isSpinning {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)
            .background {
                Circle().fill(isHovering ? Color.primary.opacity(0.09) : .clear)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovering = $0 }
    }
}

extension ToolState {
    var tint: Color {
        switch self {
        case .synced: .green
        case .stale, .incompatible: .orange
        case .failed: .red
        case .noSelection, .disabled, .notInstalled: .secondary
        }
    }
}

extension ModelInfo {
    var contextLabel: String? {
        guard let contextLength else { return nil }
        if contextLength >= 1_000_000 {
            let value = Double(contextLength) / 1_000_000
            return value == value.rounded() ? "\(Int(value))M" : String(format: "%.1fM", value)
        }
        return "\(contextLength / 1000)K"
    }
}

/// 用 ID 关联的模型名使用等宽字体，便于辨认版本号。
struct ModelName: View {
    let id: String
    var size: CGFloat = 12.5

    var body: some View {
        Text(id)
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

struct SizeReader: ViewModifier {
    let onChange: (CGSize) -> Void

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onChange(proxy.size) }
                    .onChange(of: proxy.size) { _, size in onChange(size) }
            }
        }
    }
}
