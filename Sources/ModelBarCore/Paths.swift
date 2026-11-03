import Foundation

/// 所有文件路径的唯一来源。把 `home` 指向临时目录即可完全隔离真实配置。
public struct AppPaths: Sendable {
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        if let sandbox = environment["MODELBAR_HOME"], !sandbox.isEmpty {
            return AppPaths(home: URL(fileURLWithPath: sandbox, isDirectory: true))
        }
        return AppPaths(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    public var isSandboxed: Bool {
        home.standardizedFileURL != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    public var support: URL { home.appending(path: "Library/Application Support/ModelBar", directoryHint: .isDirectory) }
    public var stateFile: URL { support.appending(path: "state.json") }
    public var keysDirectory: URL { support.appending(path: "keys", directoryHint: .isDirectory) }
    public var masterKeysDirectory: URL { support.appending(path: "master-keys", directoryHint: .isDirectory) }
    public var backupsDirectory: URL { support.appending(path: "backups", directoryHint: .isDirectory) }
    public var updatesDirectory: URL { support.appending(path: "updates", directoryHint: .isDirectory) }

    public func keyFile(for id: UUID) -> URL {
        keysDirectory.appending(path: "\(id.uuidString).key")
    }

    public var bridgeConfig: URL { support.appending(path: "bridge.json") }
    public var bridgeToken: URL { keysDirectory.appending(path: "bridge.token") }
    public var bridgeLog: URL { home.appending(path: "Library/Logs/ModelBar/bridge.log") }
    public var bridgeLabel: String { isSandboxed ? "com.local.modelbar.bridge.sandbox" : "com.local.modelbar.bridge" }
    public var bridgePlist: URL { home.appending(path: "Library/LaunchAgents/\(bridgeLabel).plist") }

    public var opencodeDirectory: URL { home.appending(path: ".config/opencode", directoryHint: .isDirectory) }
    public var kiloDirectory: URL { home.appending(path: ".config/kilo", directoryHint: .isDirectory) }
    public var codexDirectory: URL { home.appending(path: ".codex", directoryHint: .isDirectory) }
    public var codexConfig: URL { codexDirectory.appending(path: "config.toml") }
    public var claudeSettings: URL { home.appending(path: ".claude/settings.json") }
    public var piDirectory: URL { home.appending(path: ".pi/agent", directoryHint: .isDirectory) }
    public var grokConfig: URL { home.appending(path: ".grok/config.toml") }
    public var droidSettings: URL { home.appending(path: ".factory/settings.json") }

    /// 优先使用已存在的配置文件，避免新建一个优先级不明确的文件。
    public func jsonConfig(in directory: URL, baseName: String) -> URL {
        let candidates = ["\(baseName).jsonc", "\(baseName).json"].map { directory.appending(path: $0) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? directory.appending(path: "\(baseName).json")
    }

    public var extensionRoots: [URL] {
        [".cursor/extensions", ".vscode/extensions"].map { home.appending(path: $0, directoryHint: .isDirectory) }
    }

    /// 图形应用的 PATH 很短，所以直接查常见的安装目录。
    public var binaryDirectories: [URL] {
        [
            ".opencode/bin", ".grok/bin", ".local/bin", ".npm-global/bin", ".bun/bin", ".cargo/bin",
            ".volta/bin", ".asdf/shims", ".local/share/mise/shims", ".yarn/bin", "Library/pnpm", ".local/share/pnpm",
        ].map { home.appending(path: $0, directoryHint: .isDirectory) }
            + npmPrefixBinDirectories
            + nodeVersionBinDirectories
            + ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// `npm config set prefix` 写在 ~/.npmrc 里，全局命令装在它的 bin 目录。
    private var npmPrefixBinDirectories: [URL] {
        guard let text = try? String(contentsOf: home.appending(path: ".npmrc"), encoding: .utf8) else { return [] }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "prefix" else { continue }
            var value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            for variable in ["${HOME}", "$HOME"] {
                value = value.replacingOccurrences(of: variable, with: home.path)
            }
            if value.hasPrefix("~/") { value = home.path + value.dropFirst() }
            guard value.hasPrefix("/") else { return [] }
            return [URL(fileURLWithPath: value, isDirectory: true).appending(path: "bin", directoryHint: .isDirectory)]
        }
        return []
    }

    /// nvm 和 fnm 把全局命令装在各 Node 版本自己的目录里，版本号不固定，只能列出来。
    private var nodeVersionBinDirectories: [URL] {
        [
            (".nvm/versions/node", "bin"),
            (".fnm/node-versions", "installation/bin"),
            (".local/share/fnm/node-versions", "installation/bin"),
            ("Library/Application Support/fnm/node-versions", "installation/bin"),
        ].flatMap { root, suffix in
            let directory = home.appending(path: root, directoryHint: .isDirectory)
            let versions = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return versions.map { $0.appending(path: suffix, directoryHint: .isDirectory) }
        }
    }

    public func findBinary(_ name: String) -> URL? {
        binaryDirectories
            .map { $0.appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
