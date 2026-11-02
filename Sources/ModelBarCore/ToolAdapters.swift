import Foundation

public enum ManagedName {
    public static let provider = "modelbar"
}

public struct SyncContext: Sendable {
    public var endpoint: Endpoint
    public var model: ModelInfo
    public var keyFile: URL?
    public var paths: AppPaths
    public var backups: BackupStore
    /// 有值时，Codex 改连本机转换服务，而不是直接连接口。
    public var bridge: BridgeTarget?

    public init(
        endpoint: Endpoint,
        model: ModelInfo,
        keyFile: URL?,
        paths: AppPaths,
        backups: BackupStore,
        bridge: BridgeTarget? = nil
    ) {
        self.endpoint = endpoint
        self.model = model
        self.keyFile = keyFile
        self.paths = paths
        self.backups = backups
        self.bridge = bridge
    }
}

public struct ConfigError: LocalizedError {
    public var errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public protocol ToolAdapter: Sendable {
    var id: ToolID { get }
    func isInstalled(paths: AppPaths) -> Bool
    func configFile(paths: AppPaths) -> URL
    func incompatibility(with endpoint: Endpoint, bridgeEnabled: Bool) -> String?
    /// 写入配置。文件尚未被接管时返回需要保存的原值，否则返回 nil。
    func apply(_ context: SyncContext) throws -> [String: String]?
    func restore(paths: AppPaths, backups: BackupStore, originals: [String: String]) throws
    func isApplied(_ context: SyncContext) -> Bool
    /// 让正在运行的进程读到新配置，返回需要告诉用户的说明。
    func reload(paths: AppPaths) -> String?
}

extension ToolAdapter {
    public func reload(paths: AppPaths) -> String? { nil }

    public func incompatibility(with endpoint: Endpoint) -> String? {
        incompatibility(with: endpoint, bridgeEnabled: false)
    }
}

// MARK: - opencode / Kilo

/// opencode 和 Kilo 共用同一种配置结构，只是目录和文件名不同。
public struct OpenCodeFamilyAdapter: ToolAdapter {
    public let id: ToolID
    private let directory: @Sendable (AppPaths) -> URL
    private let baseName: String
    private let installed: @Sendable (AppPaths) -> Bool
    private let reloader: (@Sendable (AppPaths) -> String?)?

    private static let modelKey = "model"
    private static let maxModels = 300
    private static let defaultContext = 128_000
    private static let defaultOutput = 8_192

    public init(
        id: ToolID,
        baseName: String,
        directory: @escaping @Sendable (AppPaths) -> URL,
        installed: @escaping @Sendable (AppPaths) -> Bool,
        reloader: (@Sendable (AppPaths) -> String?)? = nil
    ) {
        self.id = id
        self.baseName = baseName
        self.directory = directory
        self.installed = installed
        self.reloader = reloader
    }

    public func isInstalled(paths: AppPaths) -> Bool { installed(paths) }

    public func configFile(paths: AppPaths) -> URL {
        paths.jsonConfig(in: directory(paths), baseName: baseName)
    }

    public func incompatibility(with endpoint: Endpoint, bridgeEnabled: Bool) -> String? {
        if endpoint.probe?.chat == .failed, endpoint.probe?.responses == .failed {
            return "这个接口没有通过 Chat 和 Responses 测试"
        }
        return nil
    }

    public func apply(_ context: SyncContext) throws -> [String: String]? {
        let file = configFile(paths: context.paths)
        var root = try load(file)

        let current = root[Self.modelKey] as? String
        var originals: [String: String]?
        if !isManaged(current) {
            originals = current.map { [Self.modelKey: $0] } ?? [:]
        }

        var providers = root["provider"] as? [String: Any] ?? [:]
        providers[ManagedName.provider] = providerBlock(context)
        root["provider"] = providers
        root[Self.modelKey] = "\(ManagedName.provider)/\(context.model.id)"

        try save(root, to: file, backups: context.backups)
        return originals
    }

