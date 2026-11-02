import Foundation

/// 读写 JSON 配置：解析失败时绝不覆盖，写入前先备份。
enum JSONConfigFile {
    static func load(_ file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else {
            throw ConfigError("\(file.lastPathComponent) 无法解析，未作任何修改")
        }
        return root
    }

    static func save(_ root: [String: Any], to file: URL, backups: BackupStore, label: String) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try backups.backup(file, label: label)
        try FileSupport.writeAtomically(data + Data("\n".utf8), to: file)
    }
}

/// 让 shell 把路径当成一个整体，路径里可能有空格和单引号。
func shellQuoted(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Claude Code

/// 写 ~/.claude/settings.json 的 env 和 apiKeyHelper，VS Code 里的 Claude Code 扩展读的是同一份。
public struct ClaudeCodeAdapter: ToolAdapter {
    public let id: ToolID = .claudeCode

    private static let marker = "MODELBAR_MANAGED"
    private static let helperKey = "apiKeyHelper"
    private static let modelKeys = [
        "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_SUBAGENT_MODEL",
    ]
    /// 令牌类的环境变量优先级高于 apiKeyHelper，必须先移走。
    private static let managedEnvKeys = modelKeys + [
        "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_EFFORT_LEVEL",
    ]

    public init() {}

    public func isInstalled(paths: AppPaths) -> Bool { paths.findBinary("claude") != nil }

    public func configFile(paths: AppPaths) -> URL { paths.claudeSettings }

    public func incompatibility(with endpoint: Endpoint, bridgeEnabled: Bool) -> String? {
        guard let probe = endpoint.probe else { return nil }
        if probe.messages == .ok { return nil }
        if probe.chat == .failed { return "这个接口没有通过 Chat 和 Anthropic 测试，Claude Code 的配置保持不变" }
        if bridgeEnabled, probe.messages == .failed { return nil }
        if probe.messages == .unknown { return "还不确定这个接口是否支持 Anthropic 协议，请重新测试接口" }
        return "这个接口不支持 Anthropic 协议，Claude Code 的配置保持不变"
    }

    public func apply(_ context: SyncContext) throws -> [String: String]? {
        let file = configFile(paths: context.paths)
        var root = try JSONConfigFile.load(file)
        var env = root["env"] as? [String: Any] ?? [:]

        var originals: [String: String]?
        if env[Self.marker] == nil {
            var captured: [String: String] = [:]
            for key in Self.managedEnvKeys {
                if let value = env[key] as? String { captured["env.\(key)"] = value }
            }
            if let helper = root[Self.helperKey] as? String { captured[Self.helperKey] = helper }
            originals = captured
        }

        for key in Self.managedEnvKeys { env[key] = nil }
        env[Self.marker] = "1"
        env["ANTHROPIC_BASE_URL"] = Self.baseURL(for: context)
        for key in Self.modelKeys { env[key] = context.model.id }
        if let effort = context.endpoint.effort.wireValue { env["CLAUDE_CODE_EFFORT_LEVEL"] = effort }
        root["env"] = env

        if let credential = context.bridge?.tokenFile ?? context.keyFile {
            root[Self.helperKey] = "/bin/cat \(shellQuoted(credential.path))"
        } else {
            root[Self.helperKey] = nil
        }
        try JSONConfigFile.save(root, to: file, backups: context.backups, label: id.rawValue)
        return originals
    }

    public func restore(paths: AppPaths, backups: BackupStore, originals: [String: String]) throws {
        let file = configFile(paths: paths)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var root = try JSONConfigFile.load(file)
        guard var env = root["env"] as? [String: Any], env[Self.marker] != nil else { return }
        env[Self.marker] = nil
        for key in Self.managedEnvKeys { env[key] = originals["env.\(key)"] }
        root["env"] = env.isEmpty ? nil : env
        root[Self.helperKey] = originals[Self.helperKey]
        try JSONConfigFile.save(root, to: file, backups: backups, label: id.rawValue)
    }

    public func isApplied(_ context: SyncContext) -> Bool {
        guard let root = try? JSONConfigFile.load(configFile(paths: context.paths)),
              let env = root["env"] as? [String: Any],
              env[Self.marker] != nil else { return false }
        return env["ANTHROPIC_BASE_URL"] as? String == Self.baseURL(for: context)
            && env["ANTHROPIC_MODEL"] as? String == context.model.id
            && env["CLAUDE_CODE_EFFORT_LEVEL"] as? String == context.endpoint.effort.wireValue
    }

    /// Claude Code 自己会加 /v1/messages，所以地址里不能带 /v1。
    private static func baseURL(for context: SyncContext) -> String {
        var url = context.bridge?.baseURL ?? context.endpoint.baseURL
        if url.hasSuffix("/v1") { url.removeLast(3) }
        return url
    }
}

// MARK: - pi

/// 接口写进 models.json，默认模型写进 settings.json。
public struct PiAdapter: ToolAdapter {
    public let id: ToolID = .pi

    private static let settingKeys = ["defaultProvider", "defaultModel", "defaultThinkingLevel"]
    private static let enabledPrefix = "\(ManagedName.provider)/"

    public init() {}

    public func isInstalled(paths: AppPaths) -> Bool { paths.findBinary("pi") != nil }

    public func configFile(paths: AppPaths) -> URL { paths.piDirectory.appending(path: "models.json") }

    private func settingsFile(paths: AppPaths) -> URL { paths.piDirectory.appending(path: "settings.json") }

    public func incompatibility(with endpoint: Endpoint, bridgeEnabled: Bool) -> String? {
        if endpoint.probe?.chat == .failed, endpoint.probe?.responses == .failed {
            return "这个接口没有通过 Chat 和 Responses 测试"
        }
        return nil
    }

    public func apply(_ context: SyncContext) throws -> [String: String]? {
        let modelsURL = configFile(paths: context.paths)
        let settingsURL = settingsFile(paths: context.paths)
        var models = try JSONConfigFile.load(modelsURL)
        var settings = try JSONConfigFile.load(settingsURL)

        var originals: [String: String]?
        if settings["defaultProvider"] as? String != ManagedName.provider {
            var captured: [String: String] = [:]
            for key in Self.settingKeys {
                if let value = settings[key] as? String { captured[key] = value }
            }
            originals = captured
        }

        var providers = models["providers"] as? [String: Any] ?? [:]
        providers[ManagedName.provider] = providerBlock(context)
        models["providers"] = providers

        settings["defaultProvider"] = ManagedName.provider
        settings["defaultModel"] = context.model.id
        settings["defaultThinkingLevel"] = context.endpoint.effort.wireValue
        // 有 enabledModels 白名单时，不在名单里的默认模型会被跳过。
        if var enabled = settings["enabledModels"] as? [String] {
            enabled.removeAll { $0.hasPrefix(Self.enabledPrefix) }
            enabled.insert(Self.enabledPrefix + context.model.id, at: 0)
            settings["enabledModels"] = enabled
        }

        try JSONConfigFile.save(models, to: modelsURL, backups: context.backups, label: "pi-models")
        try JSONConfigFile.save(settings, to: settingsURL, backups: context.backups, label: "pi-settings")
        return originals
    }

    public func restore(paths: AppPaths, backups: BackupStore, originals: [String: String]) throws {
        let modelsURL = configFile(paths: paths)
        if FileManager.default.fileExists(atPath: modelsURL.path) {
            var models = try JSONConfigFile.load(modelsURL)
            if var providers = models["providers"] as? [String: Any], providers[ManagedName.provider] != nil {
                providers[ManagedName.provider] = nil
                models["providers"] = providers.isEmpty ? nil : providers
                try JSONConfigFile.save(models, to: modelsURL, backups: backups, label: "pi-models")
            }
        }
        let settingsURL = settingsFile(paths: paths)
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        var settings = try JSONConfigFile.load(settingsURL)
        if var enabled = settings["enabledModels"] as? [String], enabled.contains(where: { $0.hasPrefix(Self.enabledPrefix) }) {
            enabled.removeAll { $0.hasPrefix(Self.enabledPrefix) }
            settings["enabledModels"] = enabled
        }
        if settings["defaultProvider"] as? String == ManagedName.provider {
            for key in Self.settingKeys { settings[key] = originals[key] }
        }
        try JSONConfigFile.save(settings, to: settingsURL, backups: backups, label: "pi-settings")
    }

    public func isApplied(_ context: SyncContext) -> Bool {
        guard let settings = try? JSONConfigFile.load(settingsFile(paths: context.paths)),
              let models = try? JSONConfigFile.load(configFile(paths: context.paths)),
              settings["defaultProvider"] as? String == ManagedName.provider,
              settings["defaultModel"] as? String == context.model.id,
              settings["defaultThinkingLevel"] as? String == context.endpoint.effort.wireValue,
              (settings["enabledModels"] as? [String])?.contains(Self.enabledPrefix + context.model.id) != false,
              let provider = (models["providers"] as? [String: Any])?[ManagedName.provider] as? [String: Any]
        else { return false }
        return provider["baseUrl"] as? String == context.endpoint.baseURL
    }

    private func providerBlock(_ context: SyncContext) -> [String: Any] {
        let endpoint = context.endpoint
        var catalog = Array(endpoint.models.prefix(300))
        if !catalog.contains(where: { $0.id == context.model.id }) { catalog.append(context.model) }
        let usesResponses = endpoint.probe?.chat == .failed && endpoint.probe?.responses == .ok
        return [
            "name": "ModelBar · \(endpoint.name)",
            "api": usesResponses ? "openai-responses" : "openai-completions",
            "baseUrl": endpoint.baseURL,
            // 以 ! 开头时，pi 运行这条命令并用它的输出作为 Key。
            "apiKey": context.keyFile.map { "!/bin/cat \(shellQuoted($0.path))" } ?? "none",
            "models": catalog.map { model -> [String: Any] in
                [
                    "id": model.id,
                    "name": model.id,
                    "input": ["text"],
                    "reasoning": model.supportsReasoning != false,
                    "contextWindow": model.contextLength ?? 128_000,
                    "maxTokens": model.maxOutputTokens ?? 8_192,
                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                ]
            },
        ]
    }
}

// MARK: - Grok

public struct GrokAdapter: ToolAdapter {
    public let id: ToolID = .grok

    private static let modelTable = "model.\(ManagedName.provider)"
    private static let authTable = "auth_provider.\(ManagedName.provider)"
    private static let marker = "# Managed by ModelBar"

    public init() {}

    public func isInstalled(paths: AppPaths) -> Bool { paths.findBinary("grok") != nil }

    public func configFile(paths: AppPaths) -> URL { paths.grokConfig }

    public func incompatibility(with endpoint: Endpoint, bridgeEnabled: Bool) -> String? {
        endpoint.probe?.chat == .failed ? "这个接口没有通过 Chat 测试，Grok 的配置保持不变" : nil
    }

    public func apply(_ context: SyncContext) throws -> [String: String]? {
        let file = configFile(paths: context.paths)
        var document = TOMLDocument(text: try readText(file))

        var originals: [String: String]?
        if document.string(forKey: "default", inTable: "models") != ManagedName.provider {
            originals = document.rawValue(forKey: "default", inTable: "models").map { ["default": $0] } ?? [:]
        }

        document.set("default", rawValue: TOMLDocument.quote(ManagedName.provider), inTable: "models")
        removeManagedTables(&document)

        let endpoint = context.endpoint
        var block = [
            Self.marker,
            "[\(Self.modelTable)]",
            "model = \(TOMLDocument.quote(context.model.id))",
            "base_url = \(TOMLDocument.quote(endpoint.baseURL))",
            "name = \(TOMLDocument.quote("ModelBar · \(endpoint.name)"))",
        ]
        if let length = context.model.contextLength { block.append("context_window = \(length)") }
        if let keyFile = context.keyFile {
            block += [
                "auth_provider = \(TOMLDocument.quote(ManagedName.provider))",
                "",
                Self.marker,
                "[\(Self.authTable)]",
                "command = \(TOMLDocument.quote("/bin/cat \(shellQuoted(keyFile.path))"))",
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
        // 先删自己的表：它们前面的注释会让 [models] 看起来不是空表。
        removeManagedTables(&document)
        if document.string(forKey: "default", inTable: "models") == ManagedName.provider {
            document.set("default", rawValue: originals["default"], inTable: "models")
        }
        try backups.backup(file, label: id.rawValue)
        try FileSupport.writeAtomically(Data(document.text.utf8), to: file)
    }

    public func isApplied(_ context: SyncContext) -> Bool {
        guard let text = try? readText(configFile(paths: context.paths)) else { return false }
        let document = TOMLDocument(text: text)
        return document.string(forKey: "default", inTable: "models") == ManagedName.provider
            && document.string(forKey: "model", inTable: Self.modelTable) == context.model.id
            && document.string(forKey: "base_url", inTable: Self.modelTable) == context.endpoint.baseURL
    }

    private func removeManagedTables(_ document: inout TOMLDocument) {
        document.removeTable(Self.modelTable, marker: Self.marker)
        document.removeTable(Self.authTable, marker: Self.marker)
    }

    private func readText(_ file: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw ConfigError("\(file.lastPathComponent) 无法读取，未作任何修改")
        }
        return text
    }
}

// MARK: - Factory Droid

/// Droid 的自定义模型只接受明文 Key，所以 Key 会写进它的配置文件。
public struct DroidAdapter: ToolAdapter {
    public let id: ToolID = .droid

    private static let displayName = "ModelBar"
    private static let defaultKeys = ["model", "reasoningEffort"]

    public init() {}

    public func isInstalled(paths: AppPaths) -> Bool { paths.findBinary("droid") != nil }

    public func configFile(paths: AppPaths) -> URL { paths.droidSettings }

    public func incompatibility(with endpoint: Endpoint, bridgeEnabled: Bool) -> String? {
        if endpoint.probe?.chat == .failed, endpoint.probe?.responses == .failed {
            return "这个接口没有通过 Chat 和 Responses 测试"
        }
        return nil
    }

    public func apply(_ context: SyncContext) throws -> [String: String]? {
        let file = configFile(paths: context.paths)
        var root = try JSONConfigFile.load(file)
        var defaults = root["sessionDefaultSettings"] as? [String: Any] ?? [:]

        var originals: [String: String]?
        if (defaults["model"] as? String)?.hasPrefix("custom:\(Self.displayName)-") != true {
            var captured: [String: String] = [:]
            for key in Self.defaultKeys {
                if let value = defaults[key] as? String { captured[key] = value }
            }
            originals = captured
        }

        var models = (root["customModels"] as? [[String: Any]] ?? []).filter { $0["displayName"] as? String != Self.displayName }
        var entry: [String: Any] = [
            "model": context.model.id,
            "displayName": Self.displayName,
            "baseUrl": context.endpoint.baseURL,
            "apiKey": try context.keyFile.map { try String(contentsOf: $0, encoding: .utf8) } ?? "none",
            "provider": context.endpoint.probe?.chat == .failed ? "openai" : "generic-chat-completion-api",
        ]
        if let limit = context.model.maxOutputTokens { entry["maxOutputTokens"] = limit }
        models.append(entry)
        root["customModels"] = models

        // Droid 用“显示名-序号”引用自定义模型。
        defaults["model"] = "custom:\(Self.displayName)-\(models.count - 1)"
        defaults["reasoningEffort"] = context.endpoint.effort.wireValue
        root["sessionDefaultSettings"] = defaults

        try JSONConfigFile.save(root, to: file, backups: context.backups, label: id.rawValue)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return originals
    }

    public func restore(paths: AppPaths, backups: BackupStore, originals: [String: String]) throws {
        let file = configFile(paths: paths)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var root = try JSONConfigFile.load(file)
        let models = (root["customModels"] as? [[String: Any]] ?? []).filter { $0["displayName"] as? String != Self.displayName }
        root["customModels"] = models.isEmpty ? nil : models
        if var defaults = root["sessionDefaultSettings"] as? [String: Any],
           (defaults["model"] as? String)?.hasPrefix("custom:\(Self.displayName)-") == true {
            for key in Self.defaultKeys { defaults[key] = originals[key] }
            root["sessionDefaultSettings"] = defaults.isEmpty ? nil : defaults
        }
        try JSONConfigFile.save(root, to: file, backups: backups, label: id.rawValue)
    }

    public func isApplied(_ context: SyncContext) -> Bool {
        guard let root = try? JSONConfigFile.load(configFile(paths: context.paths)),
              let defaults = root["sessionDefaultSettings"] as? [String: Any],
              (defaults["model"] as? String)?.hasPrefix("custom:\(Self.displayName)-") == true,
              defaults["reasoningEffort"] as? String == context.endpoint.effort.wireValue,
              let entry = (root["customModels"] as? [[String: Any]])?.first(where: { $0["displayName"] as? String == Self.displayName })
        else { return false }
        return entry["model"] as? String == context.model.id
            && entry["baseUrl"] as? String == context.endpoint.baseURL
    }
}
