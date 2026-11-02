import Darwin
import Foundation
import Security

public enum BridgeInfo {
    /// 转换服务和应用的协议版本。应用更新后如果版本不同，会重启服务。
    public static let version = 4
    public static let defaultPort = 47631
    public static let portSearchRange = 20
}

/// 转换服务启动时和每次请求时读取，切换接口不需要重启服务。
public struct BridgeConfig: Codable, Equatable, Sendable {
    public var port: Int
    public var tokenFile: String
    public var upstreamBaseURL: String
    public var upstreamKeyFile: String?
    /// 请求没带推理档位时使用。Claude Code 不一定会为陌生模型发送档位。
    public var defaultEffort: String?

    public init(port: Int, tokenFile: String, upstreamBaseURL: String, upstreamKeyFile: String?, defaultEffort: String? = nil) {
        self.port = port
        self.tokenFile = tokenFile
        self.upstreamBaseURL = upstreamBaseURL
        self.upstreamKeyFile = upstreamKeyFile
        self.defaultEffort = defaultEffort
    }

    public static func load(from file: URL) throws -> BridgeConfig {
        try JSONDecoder().decode(BridgeConfig.self, from: Data(contentsOf: file))
    }
}

public struct BridgeTarget: Equatable, Sendable {
    public var baseURL: String
    public var tokenFile: URL

    public init(baseURL: String, tokenFile: URL) {
        self.baseURL = baseURL
        self.tokenFile = tokenFile
    }
}

public protocol BridgeServiceControl: Sendable {
    func install(executable: URL, configFile: URL, logFile: URL) throws
    func restart() throws
    func uninstall()
}

/// 用 launchd 托管，应用退出后服务继续运行，崩溃后也会自动拉起。
public struct LaunchdControl: BridgeServiceControl {
    public let label: String
    public let plistFile: URL

    private static let launchctl = URL(fileURLWithPath: "/bin/launchctl")

    public init(label: String, plistFile: URL) {
        self.label = label
        self.plistFile = plistFile
    }

    private var domain: String { "gui/\(getuid())" }
    private var service: String { "\(domain)/\(label)" }

    private var isLoaded: Bool {
        ProcessRunner.run(Self.launchctl, arguments: ["print", service], timeout: 5).exitCode == 0
    }