    public func restore(paths: AppPaths, backups: BackupStore, originals: [String: String]) throws {
        let file = configFile(paths: paths)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var root = try load(file)
        guard var providers = root["provider"] as? [String: Any] else {
            if isManaged(root[Self.modelKey] as? String) { root[Self.modelKey] = originals[Self.modelKey] }
            try save(root, to: file, backups: backups)
            return
        }
        providers[ManagedName.provider] = nil
        root["provider"] = providers.isEmpty ? nil : providers
        if isManaged(root[Self.modelKey] as? String) {
            root[Self.modelKey] = originals[Self.modelKey]
        }
        try save(root, to: file, backups: backups)
    }

    public func isApplied(_ context: SyncContext) -> Bool {
        guard let root = try? load(configFile(paths: context.paths)),
              root[Self.modelKey] as? String == "\(ManagedName.provider)/\(context.model.id)",
              let provider = (root["provider"] as? [String: Any])?[ManagedName.provider] as? [String: Any],
              let options = provider["options"] as? [String: Any],
              options["baseURL"] as? String == context.endpoint.baseURL,
              let models = provider["models"] as? [String: Any],
              let model = models[context.model.id] as? [String: Any]
        else { return false }
        let effort = (model["options"] as? [String: Any])?["reasoningEffort"] as? String
        return effort == context.endpoint.effort.wireValue
    }

    public func reload(paths: AppPaths) -> String? { reloader?(paths) }

    private func isManaged(_ model: String?) -> Bool {
        model?.hasPrefix("\(ManagedName.provider)/") == true
    }

    private func providerBlock(_ context: SyncContext) -> [String: Any] {
        let endpoint = context.endpoint
        let apiKey = context.keyFile.map { "{file:\($0.path)}" } ?? "none"
        let usesResponses = endpoint.probe?.chat == .failed && endpoint.probe?.responses == .ok

        var catalog = Array(endpoint.models.prefix(Self.maxModels))
        if !catalog.contains(where: { $0.id == context.model.id }) { catalog.append(context.model) }

        var models: [String: Any] = [:]
        for model in catalog {
            let isSelected = model.id == context.model.id
            models[model.id] = modelBlock(model, effort: isSelected ? endpoint.effort : .automatic)
        }

        return [
            "npm": usesResponses ? "@ai-sdk/openai" : "@ai-sdk/openai-compatible",
            "name": "ModelBar · \(endpoint.name)",
            "options": ["baseURL": endpoint.baseURL, "apiKey": apiKey],
            "models": models,
        ]
    }

    private func modelBlock(_ model: ModelInfo, effort: ReasoningEffort) -> [String: Any] {
        var block: [String: Any] = [
            "name": model.id,
            "tool_call": true,
            "limit": [
                "context": model.contextLength ?? Self.defaultContext,
                "output": model.maxOutputTokens ?? Self.defaultOutput,
            ],
        ]
        if model.supportsReasoning != false {
            let levels = model.availableEfforts.compactMap(\.wireValue)
            block["variants"] = Dictionary(uniqueKeysWithValues: levels.map { ($0, ["reasoningEffort": $0]) })
        }
        if model.supportsReasoning == true || effort != .automatic {
            block["reasoning"] = true
        }
        if let value = effort.wireValue {
            block["options"] = ["reasoningEffort": value]
        }
        return block
    }

    private func load(_ file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return [:] }
        do {
            guard let root = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else {
                throw ConfigError("顶层不是对象")
            }
            return root
        } catch {
            throw ConfigError("\(file.lastPathComponent) 无法解析，未作任何修改")
        }
    }

    private func save(_ root: [String: Any], to file: URL, backups: BackupStore) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try backups.backup(file, label: id.rawValue)
        try FileSupport.writeAtomically(data + Data("\n".utf8), to: file)
    }
}

// MARK: - Codex CLI

public struct CodexAdapter: ToolAdapter {
    public let id: ToolID = .codex

