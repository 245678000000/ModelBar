import SwiftUI
import ModelBarCore

struct PanelView: View {
    @Bindable var model: AppModel
    let openSettings: (SettingsPage?) -> Void
    let quit: () -> Void
    let onSize: (CGSize) -> Void

    var body: some View {
        VStack(spacing: 11) {
            header
            if model.state.endpoints.isEmpty {
                emptyState
            } else {
                endpointsModule
                if let endpoint = model.activeEndpoint {
                    ModelModule(model: model, endpoint: endpoint, openSettings: openSettings)
                }
                toolsModule
            }
            if let update = model.availableUpdate {
                UpdateBanner(model: model, update: update)
            }
            if let notice = model.notice {
                NoticeView(notice: notice)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            footer
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(width: StatusPanelMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.snappy(duration: 0.22), value: model.notice)
        .modifier(SizeReader(onChange: onSize))
        .modifier(PanelGlass())
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("ModelBar")
                .font(.system(size: 13, weight: .semibold))
            if model.isSyncing {
                ProgressView().controlSize(.mini)
                    .transition(.opacity)
            }
            Spacer()
            if let active = model.activeEndpoint {
                IconButton(
                    symbol: "arrow.clockwise",
                    help: "测试当前接口",
                    isSpinning: model.testing.contains(active.id)
                ) { model.test(active.id) }
            }
            IconButton(symbol: "gearshape", help: "打开设置") { openSettings(nil) }
        }
        .padding(.leading, 5)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.secondary)
            Text("还没有接口")
                .font(.system(size: 13, weight: .semibold))
            Text("添加一个 API 接口后，就能一键同步到各个工具。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("添加接口") {
                model.isAddingEndpoint = true
                openSettings(.tools)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    private var endpointsModule: some View {
        PanelModule(title: "接口") {
            ForEach(model.state.endpoints) { endpoint in
                EndpointRow(
                    endpoint: endpoint,
                    colorIndex: model.glyphColorIndex(for: endpoint),
                    isActive: endpoint.id == model.state.activeEndpointID,
                    isTesting: model.testing.contains(endpoint.id)
                ) {
                    withAnimation(.snappy(duration: 0.18)) { model.activate(endpoint.id) }
                }
            }
            Button {
                model.isAddingEndpoint = true
                openSettings(model.state.activeEndpointID.map { .endpoint($0) })
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 22)
                    Text("添加接口")
                        .font(.system(size: 12.5))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    private var toolsModule: some View {
        PanelModule(title: "同步到") {
            ForEach(ToolID.allCases.filter { model.status(of: $0) != .notInstalled || model.isEnabled($0) }) { tool in
                ToolRow(model: model, tool: tool, openSettings: openSettings)
            }
            if model.hiddenToolCount > 0 {
                Button("还有 \(model.hiddenToolCount) 个工具未安装") { openSettings(.tools) }
                    .buttonStyle(.link)
                    .font(.system(size: 10.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("退出后，工具仍按当前配置运行")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("退出", action: quit)
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5)
    }
}

private struct PanelGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: StatusPanelMetrics.cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .clipShape(shape)
        }
    }
}

private struct EndpointRow: View {
    let endpoint: Endpoint
    let colorIndex: Int?
    let isActive: Bool
    let isTesting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                EndpointGlyph(name: endpoint.name, host: endpoint.host, colorIndex: colorIndex)
                VStack(alignment: .leading, spacing: 0) {
                    Text(endpoint.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(endpoint.host)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                trailing
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .buttonStyle(RowButtonStyle(isSelected: isActive))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private var trailing: some View {
        if isTesting {
            ProgressView().controlSize(.mini)
        } else if isActive {
            HStack(spacing: 6) {
                if let latency = endpoint.probe?.latencyMs {
                    Text("\(latency) ms")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if endpoint.probe?.models == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .help(endpoint.probe?.message ?? "接口测试失败")
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}

private struct ModelModule: View {
    @Bindable var model: AppModel
    let endpoint: Endpoint
    let openSettings: (SettingsPage?) -> Void
    @State private var isOpen = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [ModelInfo] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return endpoint.models }
        return endpoint.models.filter { $0.id.lowercased().contains(query) }
    }

    var body: some View {
        PanelModule(title: "模型") {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isOpen.toggle()
                    search = ""
                }
                if isOpen { searchFocused = true }
            } label: {
                HStack(spacing: 8) {
                    if let selected = endpoint.selectedModel {
                        ModelName(id: selected)
                    } else {
                        Text(endpoint.models.isEmpty ? "还没有模型" : "选择模型")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let label = endpoint.currentModel?.contextLabel {
                        Text(label)
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityLabel("选择模型")

            if isOpen { list }

            if !isOpen {
                effortRow
            }
        }
    }

    private var list: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索模型", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if endpoint.models.isEmpty {
                VStack(spacing: 6) {
                    Text("这个接口没有返回模型列表")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Button("手动添加") { openSettings(.endpoint(endpoint.id)) }
                        .controlSize(.small)
                }
                .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filtered) { item in
                            Button {
                                model.selectModel(item.id, for: endpoint.id)
                                withAnimation(.snappy(duration: 0.2)) { isOpen = false }
                            } label: {
                                HStack(spacing: 6) {
                                    ModelName(id: item.id, size: 12)
                                    Spacer(minLength: 4)
                                    if let label = item.contextLabel {
                                        Text(label)
                                            .font(.system(size: 10.5).monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    if item.id == endpoint.selectedModel {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(RowButtonStyle())
                        }
                    }
                }
                .frame(maxHeight: 190)
                if filtered.isEmpty {
                    Text("没有匹配的模型")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
        .transition(.opacity)
    }

    private var effortRow: some View {
        let current = endpoint.currentModel
        let levels = current?.availableEfforts ?? ReasoningEffort.allCases
        let unsupported = current?.supportsReasoning == false
        return HStack(spacing: 8) {
            Text("推理档位")
                .font(.system(size: 12))
                .foregroundStyle(unsupported ? .tertiary : .secondary)
                .layoutPriority(1)
            Spacer(minLength: 2)
            Picker("推理档位", selection: Binding(
                get: { levels.contains(endpoint.effort) ? endpoint.effort : .automatic },
                set: { model.setEffort($0, for: endpoint.id) }
            )) {
                ForEach(levels) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .disabled(unsupported || current == nil)
            .help(unsupported ? "这个模型不支持推理档位" : "发送给接口的 reasoning_effort")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

private struct ToolRow: View {
    @Bindable var model: AppModel
    let tool: ToolID
    let openSettings: (SettingsPage?) -> Void

    private var state: ToolState { model.status(of: tool) }
    private var isBridged: Bool { model.isBridged(tool) }

    var body: some View {
        HStack(spacing: 10) {
            ToolTile(tool: tool, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(tool.title)
                    .font(.system(size: 12.5, weight: .medium))
                statusLine
            }
            Spacer(minLength: 6)
            control
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .help(state.detail ?? "")
    }

    @ViewBuilder
    private var statusLine: some View {
        if state == .disabled {
            Text(tool.subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(isBridged && state == .synced ? "已同步 · 本机转换" : state.detail ?? state.title)
                .font(.system(size: 10.5))
                .foregroundStyle(state.tint)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if model.canOfferBridge(for: tool) {
                Button("开启本机转换") { model.setBridge(enabled: true) }
                    .buttonStyle(.link)
                    .font(.system(size: 10.5, weight: .medium))
                    .help("运行一个只监听本机的后台服务，让这个工具也能用这个接口")
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        if state == .notInstalled {
            Button("安装") { openSettings(.tools) }
                .controlSize(.small)
        } else if state == .stale {
            Button("修复") { model.resync() }
                .controlSize(.small)
        } else {
            Toggle(tool.title, isOn: Binding(
                get: { model.isEnabled(tool) },
                set: { model.setTool(tool, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }
}

private struct UpdateBanner: View {
    let model: AppModel
    let update: AppUpdate

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.tint)
            Text("新版本 \(update.version.description)")
                .font(.system(size: 11.5, weight: .medium))
            Button("详情") { model.openUpdatePage() }
                .buttonStyle(.link)
                .font(.system(size: 10.5))
            Spacer(minLength: 0)
            if model.isInstallingUpdate {
                ProgressView().controlSize(.mini)
                Text("正在更新…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Button("安装并重启") { model.installUpdate() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
    }
}

struct NoticeView: View {
    let notice: Notice

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: notice.kind == .error ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(notice.kind == .error ? Color.red : Color.green)
            Text(notice.text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
