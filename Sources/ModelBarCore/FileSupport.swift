import Foundation

public enum FileSupport {
    /// 原子写入，并保持已有文件的权限。
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existingAttributes = try? manager.attributesOfItem(atPath: url.path)
        try data.write(to: url, options: .atomic)
        if let mode = existingAttributes?[.posixPermissions] {
            try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
    }

    /// 目录 0700、文件 0600，只有当前用户能读。
    public static func writePrivate(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// 改动工具配置前保留副本，每个文件最多保留 `limit` 份。
public struct BackupStore: Sendable {
    public let directory: URL
    public let limit: Int

    public init(directory: URL, limit: Int = 10) {
        self.directory = directory
        self.limit = limit
    }

    @discardableResult
    public func backup(_ file: URL, label: String, now: Date = Date()) throws -> URL? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return nil }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let target = directory.appending(path: "\(label)-\(formatter.string(from: now))-\(file.lastPathComponent)")
        try manager.copyItem(at: file, to: target)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try prune(label: label)
        return target
    }

    public func backups(label: String) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { $0.lastPathComponent.hasPrefix("\(label)-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func prune(label: String) throws {
        let items = backups(label: label)
        guard items.count > limit else { return }
        for item in items.prefix(items.count - limit) {
            try FileManager.default.removeItem(at: item)
        }
    }
}