    private static let table = "model_providers.\(ManagedName.provider)"
    private static let marker = "# Managed by ModelBar"
    private static let managedKeys = ["model", "model_provider", "model_reasoning_effort", "model_context_window"]

    public init() {}

    public func isInstalled(paths: AppPaths) -> Bool {
        paths.findBinary("codex") != nil || FileManager.default.fileExists(atPath: paths.codexDirectory.path)
    }

    public func configFile(paths: AppPaths) -> URL { paths.codexConfig }

    public func incompatibility(with endpoint: Endpoint, bridgeEnabled: Bool) -> String? {
        guard endpoint.probe?.responses == .failed else { return nil }
        if endpoint.probe?.chat == .failed { return "这个接口没有通过 Chat 和 Responses 测试，Codex 的配置保持不变" }
        return bridgeEnabled ? nil : "这个接口不支持 Responses API，Codex 的配置保持不变"
    }

    public func apply(_ context: SyncContext) throws -> [String: String]? {
        let file = configFile(paths: context.paths)
        var document = TOMLDocument(text: try readText(file))

        var originals: [String: String]?
        if document.string(forKey: "model_provider") != ManagedName.provider {
            var captured: [String: String] = [:]
            for key in Self.managedKeys {
                if let raw = document.rawValue(forKey: key) { captured[key] = raw }
            }
            originals = captured
        }

        let endpoint = context.endpoint
        document.setTopLevel("model", rawValue: TOMLDocument.quote(context.model.id))
        document.setTopLevel("model_provider", rawValue: TOMLDocument.quote(ManagedName.provider))
        document.setTopLevel("model_reasoning_effort", rawValue: endpoint.effort.wireValue.map(TOMLDocument.quote))
        document.setTopLevel("model_context_window", rawValue: context.model.contextLength.map(String.init))

        document.removeTable(Self.table, marker: Self.marker)
        let displayName = context.bridge == nil ? "ModelBar · \(endpoint.name)" : "ModelBar · \(endpoint.name)（本机转换）"
        var block = [
            Self.marker,
            "[\(Self.table)]",
            "name = \(TOMLDocument.quote(displayName))",
            "base_url = \(TOMLDocument.quote(context.bridge?.baseURL ?? endpoint.baseURL))",
            "wire_api = \"responses\"",
        ]
        if let credential = context.bridge?.tokenFile ?? context.keyFile {
            block += [
                "",
                "[\(Self.table).auth]",
                "command = \"/bin/cat\"",
                "args = [\(TOMLDocument.quote(credential.path))]",
            ]
        }
        document.appendBlock(block)

        try context.backups.backup(file, label: id.rawValue)
        try FileSupport.writeAtomically(Data(document.text.utf8), to: file)
        return originals
    }

    public func restore(paths: AppPaths, backups: BackupStore, originals: [String: String]) throws {
        let file = configFile(paths: paths)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var document = TOMLDocument(text: try readText(file))
        let isManaged = document.string(forKey: "model_provider") == ManagedName.provider
        if isManaged {
            for key in Self.managedKeys {
                document.setTopLevel(key, rawValue: originals[key])
            }
        }
        document.removeTable(Self.table, marker: Self.marker)
        try backups.backup(file, label: id.rawValue)
        try FileSupport.writeAtomically(Data(document.text.utf8), to: file)
    }

    public func isApplied(_ context: SyncContext) -> Bool {
        guard let text = try? readText(configFile(paths: context.paths)) else { return false }
        let document = TOMLDocument(text: text)
        return document.string(forKey: "model_provider") == ManagedName.provider
            && document.string(forKey: "model") == context.model.id
            && document.string(forKey: "base_url", inTable: Self.table) == (context.bridge?.baseURL ?? context.endpoint.baseURL)
            && document.string(forKey: "model_reasoning_effort") == context.endpoint.effort.wireValue
    }

    private func readText(_ file: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw ConfigError("\(file.lastPathComponent) 无法读取，未作任何修改")
        }
        return text
    }
}

// MARK: - 默认工具集

