import CryptoKit
import Foundation
import Security

public struct UpdateError: LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// 版本号按数字逐段比较，缺的段当作 0。
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let description: String
    private let parts: [Int]

    public init?(_ text: String) {
        var parts: [Int] = []
        for piece in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard !piece.isEmpty, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(piece) else {
                return nil
            }
            parts.append(number)
        }
        self.parts = parts
        description = text
    }

    private func part(_ index: Int) -> Int {
        index < parts.count ? parts[index] : 0
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) where lhs.part(index) != rhs.part(index) {
            return lhs.part(index) < rhs.part(index)
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

public struct AppUpdate: Equatable, Sendable {
    public let version: AppVersion
    public let archiveURL: URL
    public let checksumsURL: URL
    public let pageURL: URL
}

/// Mac 和 Windows 的版本号各走各的，所以 Mac 版只看 mac-v 开头的发布。
public enum UpdateFeed {
    public static let tagPrefix = "mac-v"
    public static let archiveName = "ModelBar-mac.zip"
    public static let checksumsName = "SHA256SUMS.txt"

    private static let releasesURL = URL(string: "https://api.github.com/repos/245678000000/ModelBar/releases?per_page=30")!

    /// 隔离运行时不访问真实的发布地址，只用测试指定的地址。
    public static func url(paths: AppPaths, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard paths.isSandboxed else { return releasesURL }
        return environment["MODELBAR_UPDATE_FEED"].flatMap(URL.init(string:))
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }

        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let html_url: String
        let assets: [Asset]

        func assetURL(_ name: String, allowsAnyHost: Bool) -> URL? {
            guard let text = assets.first(where: { $0.name == name })?.browser_download_url,
                  let url = URL(string: text) else { return nil }
            return allowsAnyHost || (url.scheme == "https" && url.host == "github.com") ? url : nil
        }
    }

    public static func latest(in data: Data, newerThan current: AppVersion, allowsAnyHost: Bool = false) throws -> AppUpdate? {
        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else {
            throw UpdateError("更新信息的格式不对")
        }
        var best: AppUpdate?
        for release in releases where !release.draft && !release.prerelease && release.tag_name.hasPrefix(tagPrefix) {
            guard let version = AppVersion(String(release.tag_name.dropFirst(tagPrefix.count))),
                  version > current,
                  best.map({ version > $0.version }) ?? true,
                  let archive = release.assetURL(archiveName, allowsAnyHost: allowsAnyHost),
                  let checksums = release.assetURL(checksumsName, allowsAnyHost: allowsAnyHost),
                  let page = URL(string: release.html_url) else { continue }
            best = AppUpdate(version: version, archiveURL: archive, checksumsURL: checksums, pageURL: page)
        }
        return best
    }
}

public protocol UpdateTransport: Sendable {
    func data(from url: URL) async throws -> Data
    func download(from url: URL) async throws -> URL
}

public struct URLSessionUpdateTransport: UpdateTransport {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    public init() {}

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("ModelBar", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("服务器返回错误 \(http.statusCode)")
        }
    }

    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await Self.session.data(for: request(url))
        try check(response)
        return data
    }

    public func download(from url: URL) async throws -> URL {
        let (file, response) = try await Self.session.download(for: request(url))
        try check(response)
        return file
    }
}

public protocol UpdateVerifier: Sendable {
    func verify(app: URL) throws
}

/// 新版必须和正在运行的版本出自同一张证书，下载来源出问题也装不上别人打包的程序。
public struct SigningVerifier: UpdateVerifier {
    private let requirementText: String?

    /// 不传时用正在运行的程序自己的签名要求。
    public init(requirementText: String? = nil) {
        self.requirementText = requirementText
    }

    private static func runningRequirementText() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw UpdateError("当前版本没有有效的签名，请手动下载新版")
        }
        return text as String
    }

    public func verify(app: URL) throws {
        let text = try requirementText ?? Self.runningRequirementText()
        // 临时签名的要求是某次编译的哈希，新版永远满足不了，也说明不了来源。
        guard !text.contains("cdhash") else {
            throw UpdateError("当前版本没有用固定证书签名，请手动下载新版")
        }
        var requirement: SecRequirement?
        var staticCode: SecStaticCode?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError("无法校验新版的签名")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw UpdateError("新版的签名不对，已停止更新")
        }
    }
}

public struct UpdateChecker: Sendable {
    private let feedURL: URL
    private let allowsAnyHost: Bool
    private let transport: any UpdateTransport

    public init(feedURL: URL, allowsAnyHost: Bool, transport: any UpdateTransport) {
        self.feedURL = feedURL
        self.allowsAnyHost = allowsAnyHost
        self.transport = transport
    }

    public func latest(newerThan current: AppVersion) async throws -> AppUpdate? {
        try UpdateFeed.latest(in: try await transport.data(from: feedURL), newerThan: current, allowsAnyHost: allowsAnyHost)
    }
}

/// 下载、校验都在替换之前完成，替换之前的任何失败都不会碰到正在用的版本。
public struct UpdateInstaller: Sendable {
    private static let stagedPrefix = ".ModelBar-update-"
    private static let backupPrefix = ".ModelBar-previous-"

