import Foundation

public struct AppState: Codable, Equatable, Sendable {
    public var endpoints: [Endpoint] = []
    public var activeEndpointID: UUID?
    public var enabledTools: [ToolID] = []
    public var originals: [ToolID: [String: String]] = [:]
    public var showModelInMenuBar = false

    public init() {}

    public var activeEndpoint: Endpoint? {
        endpoints.first { $0.id == activeEndpointID }
    }

    private enum CodingKeys: String, CodingKey {
        case endpoints, activeEndpointID, enabledTools, originals, showModelInMenuBar
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoints = try container.decodeIfPresent([Endpoint].self, forKey: .endpoints) ?? []
        activeEndpointID = try container.decodeIfPresent(UUID.self, forKey: .activeEndpointID)
        enabledTools = try container.decodeIfPresent([ToolID].self, forKey: .enabledTools) ?? []
        originals = try container.decodeIfPresent([ToolID: [String: String]].self, forKey: .originals) ?? [:]
        showModelInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showModelInMenuBar) ?? false
    }
}

public struct StateStore: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func load() throws -> AppState {
        guard FileManager.default.fileExists(atPath: file.path) else { return AppState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppState.self, from: Data(contentsOf: file))
    }

    /// 读不了的文件先改名留存，防止之后保存时把它覆盖掉。
    @discardableResult
    public func quarantine(now: Date = Date()) -> URL? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let target = file.deletingLastPathComponent()
            .appending(path: "state-unreadable-\(Int(now.timeIntervalSince1970)).json")
        return (try? FileManager.default.moveItem(at: file, to: target)) == nil ? nil : target
    }

    public func save(_ state: AppState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileSupport.writePrivate(try encoder.encode(state), to: file)
    }
}

public enum ToolState: Equatable, Sendable {
    case notInstalled
    case disabled
    case noSelection
    case synced
    case stale
    case incompatible(String)
    case failed(String)

    public var title: String {
        switch self {
        case .notInstalled: "未安装"
        case .disabled: "未启用"
        case .noSelection: "请先选择模型"
        case .synced: "已同步"
        case .stale: "配置被改动过"
        case .incompatible: "接口不兼容"
        case .failed: "同步失败"
        }
    }

    public var detail: String? {
        switch self {
        case .incompatible(let message), .failed(let message): message
        default: nil
        }
    }
}

public struct SyncReport: Sendable {
    public var statuses: [ToolID: ToolState] = [:]
    public var originals: [ToolID: [String: String]] = [:]
    public var removedOriginals: [ToolID] = []
    public var notes: [String] = []

    public init() {}
}

/// 所有配置写入都经过这里，保证不会有两次同步同时改同一个文件。
public actor SyncEngine {
    private let paths: AppPaths
    private let keyStore: any KeyStore
    private let adapters: [any ToolAdapter]
    private let backups: BackupStore

    public init(paths: AppPaths, keyStore: any KeyStore, adapters: [any ToolAdapter] = ToolCatalog.adapters) {
        self.paths = paths
        self.keyStore = keyStore
        self.adapters = adapters
        backups = BackupStore(directory: paths.backupsDirectory)
    }

    /// 把当前接口写入所有已启用的工具。
    public func sync(_ state: AppState) -> SyncReport {
        var report = SyncReport()
        let enabled = adapters.filter { state.enabledTools.contains($0.id) }

        guard !enabled.isEmpty else {
            removeKeyFiles(except: nil)
            report.statuses = currentStatuses(state)
            return report
        }
        guard let context = makeContext(state, report: &report) else {
            if report.statuses.isEmpty {
                for adapter in enabled { report.statuses[adapter.id] = .noSelection }
            }
            merge(currentStatuses(state), into: &report)
            return report
        }

        var someToolKeepsOldEndpoint = false
        for adapter in enabled {
            if !adapter.isInstalled(paths: paths) {
                report.statuses[adapter.id] = .notInstalled
                continue
            }
            if let reason = adapter.incompatibility(with: context.endpoint) {
                report.statuses[adapter.id] = .incompatible(reason)
                someToolKeepsOldEndpoint = true
                continue
            }
            do {
                if adapter.isApplied(context) {
                    report.statuses[adapter.id] = .synced
                    continue
                }
                if let originals = try adapter.apply(context) {
                    report.originals[adapter.id] = originals
                }
                report.statuses[adapter.id] = .synced
                if let note = adapter.reload(paths: paths) { report.notes.append(note) }
            } catch {
                report.statuses[adapter.id] = .failed(error.localizedDescription)
                someToolKeepsOldEndpoint = true
            }
        }
        // 没写入成功的工具还指向上一个接口，它的 Key 文件要留着。
        if !someToolKeepsOldEndpoint { removeKeyFiles(except: context.keyFile) }
        merge(currentStatuses(state), into: &report)
        return report
    }

    /// 停用工具并还原它原来的配置。
    public func disable(_ tool: ToolID, state: AppState) -> SyncReport {
        var report = SyncReport()
        guard let adapter = adapters.first(where: { $0.id == tool }) else { return report }
        do {
            try adapter.restore(paths: paths, backups: backups, originals: state.originals[tool] ?? [:])
            report.removedOriginals = [tool]
            report.statuses[tool] = adapter.isInstalled(paths: paths) ? .disabled : .notInstalled
            if let note = adapter.reload(paths: paths) { report.notes.append(note) }
        } catch {
            report.statuses[tool] = .failed(error.localizedDescription)
        }
        return report
    }

    public func currentStatuses(_ state: AppState) -> [ToolID: ToolState] {
        var result: [ToolID: ToolState] = [:]
        let context = makeReadOnlyContext(state)
        for adapter in adapters {
            guard adapter.isInstalled(paths: paths) else {
                result[adapter.id] = .notInstalled
                continue
            }
            guard state.enabledTools.contains(adapter.id) else {
                result[adapter.id] = .disabled
                continue
            }
            guard let context else {
                result[adapter.id] = .noSelection
                continue
            }
            if let reason = adapter.incompatibility(with: context.endpoint) {
                result[adapter.id] = .incompatible(reason)
            } else {
                result[adapter.id] = adapter.isApplied(context) ? .synced : .stale
            }
        }
        return result
    }

    public func removeAllKeyFiles() {
        removeKeyFiles(except: nil)
    }

    private func merge(_ statuses: [ToolID: ToolState], into report: inout SyncReport) {
        for (tool, status) in statuses where report.statuses[tool] == nil {
            report.statuses[tool] = status
        }
    }

    private func makeReadOnlyContext(_ state: AppState) -> SyncContext? {
        guard let endpoint = state.activeEndpoint, let model = endpoint.currentModel else { return nil }
        return SyncContext(endpoint: endpoint, model: model, keyFile: nil, paths: paths, backups: backups)
    }

    private func makeContext(_ state: AppState, report: inout SyncReport) -> SyncContext? {
        guard let endpoint = state.activeEndpoint, let model = endpoint.currentModel else { return nil }
        do {
            let key = try keyStore.key(for: endpoint.id)
            var keyFile: URL?
            if let key, !key.isEmpty {
                let file = paths.keyFile(for: endpoint.id)
                try FileSupport.writePrivate(Data(key.utf8), to: file)
                keyFile = file
            }
            return SyncContext(endpoint: endpoint, model: model, keyFile: keyFile, paths: paths, backups: backups)
        } catch {
            for tool in state.enabledTools {
                report.statuses[tool] = .failed(error.localizedDescription)
            }
            return nil
        }
    }

    private func removeKeyFiles(except keep: URL?) {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.keysDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "key" && file.lastPathComponent != keep?.lastPathComponent {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
