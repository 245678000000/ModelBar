import AppKit
import Foundation
import Observation
import ServiceManagement
import ModelBarCore

enum SettingsPage: Hashable {
    case endpoint(UUID)
    case tools
    case general
    case about
}

struct Notice: Equatable {
    enum Kind { case info, error }
    var kind: Kind
    var text: String
}

@MainActor
@Observable
final class AppModel {
    private(set) var state: AppState
    private(set) var statuses: [ToolID: ToolState] = [:]
    private(set) var isSyncing = false
    private(set) var testing: Set<UUID> = []
    private(set) var loadingModels: Set<UUID> = []
    private(set) var notice: Notice?
    private(set) var installingKilo = false

    var settingsPage: SettingsPage? = nil
    var isAddingEndpoint = false

    /// 状态变化时通知菜单栏图标刷新。
    @ObservationIgnored var onChange: (() -> Void)?

    let paths: AppPaths
    @ObservationIgnored private let keyStore: any KeyStore
    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private let client = EndpointClient()
    @ObservationIgnored private var syncGeneration = 0
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(paths: AppPaths) {
        self.paths = paths
        keyStore = paths.isSandboxed
            ? SandboxFileKeyStore(directory: paths.support.appending(path: "sandbox-keys", directoryHint: .isDirectory))
            : KeychainStore()
        engine = SyncEngine(paths: paths, keyStore: keyStore)
        store = StateStore(file: paths.stateFile)
        do {
            state = try store.load()
        } catch {
            state = AppState()
            let kept = store.quarantine()
            notice = Notice(kind: .error, text: "无法读取保存的设置，原文件已另存为 \(kept?.lastPathComponent ?? "（另存失败）")")
        }
    }

    func start() {
        refreshStatuses()
        onChange?()
    }

    // MARK: 查询

    var activeEndpoint: Endpoint? { state.activeEndpoint }

    func endpoint(_ id: UUID) -> Endpoint? {
        state.endpoints.first { $0.id == id }
    }

    func status(of tool: ToolID) -> ToolState {
        statuses[tool] ?? .disabled
    }

    func isEnabled(_ tool: ToolID) -> Bool {
        state.enabledTools.contains(tool)
    }

    func configPath(for tool: ToolID) -> URL {
        ToolCatalog.adapter(for: tool).configFile(paths: paths)
    }

    var kiloExtensionInstalled: Bool { KiloExtension.isInstalled(paths: paths) }

