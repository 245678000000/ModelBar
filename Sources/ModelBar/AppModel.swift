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
    private(set) var availableUpdate: AppUpdate?
    private(set) var isCheckingForUpdates = false
    private(set) var isInstallingUpdate = false
    private(set) var updateMessage: String?

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
    @ObservationIgnored private var updateTask: Task<Void, Never>?

    init(paths: AppPaths) {
        self.paths = paths
        keyStore = paths.isSandboxed
            ? SandboxFileKeyStore(directory: paths.support.appending(path: "sandbox-keys", directoryHint: .isDirectory))
            : KeychainStore()
        let gateway = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "ModelBarGateway")
        engine = SyncEngine(paths: paths, keyStore: keyStore, bridge: BridgeManager(paths: paths, executable: gateway))
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
        // 应用更新后转换服务可能还是旧版本，同步时会自动重启它。
        if state.needsBridge {
            syncNow()
        } else {
            refreshStatuses()
        }
        startUpdateChecks()
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
            // 旧版本的测试结果里没有 Anthropic 这一项，打开 Claude Code 时要补测。
            if tool == .claudeCode, let active = activeEndpoint, active.probe?.messages == .unknown {
                persist()
                test(active.id)
            } else {
                syncNow()
            }
        } else {
            state.enabledTools.removeAll { $0 == tool }
            persist()
            Task { await disable(tool) }
        }
    }

    func resync() {
        syncNow()
    }

    // MARK: 本机转换

    /// 这个工具用不了当前接口的原生协议，用户还没开启转换，可以提示开启。
    func canOfferBridge(for tool: ToolID) -> Bool {
        !state.bridgeEnabled && isEnabled(tool) && tool.needsConversion(activeEndpoint?.probe)
    }

    var canOfferBridge: Bool {
        !state.bridgeEnabled && !state.toolsNeedingConversion.isEmpty
    }

    func isBridged(_ tool: ToolID) -> Bool {
        state.bridgeEnabled && isEnabled(tool) && tool.needsConversion(activeEndpoint?.probe)
    }

    var isBridgeActive: Bool { state.needsBridge }

    var hiddenToolCount: Int {
        ToolID.allCases.filter { status(of: $0) == .notInstalled && !isEnabled($0) }.count
    }

    func setBridge(enabled: Bool) {
        guard state.bridgeEnabled != enabled else { return }
        let bridged = state.toolsNeedingConversion
        state.bridgeEnabled = enabled
        if enabled {
            syncNow()
        } else {
            persist()
            // 这些工具可能正连着转换服务，要先恢复它们原来的配置。
            Task {
                for tool in bridged { await disable(tool) }
            }
        }
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
            // 删掉旧的副本，下次同步时写入新 Key。
            try? FileManager.default.removeItem(at: paths.keyFile(for: id))
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

    // MARK: 更新

    var checksForUpdates: Bool {
        get { state.checksForUpdates }
        set {
            state.checksForUpdates = newValue
            persist()
        }
    }

    private var currentVersion: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    /// 开发时直接运行的程序不在应用包里，没有东西可以替换。
    var canUpdate: Bool {
        currentVersion != nil && Bundle.main.bundleURL.pathExtension == "app" && UpdateFeed.url(paths: paths) != nil
    }

    private var updateInstaller: UpdateInstaller? {
        guard canUpdate, let identifier = Bundle.main.bundleIdentifier else { return nil }
        return UpdateInstaller(
            appBundle: Bundle.main.bundleURL,
            bundleIdentifier: identifier,
            workDirectory: paths.updatesDirectory,
            transport: URLSessionUpdateTransport(),
            verifier: SigningVerifier()
        )
    }

    private func startUpdateChecks() {
        guard canUpdate else { return }
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.runScheduledUpdateCheck()
            // 重启脚本可能还要用旧版回退，等它结束后再清理。正在安装时不清理，下次启动再说。
            try? await Task.sleep(for: .seconds(60))
            if self?.isInstallingUpdate == false { self?.updateInstaller?.removeLeftovers() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
                await self?.runScheduledUpdateCheck()
            }
        }
    }

    private func runScheduledUpdateCheck() async {
        if state.checksForUpdates { await performUpdateCheck(manual: false) }
    }

    func checkForUpdates() {
        Task { await performUpdateCheck(manual: true) }
    }

    /// 自动检查失败时不打扰用户，下次再试。
    private func performUpdateCheck(manual: Bool) async {
        guard let current = currentVersion, let feed = UpdateFeed.url(paths: paths),
              !isCheckingForUpdates, !isInstallingUpdate else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        do {
            let checker = UpdateChecker(feedURL: feed, allowsAnyHost: paths.isSandboxed, transport: URLSessionUpdateTransport())
            availableUpdate = try await checker.latest(newerThan: current)
            updateMessage = manual && availableUpdate == nil ? "已是最新版本" : nil
        } catch {
            if manual { updateMessage = "检查更新失败：\(error.localizedDescription)" }
        }
    }

    func installUpdate() {
        guard let update = availableUpdate, let installer = updateInstaller, !isInstallingUpdate else { return }
        isInstallingUpdate = true
        updateMessage = nil
        Task {
            do {
                try await installer.install(update) { [weak self] in
                    try await self?.waitForSyncToFinish()
                }
                NSApp.terminate(nil)
                // 设置窗口里开着表单时系统会拒绝退出，这时新版已经换好，不能停在这里。
                exit(0)
            } catch {
                isInstallingUpdate = false
                updateMessage = "更新失败：\(error.localizedDescription)"
                show(.error, "更新失败，旧版本没有变化：\(error.localizedDescription)")
            }
        }
    }

    /// 退出会打断正在写工具配置的同步，所以等它结束后才替换。等不到就放弃，旧版不变。
    private func waitForSyncToFinish() async throws {
        for _ in 0..<600 {
            if !isSyncing { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw UpdateError("工具配置还在同步，请稍后再试")
    }

    func openUpdatePage() {
        if let url = availableUpdate?.pageURL { NSWorkspace.shared.open(url) }
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