    /// 等旧版退出后打开新版。新版没能运行起来就换回旧版。
    private static let relaunchScript = #"""
    pid=$1 app=$2 backup=$3 executable=$4
    restore() {
      /bin/rm -rf "$app" && /bin/mv "$backup" "$app"
    }
    tries=0
    while kill -0 "$pid" 2>/dev/null; do
      tries=$((tries + 1))
      if [ "$tries" -ge 150 ]; then
        restore
        exit 1
      fi
      sleep 0.2
    done
    launch() {
      /usr/bin/open ${MODELBAR_HOME:+--env "MODELBAR_HOME=$MODELBAR_HOME"} \
        ${MODELBAR_UPDATE_FEED:+--env "MODELBAR_UPDATE_FEED=$MODELBAR_UPDATE_FEED"} "$app"
    }
    launch
    sleep 8
    if /bin/ps -axo command= | /usr/bin/grep -Fxq "$app/Contents/MacOS/$executable"; then
      /bin/rm -rf "$backup"
    else
      restore && launch
    fi
    """#

    private let appBundle: URL
    private let bundleIdentifier: String
    private let workDirectory: URL
    private let transport: any UpdateTransport
    private let verifier: any UpdateVerifier

    public init(
        appBundle: URL,
        bundleIdentifier: String,
        workDirectory: URL,
        transport: any UpdateTransport,
        verifier: any UpdateVerifier
    ) {
        self.appBundle = appBundle
        self.bundleIdentifier = bundleIdentifier
        self.workDirectory = workDirectory
        self.transport = transport
        self.verifier = verifier
    }

    private var parent: URL { appBundle.deletingLastPathComponent() }

    public func checkCanInstall() throws {
        let manager = FileManager.default
        guard appBundle.pathExtension == "app", !appBundle.path.contains("/AppTranslocation/"),
              !appBundle.path.hasPrefix("/Volumes/") else {
            throw UpdateError("请先把 ModelBar 拖进“应用程序”文件夹，再安装更新")
        }
        guard manager.isWritableFile(atPath: parent.path), manager.isWritableFile(atPath: appBundle.path) else {
            throw UpdateError("没有权限替换 \(appBundle.path)，请手动下载新版")
        }
    }

    /// 下载并校验新版，放到旧版旁边等待替换，返回它的位置。
    public func prepare(_ update: AppUpdate) async throws -> URL {
        try checkCanInstall()
        let manager = FileManager.default
        let work = workDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }

        let archive = work.appending(path: UpdateFeed.archiveName)
        try manager.moveItem(at: try await transport.download(from: update.archiveURL), to: archive)
        let checksums = try await transport.data(from: update.checksumsURL)
        try Self.verifyChecksum(of: archive, checksums: checksums)

        let extracted = work.appending(path: "extracted", directoryHint: .isDirectory)
        let unpack = ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, extracted.path],
            timeout: 120
        )
        guard unpack.exitCode == 0 else { throw UpdateError("无法解压更新包") }
        let contents = try manager.contentsOfDirectory(atPath: extracted.path).filter { $0 != "__MACOSX" }
        guard contents == [appBundle.lastPathComponent] else { throw UpdateError("更新包的内容不对") }
        let newApp = extracted.appending(path: contents[0], directoryHint: .isDirectory)

        let info = Bundle(url: newApp)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateError("更新包不是 ModelBar")
        }
        guard (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == update.version else {
            throw UpdateError("更新包的版本和发布信息不一致")
        }
        try verifier.verify(app: newApp)

        let staged = parent.appending(path: "\(Self.stagedPrefix)\(UUID().uuidString).app", directoryHint: .isDirectory)
        try manager.moveItem(at: newApp, to: staged)
        return staged
    }

    private static func verifyChecksum(of file: URL, checksums: Data) throws {
        let expected = String(decoding: checksums, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard parts.count == 2 else { return nil }
                let name = parts[1].trimmingCharacters(in: .whitespaces)
                return (name == UpdateFeed.archiveName || name == "*\(UpdateFeed.archiveName)") ? parts[0].lowercased() : nil
            }
            .first
        guard let expected else { throw UpdateError("发布信息里没有更新包的校验值") }
        let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
        guard digest.map({ String(format: "%02x", $0) }).joined() == expected else {
            throw UpdateError("更新包的校验值不对，可能下载不完整")
        }
    }

    /// 把新版换到旧版的位置，返回旧版现在的位置。第二步失败时恢复原样。
    public func swapIn(_ staged: URL) throws -> URL {
        let manager = FileManager.default
        let backup = parent.appending(path: "\(Self.backupPrefix)\(UUID().uuidString).app", directoryHint: .isDirectory)
        try manager.moveItem(at: appBundle, to: backup)
        do {
            try manager.moveItem(at: staged, to: appBundle)
        } catch {
            try? manager.moveItem(at: backup, to: appBundle)
            throw error
        }
        return backup
    }

    /// 换好新版并安排重启，调用方接下来应该退出应用。beforeSwap 抛错时不替换，旧版不变。
    public func install(_ update: AppUpdate, beforeSwap: @Sendable () async throws -> Void = {}) async throws {
        let staged = try await prepare(update)
        let manager = FileManager.default
        do {
            try await beforeSwap()
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
        let executable = Bundle(url: staged)?.infoDictionary?["CFBundleExecutable"] as? String ?? appBundle.deletingPathExtension().lastPathComponent
        let backup: URL
        do {
            backup = try swapIn(staged)
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c", Self.relaunchScript, "sh",
            String(ProcessInfo.processInfo.processIdentifier), appBundle.path, backup.path, executable,
        ]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            try? manager.removeItem(at: appBundle)
            try? manager.moveItem(at: backup, to: appBundle)
            throw error
        }
    }

    /// 清理上次更新中断时留下的文件。
    public func removeLeftovers() {
        let manager = FileManager.default
        try? manager.removeItem(at: workDirectory)
        for name in (try? manager.contentsOfDirectory(atPath: parent.path)) ?? []
        where name.hasSuffix(".app") && (name.hasPrefix(Self.stagedPrefix) || name.hasPrefix(Self.backupPrefix)) {
            try? manager.removeItem(at: parent.appending(path: name, directoryHint: .isDirectory))
        }
    }
}