    public func install(executable: URL, configFile: URL, logFile: URL) throws {
        try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "--config", configFile.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 5,
            "ProcessType": "Background",
            "StandardOutPath": logFile.path,
            "StandardErrorPath": logFile.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let unchanged = (try? Data(contentsOf: plistFile)) == data
        if unchanged, isLoaded { return }

        if isLoaded { _ = ProcessRunner.run(Self.launchctl, arguments: ["bootout", service], timeout: 10) }
        try FileSupport.writeAtomically(data, to: plistFile)
        let result = ProcessRunner.run(Self.launchctl, arguments: ["bootstrap", domain, plistFile.path], timeout: 10)
        guard result.exitCode == 0 else {
            throw ConfigError("无法启动本机转换服务：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    public func restart() throws {
        let result = ProcessRunner.run(Self.launchctl, arguments: ["kickstart", "-k", service], timeout: 10)
        guard result.exitCode == 0 else {
            throw ConfigError("无法重启本机转换服务：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    public func uninstall() {
        if isLoaded { _ = ProcessRunner.run(Self.launchctl, arguments: ["bootout", service], timeout: 10) }
        try? FileManager.default.removeItem(at: plistFile)
    }
}

public struct BridgeManager: Sendable {
    public typealias HealthCheck = @Sendable (Int) -> Int?

    private let paths: AppPaths
    private let executable: URL?
    private let control: any BridgeServiceControl
    private let health: HealthCheck
    private let isPortFree: @Sendable (Int) -> Bool

    public init(
        paths: AppPaths,
        executable: URL?,
        control: (any BridgeServiceControl)? = nil,
        health: @escaping HealthCheck = BridgeManager.liveHealth,
        isPortFree: @escaping @Sendable (Int) -> Bool = BridgeManager.canBind
    ) {
        self.paths = paths
        self.executable = executable
        self.control = control ?? LaunchdControl(label: paths.bridgeLabel, plistFile: paths.bridgePlist)
        self.health = health
        self.isPortFree = isPortFree
    }

    /// 写好配置并确保服务在运行。重复调用是安全的。
    public func prepare(endpoint: Endpoint, keyFile: URL?) throws -> BridgeTarget {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ConfigError("找不到本机转换程序，请重新安装 ModelBar")
        }
        let tokenFile = try ensureToken()
        let previous = try? BridgeConfig.load(from: paths.bridgeConfig)
        let port = try choosePort(previous: previous)
        let config = BridgeConfig(
            port: port,
            tokenFile: tokenFile.path,
            upstreamBaseURL: endpoint.baseURL,
            upstreamKeyFile: keyFile?.path,
            defaultEffort: endpoint.effort.wireValue
        )
        if config != previous {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try FileSupport.writePrivate(try encoder.encode(config), to: paths.bridgeConfig)
        }
        try control.install(executable: executable, configFile: paths.bridgeConfig, logFile: paths.bridgeLog)
        if let previous, previous.port != port { try control.restart() }

        var version = waitForService(port: port)
        if version != BridgeInfo.version {
            // 应用更新后服务还是旧版本，或者服务没有响应。
            try control.restart()
            version = waitForService(port: port)
        }
        guard version == BridgeInfo.version else {
            throw ConfigError("本机转换服务没有响应，可以在“工具同步”里查看日志")
        }
        return BridgeTarget(baseURL: "http://127.0.0.1:\(port)/v1", tokenFile: tokenFile)
    }

    public func target() -> BridgeTarget? {
        guard let config = try? BridgeConfig.load(from: paths.bridgeConfig) else { return nil }
        return BridgeTarget(baseURL: "http://127.0.0.1:\(config.port)/v1", tokenFile: URL(fileURLWithPath: config.tokenFile))
    }

    public func isHealthy() -> Bool {
        guard let config = try? BridgeConfig.load(from: paths.bridgeConfig) else { return false }
        return health(config.port) == BridgeInfo.version
    }

    public func stop() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: paths.bridgeConfig.path) || manager.fileExists(atPath: paths.bridgePlist.path) else { return }
        control.uninstall()
        try? manager.removeItem(at: paths.bridgeConfig)
        try? manager.removeItem(at: paths.bridgeToken)
    }

    private func waitForService(port: Int) -> Int? {
        for attempt in 0..<20 {
            if let version = health(port) { return version }
            if attempt < 19 { Thread.sleep(forTimeInterval: 0.2) }
        }
        return nil
    }

    private func choosePort(previous: BridgeConfig?) throws -> Int {
        if let previous, health(previous.port) != nil || isPortFree(previous.port) { return previous.port }
        for offset in 0..<BridgeInfo.portSearchRange where isPortFree(BridgeInfo.defaultPort + offset) {
            return BridgeInfo.defaultPort + offset
        }
        throw ConfigError("找不到可用的本机端口")
    }

    private func ensureToken() throws -> URL {
        let file = paths.bridgeToken
        if let existing = try? String(contentsOf: file, encoding: .utf8), !existing.isEmpty { return file }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ConfigError("无法生成本机访问令牌")
        }
        let token = "mb-" + bytes.map { String(format: "%02x", $0) }.joined()
        try FileSupport.writePrivate(Data(token.utf8), to: file)
        return file
    }

    public static let liveHealth: HealthCheck = { port in
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 1
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        let box = VersionBox()
        session.dataTask(with: url) { data, _, _ in
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                box.value = object["version"] as? Int
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1.5)
        return box.value
    }

    public static let canBind: @Sendable (Int) -> Bool = { port in
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private final class VersionBox: @unchecked Sendable {
        var value: Int?
    }
}
