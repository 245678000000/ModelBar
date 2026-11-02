import SwiftUI
import ModelBarCore

/// 接口的彩色图标，颜色由名称决定，同一个接口始终同色。
struct EndpointGlyph: View {
    let name: String
    var size: CGFloat = 28

    private static let palettes: [(Color, Color)] = [
        (Color(red: 0.36, green: 0.55, blue: 1.00), Color(red: 0.20, green: 0.36, blue: 0.90)),
        (Color(red: 0.25, green: 0.78, blue: 0.72), Color(red: 0.08, green: 0.56, blue: 0.56)),
        (Color(red: 1.00, green: 0.62, blue: 0.30), Color(red: 0.93, green: 0.40, blue: 0.16)),
        (Color(red: 0.98, green: 0.45, blue: 0.56), Color(red: 0.84, green: 0.22, blue: 0.40)),
        (Color(red: 0.42, green: 0.80, blue: 0.42), Color(red: 0.18, green: 0.58, blue: 0.30)),
        (Color(red: 0.64, green: 0.56, blue: 0.98), Color(red: 0.42, green: 0.33, blue: 0.84)),
        (Color(red: 0.50, green: 0.53, blue: 0.60), Color(red: 0.30, green: 0.32, blue: 0.38)),
    ]

    var body: some View {
        let colors = Self.palettes[Self.index(for: name)]
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private static func index(for name: String) -> Int {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return abs(sum) % palettes.count
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
        case .opencode: [Color(white: 0.34), Color(white: 0.16)]
        case .codex: [Color(red: 0.32, green: 0.55, blue: 1.0), Color(red: 0.17, green: 0.34, blue: 0.86)]
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
