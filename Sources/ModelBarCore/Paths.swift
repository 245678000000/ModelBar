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
    public var backupsDirectory: URL { support.appending(path: "backups", directoryHint: .isDirectory) }

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
            ".opencode/bin", ".local/bin", ".npm-global/bin", ".bun/bin", ".cargo/bin",
        ].map { home.appending(path: $0, directoryHint: .isDirectory) }
            + ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func findBinary(_ name: String) -> URL? {
        binaryDirectories
            .map { $0.appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
