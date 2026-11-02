import AppKit
import SwiftUI
import ModelBarCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.settingsPage) {
                Section("接口") {
                    ForEach(model.state.endpoints) { endpoint in
                        HStack(spacing: 8) {
                            EndpointGlyph(name: endpoint.name, size: 20)
                            Text(endpoint.name).lineLimit(1)
                            Spacer(minLength: 2)
                            if endpoint.id == model.state.activeEndpointID {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("当前使用")
                            }
                        }
                        .tag(SettingsPage.endpoint(endpoint.id))
                    }
                    Button {
                        model.isAddingEndpoint = true
                    } label: {
                        Label("添加接口", systemImage: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Section("应用") {
                    Label("工具同步", systemImage: "arrow.triangle.2.circlepath").tag(SettingsPage.tools)
                    Label("通用", systemImage: "gearshape").tag(SettingsPage.general)
                    Label("关于", systemImage: "info.circle").tag(SettingsPage.about)
                }
            }
            .listStyle(.sidebar)
            .modifier(CleanTopEdge())
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(isPresented: $model.isAddingEndpoint) {
            AddEndpointSheet(model: model)
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                NoticeView(notice: notice)
                    .frame(maxWidth: 420)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.snappy(duration: 0.22), value: model.notice)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.settingsPage {
        case .endpoint(let id):
            if model.endpoint(id) != nil {
                EndpointDetailView(model: model, endpointID: id)
                    .id(id)
            } else {
                placeholder
            }
        case .tools:
            ToolsPane(model: model)
        case .general:
            GeneralPane(model: model)
        case .about:
            AboutPane()
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableView("选择一个接口", systemImage: "point.3.connected.trianglepath.dotted")
    }
}

/// 去掉滚动区域顶部的分隔线，让内容和窗口标题栏融为一体。
private struct CleanTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

// MARK: - 接口详情

private struct EndpointDetailView: View {
    @Bindable var model: AppModel
    let endpointID: UUID

    @State private var name = ""
    @State private var baseURL = ""
    @State private var keyDraft = ""
    @State private var isRevealed = false
    @State private var keyEdited = false
    @State private var error: String?
    @State private var modelSearch = ""
    @State private var manualModel = ""
    @State private var confirmDelete = false

    private var endpoint: Endpoint? { model.endpoint(endpointID) }

    private var isDirty: Bool {
        guard let endpoint else { return false }
        return name != endpoint.name
            || Endpoint.normalize(baseURL: baseURL) != endpoint.baseURL
            || (keyEdited && !keyDraft.isEmpty)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && Endpoint.isValid(baseURL: baseURL)
    }

    var body: some View {
        if let endpoint {
            Form {
                hero(endpoint)
                connection(endpoint)
                testing(endpoint)
                modelsSection(endpoint)
                effortSection(endpoint)
                manualUse(endpoint)
                Section {
                    Button("删除这个接口", role: .destructive) { confirmDelete = true }
                }
            }
            .formStyle(.grouped)
            .modifier(CleanTopEdge())
            .onAppear(perform: load)
            .confirmationDialog("删除“\(endpoint.name)”？", isPresented: $confirmDelete) {
                Button("删除", role: .destructive) { model.deleteEndpoint(endpointID) }
            } message: {
                Text("密钥会一起从钥匙串移除。如果它正在使用，工具会切到下一个接口。")
            }
        }
    }

    private func load() {
        guard let endpoint else { return }
        name = endpoint.name
        baseURL = endpoint.baseURL
    }

    private func save() {
        do {
            let newKey = keyEdited && !keyDraft.isEmpty ? keyDraft : nil
            try model.updateEndpoint(endpointID, name: name, baseURL: baseURL, key: newKey)
            keyEdited = false
            if !isRevealed { keyDraft = "" }
            baseURL = Endpoint.normalize(baseURL: baseURL)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func hero(_ endpoint: Endpoint) -> some View {
        Section {
            HStack(spacing: 14) {
                EndpointGlyph(name: endpoint.name, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(endpoint.name).font(.title2.weight(.semibold))
                    Text(endpoint.host).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if endpoint.id == model.state.activeEndpointID {
                    Label("使用中", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    Button("设为当前") { model.activate(endpoint.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func connection(_ endpoint: Endpoint) -> some View {
        Section("连接") {
            TextField("名称", text: $name)
            LabeledContent("Base URL") {
                TextField("Base URL", text: $baseURL, prompt: Text("https://api.example.com/v1"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
            }
            LabeledContent("API Key") {
                HStack(spacing: 8) {
                    Group {
                        if isRevealed {
                            TextField("API Key", text: keyBinding, prompt: Text("sk-…"))
                        } else {
                            SecureField("API Key", text: keyBinding, prompt: Text(endpoint.hasKey ? "已保存在钥匙串，输入新值可替换" : "sk-…（本地接口可留空）"))
                        }
                    }
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .monospaced))
                    if endpoint.hasKey {
                        Button {
                            toggleReveal()
                        } label: {
                            Image(systemName: isRevealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(isRevealed ? "隐藏密钥" : "显示密钥")
                        .accessibilityLabel(isRevealed ? "隐藏密钥" : "显示密钥")
                    }
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            if isDirty {
                HStack {
                    if !canSave {
                        Text("请填写名称和以 http:// 或 https:// 开头的地址")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("还原") {
                        load()
                        keyDraft = ""
                        keyEdited = false
                    }
                    Button("保存", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var keyBinding: Binding<String> {
        Binding(
            get: { keyDraft },
            set: {
                keyDraft = $0
                keyEdited = true
            }
        )
    }

    private func toggleReveal() {
        if isRevealed {
            isRevealed = false
            if !keyEdited { keyDraft = "" }
        } else {
            if !keyEdited { keyDraft = model.readKey(endpointID) ?? "" }
            isRevealed = true
        }
    }

    private func testing(_ endpoint: Endpoint) -> some View {
        Section {
            ProbeRow(title: "模型列表", caption: "GET /models", status: endpoint.probe?.models ?? .unknown)
            ProbeRow(title: "Chat Completions", caption: "opencode、Kilo Code 使用", status: endpoint.probe?.chat ?? .unknown)
            ProbeRow(title: "Responses", caption: "Codex CLI 需要", status: endpoint.probe?.responses ?? .unknown)
            if let message = endpoint.probe?.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("连接测试")
                Spacer()
                if let latency = endpoint.probe?.latencyMs {
                    Text("\(latency) ms").monospacedDigit().foregroundStyle(.secondary)
                }
                if model.testing.contains(endpoint.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("重新测试") {
                        if isDirty && canSave { save() } else { model.test(endpoint.id) }
                    }
                    .controlSize(.small)
                }
            }
        } footer: {
            Text("测试会发送两条极短的真实请求，可能产生极少量费用。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func modelsSection(_ endpoint: Endpoint) -> some View {
        Section {
            if endpoint.models.count > 6 {
                TextField("搜索模型", text: $modelSearch)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            if !endpoint.models.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredModels(endpoint)) { item in
                            Button {
                                model.selectModel(item.id, for: endpoint.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.id == endpoint.selectedModel ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(item.id == endpoint.selectedModel ? Color.accentColor : .secondary)
                                    ModelName(id: item.id)
                                    Spacer()
                                    if let label = item.contextLabel {
                                        Text(label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    if item.supportsReasoning == true {
                                        Image(systemName: "brain")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .help("支持推理档位")
                                    }
                                }
                                .padding(.vertical, 5)
                                .padding(.horizontal, 6)
                            }
                            .buttonStyle(RowButtonStyle())
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            LabeledContent("手动添加") {
                HStack(spacing: 8) {
                    TextField("手动添加", text: $manualModel, prompt: Text("输入模型名"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(addManual)
                    Button("添加", action: addManual)
                        .disabled(manualModel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            HStack {
                Text("模型")
                if !endpoint.models.isEmpty {
                    Text("\(endpoint.models.count)").foregroundStyle(.secondary)
                }
                Spacer()
                if model.loadingModels.contains(endpoint.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("刷新") { model.refreshModels(endpoint.id) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func addManual() {
        model.addManualModel(manualModel, for: endpointID)
        manualModel = ""
    }

    private func filteredModels(_ endpoint: Endpoint) -> [ModelInfo] {
        let query = modelSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return endpoint.models }
        return endpoint.models.filter { $0.id.lowercased().contains(query) }
    }

    private func effortSection(_ endpoint: Endpoint) -> some View {
        let current = endpoint.currentModel
        let levels = current?.availableEfforts ?? ReasoningEffort.allCases
        return Section {
            Picker("推理档位", selection: Binding(
                get: { levels.contains(endpoint.effort) ? endpoint.effort : .automatic },
                set: { model.setEffort($0, for: endpoint.id) }
            )) {
                ForEach(levels) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(current == nil || current?.supportsReasoning == false)
        } footer: {
            Text(current?.supportsReasoning == false
                 ? "接口声明这个模型不支持推理档位。"
                 : "作为 reasoning_effort 发给接口。接口是否遵守取决于服务商。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func manualUse(_ endpoint: Endpoint) -> some View {
        Section {
            CopyRow(title: "Base URL", value: endpoint.baseURL) { model.copy(endpoint.baseURL, label: " Base URL") }
            if let selected = endpoint.selectedModel {
                CopyRow(title: "模型名", value: selected) { model.copy(selected, label: "模型名") }
            }
            if endpoint.hasKey {
                CopyRow(title: "API Key", value: "••••••••") {
                    if let key = model.readKey(endpoint.id) { model.copy(key, label: " API Key") }
                }
            }
        } header: {
            Text("用在其他工具里")
        } footer: {
            Text("Cline 等扩展：提供商选 OpenAI Compatible，再填入这几项。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProbeRow: View {
    let title: String
    let caption: String
    let status: ProbeStatus

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch status {
                case .ok:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .unknown:
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(status == .ok ? "通过" : status == .failed ? "未通过" : "未测试")
            Text(title)
            Spacer()
            Text(caption).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct CopyRow: View {
    let title: String
    let value: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: action) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("拷贝\(title)")
            .accessibilityLabel("拷贝\(title)")
        }
    }
}

// MARK: - 添加接口

private struct AddEndpointSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseURL = ""
    @State private var key = ""
    @State private var selectedPreset: String?
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case name, url, key }
    private static let customID = "custom"

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && Endpoint.isValid(baseURL: baseURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加接口").font(.title2.weight(.semibold))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Preset.all) { preset in
                    PresetChip(name: preset.name, isSelected: selectedPreset == preset.id) {
                        selectedPreset = preset.id
                        name = preset.name
                        baseURL = preset.baseURL
                        focus = preset.needsKey ? .key : .name
                    }
                }
                PresetChip(name: "自定义", symbol: "slider.horizontal.3", isSelected: selectedPreset == Self.customID) {
                    selectedPreset = Self.customID
                    name = ""
                    baseURL = ""
                    focus = .name
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("名称").gridColumnAlignment(.trailing)
                    TextField("名称", text: $name, prompt: Text("我的接口"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused($focus, equals: .name)
                }
                GridRow {
                    Text("Base URL")
                    TextField("Base URL", text: $baseURL, prompt: Text("https://api.example.com/v1"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .focused($focus, equals: .url)
                }
                GridRow {
                    Text("API Key")
                    SecureField("API Key", text: $key, prompt: Text("sk-…（本地接口可留空）"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                        .focused($focus, equals: .key)
                }
            }

            Text("密钥保存在系统钥匙串。添加后会自动拉取模型并测试连接。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加", action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func add() {
        do {
            let id = try model.addEndpoint(name: name, baseURL: baseURL, key: key)
            model.settingsPage = .endpoint(id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PresetChip: View {
    let name: String
    var symbol: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                } else {
                    EndpointGlyph(name: name, size: 26)
                }
                Text(name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(isHovering ? 0.08 : 0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 工具同步

private struct ToolsPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            ForEach(ToolID.allCases) { tool in
                ToolSection(model: model, tool: tool)
            }
            Section {
                Text("Key 保存在钥匙串。为了让工具在 ModelBar 退出后仍能读取，当前接口的 Key 会另存一份只有你的账户能读的文件（权限 0600），切换接口或停用全部工具时自动删除。工具的配置文件里只写这个文件的路径，不写 Key 本身。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("每次修改配置前都会自动备份")
                    Spacer()
                    Button("打开备份") { model.reveal(model.paths.backupsDirectory) }
                }
            } header: {
                Text("安全")
            }
        }
        .formStyle(.grouped)
        .modifier(CleanTopEdge())
        .onAppear { model.refreshStatuses() }
    }
}

private struct ToolSection: View {
    @Bindable var model: AppModel
    let tool: ToolID

    private var state: ToolState { model.status(of: tool) }

    var body: some View {
        Section {
            HStack(spacing: 12) {
                ToolTile(tool: tool, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.title).font(.headline)
                    Text(tool.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(state.title)
                    .font(.callout)
                    .foregroundStyle(state.tint)
                if state != .notInstalled {
                    Toggle(tool.title, isOn: Binding(
                        get: { model.isEnabled(tool) },
                        set: { model.setTool(tool, enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
            if let detail = state.detail {
                Text(detail).font(.callout).foregroundStyle(state.tint)
            }
            if state == .stale {
                HStack {
                    Text("配置文件被手动改过，和 ModelBar 的设置不一致。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("重新同步") { model.resync() }
                }
            }
            notes
            if state == .notInstalled, let command = installCommand {
                LabeledContent("安装命令") {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(model.configPath(for: tool).path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("在访达中显示") { model.reveal(model.configPath(for: tool)) }
            }
        }
    }

    private var installCommand: String? {
        switch tool {
        case .opencode: "curl -fsSL https://opencode.ai/install | bash"
        case .codex: "npm install -g @openai/codex"
        case .kilo: nil
        }
    }

    @ViewBuilder
    private var notes: some View {
        switch tool {
        case .opencode:
            Text("切换时如果后台服务正在运行，会自动重启让新配置生效，进行中的会话可能被打断。")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .codex:
            Text("Codex 只支持 Responses API。接口不支持时不会写入配置，也不会影响你现有的设置。")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .kilo:
            VStack(alignment: .leading, spacing: 6) {
                Text("在 Cursor 或 VS Code 的侧边栏使用，有自己的对话面板。切换后如未生效，请重载编辑器窗口。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !model.kiloExtensionInstalled, model.cursorInstalled {
                    Button(model.installingKilo ? "正在安装…" : "安装到 Cursor") {
                        model.installKiloIntoCursor()
                    }
                    .disabled(model.installingKilo)
                }
            }
        }
    }
}

// MARK: - 通用

private struct GeneralPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("开机时自动启动", isOn: $model.launchesAtLogin)
                Toggle("在菜单栏显示模型名", isOn: $model.showModelInMenuBar)
            }
            Section("数据") {
                HStack {
                    Text("设置和备份")
                    Spacer()
                    Button("在访达中显示") { model.reveal(model.paths.support) }
                }
            }
            Section {
                Button("退出 ModelBar") { NSApp.terminate(nil) }
            } footer: {
                Text("退出后不占用任何后台资源，已同步的工具会继续按当前配置运行。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .modifier(CleanTopEdge())
    }
}

private struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("ModelBar").font(.title.weight(.semibold))
            Text("版本 \(version)").font(.callout).foregroundStyle(.secondary)
            Text("在菜单栏统一管理你的 API 接口，一键同步到官方支持自定义接口的工具。\n不修改 Cursor 或任何工具的程序文件，只写它们公开的配置文件。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