    var cursorInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: KiloExtension.cursorCLI.path)
    }

    // MARK: 切换

    func activate(_ id: UUID) {
        guard state.activeEndpointID != id else { return }
        state.activeEndpointID = id
        // 没测试过的接口先确认协议，避免把不兼容的配置写给工具。
        if let endpoint = endpoint(id), endpoint.models.isEmpty || endpoint.probe == nil {
            persist()
            test(id)
        } else {
            syncNow()
        }
    }

    func selectModel(_ modelID: String, for endpointID: UUID) {
        mutate(endpointID) { endpoint in
            endpoint.selectedModel = modelID
            if let current = endpoint.currentModel, !current.availableEfforts.contains(endpoint.effort) {
                endpoint.effort = .automatic
            }
        }
        syncIfActive(endpointID)
    }

    func addManualModel(_ raw: String, for endpointID: UUID) {
        let modelID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return }
        mutate(endpointID) { endpoint in
            if !endpoint.models.contains(where: { $0.id == modelID }) {
                endpoint.models.insert(ModelInfo(id: modelID), at: 0)
            }
            endpoint.selectedModel = modelID
        }
        syncIfActive(endpointID)
    }

    func setEffort(_ effort: ReasoningEffort, for endpointID: UUID) {
        mutate(endpointID) { $0.effort = effort }
        syncIfActive(endpointID)
    }

    func setTool(_ tool: ToolID, enabled: Bool) {
        if enabled {
            guard !state.enabledTools.contains(tool) else { return }
            state.enabledTools.append(tool)
            syncNow()
        } else {
            state.enabledTools.removeAll { $0 == tool }
            persist()
            Task { await disable(tool) }
        }
    }

    func resync() {
        syncNow()
    }

    // MARK: 接口管理

    @discardableResult
    func addEndpoint(name: String, baseURL: String, key: String) throws -> UUID {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var endpoint = Endpoint(name: name.trimmingCharacters(in: .whitespacesAndNewlines), baseURL: baseURL)
        if !trimmed.isEmpty {
            try keyStore.setKey(trimmed, for: endpoint.id)
            endpoint.hasKey = true
        }
        state.endpoints.append(endpoint)
        if state.activeEndpointID == nil { state.activeEndpointID = endpoint.id }
        persist()
        test(endpoint.id)
        return endpoint.id
    }

    /// `key` 为 nil 表示不修改已保存的密钥。
    func updateEndpoint(_ id: UUID, name: String, baseURL: String, key: String?) throws {
        guard let current = endpoint(id) else { return }
        let normalized = Endpoint.normalize(baseURL: baseURL)
        let urlChanged = normalized != current.baseURL
        if let key {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            try keyStore.setKey(trimmed, for: id)
            mutate(id) { $0.hasKey = !trimmed.isEmpty }
        }
        mutate(id) { endpoint in
            endpoint.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            endpoint.baseURL = normalized
        }
        if urlChanged || key != nil {
            mutate(id) { $0.probe = nil }
            test(id)
        } else {
            syncIfActive(id)
        }
    }

    func deleteEndpoint(_ id: UUID) {
        try? keyStore.setKey(nil, for: id)
        state.endpoints.removeAll { $0.id == id }
        if case .endpoint(id) = settingsPage {
            settingsPage = state.endpoints.first.map { .endpoint($0.id) } ?? .tools
        }
        guard state.activeEndpointID == id else {
            persist()
            return
        }
        state.activeEndpointID = state.endpoints.first?.id
        if state.activeEndpointID != nil {
            syncNow()
        } else {
            // 没有接口可用时把工具还原，避免它们继续指向已删除的接口。
            let tools = state.enabledTools
            state.enabledTools = []
            persist()
            Task {
                for tool in tools { await disable(tool) }
            }
        }
    }

    func readKey(_ id: UUID) -> String? {
        do {
            return try keyStore.key(for: id)
        } catch {
            show(.error, error.localizedDescription)
            return nil
        }
    }

    func test(_ id: UUID) {
        guard let endpoint = endpoint(id), !testing.contains(id) else { return }
        testing.insert(id)
        let key = readKey(id)
        let probeModel = endpoint.selectedModel
        let baseURL = endpoint.baseURL
        Task {
            let (result, models) = await client.probe(baseURL: baseURL, key: key, model: probeModel)
            var finalResult = result
            // 第一次还不知道模型时，模型列表拿到后补测一次协议。
            if probeModel == nil, result.chat == .unknown, let first = Endpoint.defaultModel(from: models) {
                let retried = await client.probe(baseURL: baseURL, key: key, model: first)
                finalResult = retried.0
            }
            testing.remove(id)
            mutate(id) { endpoint in
                endpoint.probe = finalResult
                if !models.isEmpty {
                    let manual = endpoint.models.filter { current in !models.contains { $0.id == current.id } && current.id == endpoint.selectedModel }
                    endpoint.models = manual + models
                }
                if endpoint.selectedModel == nil {
                    endpoint.selectedModel = Endpoint.defaultModel(from: endpoint.models)
                }
            }
            syncIfActive(id)
        }
    }

    func refreshModels(_ id: UUID) {
        guard let endpoint = endpoint(id), !loadingModels.contains(id) else { return }
        loadingModels.insert(id)
        let key = readKey(id)
        let baseURL = endpoint.baseURL
        Task {
            defer { loadingModels.remove(id) }
            do {
                let models = try await client.fetchModels(baseURL: baseURL, key: key)
                mutate(id) { endpoint in
                    let selected = endpoint.selectedModel
                    let kept = endpoint.models.filter { current in current.id == selected && !models.contains { $0.id == current.id } }
                    endpoint.models = kept + models
                    if endpoint.selectedModel == nil {
                        endpoint.selectedModel = Endpoint.defaultModel(from: endpoint.models)
                    }
                }
                syncIfActive(id)
            } catch {
                show(.error, error.localizedDescription)
            }
        }
    }

    // MARK: 工具

    func refreshStatuses() {
        let snapshot = state
        Task {
            let result = await engine.currentStatuses(snapshot)
            statuses = result
            onChange?()
        }
    }

    func installKiloIntoCursor() {
        guard !installingKilo else { return }
        installingKilo = true
        Task {
            do {
                try await Task.detached { try KiloExtension.installIntoCursor() }.value
                show(.info, "Kilo Code 已安装到 Cursor，重启 Cursor 后生效")
            } catch {
                show(.error, error.localizedDescription)
            }
            installingKilo = false
            refreshStatuses()
        }
    }

    func reveal(_ url: URL) {
        var target = url
        while !FileManager.default.fileExists(atPath: target.path), target.path != "/" {
            target.deleteLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(.info, "已拷贝\(label)")
    }

    // MARK: 通用

    var launchesAtLogin: Bool {
        get {
            access(keyPath: \.launchesAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchesAtLogin) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    show(.error, "无法修改开机启动：\(error.localizedDescription)")
                }
            }
        }
    }

    var showModelInMenuBar: Bool {
        get { state.showModelInMenuBar }
        set {
            state.showModelInMenuBar = newValue
            persist()
        }
    }

    // MARK: 内部

    private func mutate(_ id: UUID, _ change: (inout Endpoint) -> Void) {
        guard let index = state.endpoints.firstIndex(where: { $0.id == id }) else { return }
        change(&state.endpoints[index])
        persist()
    }

    private func syncIfActive(_ id: UUID) {
        if state.activeEndpointID == id {
            syncNow()
        } else {
            refreshStatuses()
        }
    }

    private func syncNow() {
        persist()
        syncGeneration += 1
        let generation = syncGeneration
        isSyncing = true
        let snapshot = state
        Task {
            let report = await engine.sync(snapshot)
            apply(report, generation: generation)
        }
    }

    private func disable(_ tool: ToolID) async {
        let report = await engine.disable(tool, state: state)
        syncGeneration += 1
        apply(report, generation: syncGeneration)
        let cleanup = await engine.sync(state)
        apply(cleanup, generation: syncGeneration)
    }

    private func apply(_ report: SyncReport, generation: Int) {
        for (tool, originals) in report.originals { state.originals[tool] = originals }
        for tool in report.removedOriginals { state.originals[tool] = nil }
        if !report.originals.isEmpty || !report.removedOriginals.isEmpty { persist() }

        guard generation == syncGeneration else { return }
        statuses.merge(report.statuses) { _, new in new }
        isSyncing = false
        if let failure = report.statuses.values.compactMap({ state -> String? in
            if case .failed(let message) = state { return message }
            return nil
        }).first {
            show(.error, failure)
        } else if let note = report.notes.first {
            show(.info, note)
        }
        onChange?()
    }

    private func persist() {
        do {
            try store.save(state)
        } catch {
            show(.error, "无法保存设置：\(error.localizedDescription)")
        }
        onChange?()
    }

    private func show(_ kind: Notice.Kind, _ text: String) {
        notice = Notice(kind: kind, text: text)
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(kind == .error ? 7 : 3))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }
}