public enum ToolCatalog {
    public static let adapters: [any ToolAdapter] = [
        ClaudeCodeAdapter(),
        CodexAdapter(),
        OpenCodeFamilyAdapter(
            id: .opencode,
            baseName: "opencode",
            directory: { $0.opencodeDirectory },
            installed: { paths in
                paths.findBinary("opencode") != nil
                    || FileManager.default.fileExists(atPath: paths.opencodeDirectory.path)
            },
            reloader: { OpenCodeService.restartIfRunning(paths: $0) }
        ),
        PiAdapter(),
        GrokAdapter(),
        DroidAdapter(),
        OpenCodeFamilyAdapter(
            id: .kilo,
            baseName: "kilo",
            directory: { $0.kiloDirectory },
            installed: { paths in
                paths.findBinary("kilo") != nil
                    || FileManager.default.fileExists(atPath: paths.kiloDirectory.path)
                    || KiloExtension.isInstalled(paths: paths)
            }
        ),
    ]

    public static func adapter(for id: ToolID) -> any ToolAdapter {
        adapters.first { $0.id == id }!
    }
}

public enum KiloExtension {
    public static let identifier = "kilocode.Kilo-Code"
    public static let cursorCLI = URL(fileURLWithPath: "/Applications/Cursor.app/Contents/Resources/app/bin/cursor")

    public static func isInstalled(paths: AppPaths) -> Bool {
        paths.extensionRoots.contains { root in
            let items = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            return items.contains { $0.lowercased().hasPrefix("kilocode.kilo-code") }
        }
    }

    public static func installIntoCursor() throws {
        guard FileManager.default.isExecutableFile(atPath: cursorCLI.path) else {
            throw ConfigError("没有找到 Cursor")
        }
        let result = ProcessRunner.run(cursorCLI, arguments: ["--install-extension", identifier], timeout: 180)
        guard result.exitCode == 0 else {
            throw ConfigError("安装失败：\(result.output.suffix(200))")
        }
    }
}

public enum OpenCodeService {
    /// 运行中的后台服务不会重新读取配置，所以切换后需要重启它。
    public static func restartIfRunning(paths: AppPaths) -> String? {
        guard let binary = paths.findBinary("opencode") else { return nil }
        let environment = paths.isSandboxed ? sandboxEnvironment(paths) : nil
        let status = ProcessRunner.run(binary, arguments: ["service", "status"], environment: environment, timeout: 10)
        let running = status.exitCode == 0
            && status.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("http")
        guard running else { return nil }
        let restart = ProcessRunner.run(binary, arguments: ["service", "restart"], environment: environment, timeout: 20)
        return restart.exitCode == 0
            ? "已重启 opencode 后台服务"
            : "opencode 后台服务重启失败，请手动运行 opencode service restart"
    }

    private static func sandboxEnvironment(_ paths: AppPaths) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let root = paths.home
        environment["XDG_CONFIG_HOME"] = root.appending(path: ".config").path
        environment["XDG_DATA_HOME"] = root.appending(path: ".local/share").path
        environment["XDG_STATE_HOME"] = root.appending(path: ".local/state").path
        environment["XDG_CACHE_HOME"] = root.appending(path: ".cache").path
        return environment
    }
}

public enum ProcessRunner {
    public struct Result: Sendable {
        public var exitCode: Int32
        public var output: String
    }

    /// 输出写入临时文件而不是管道：被拉起的后台进程会继承输出端，用管道可能永远等不到结束。
    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) -> Result {
        let logURL = FileManager.default.temporaryDirectory.appending(path: "modelbar-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil),
              let log = try? FileHandle(forWritingTo: logURL) else {
            return Result(exitCode: -1, output: "无法创建临时文件")
        }
        defer {
            try? log.close()
            try? FileManager.default.removeItem(at: logURL)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return Result(exitCode: -1, output: error.localizedDescription)
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return Result(exitCode: -2, output: "执行超时")
        }
        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return Result(exitCode: process.terminationStatus, output: output)
    }
}
