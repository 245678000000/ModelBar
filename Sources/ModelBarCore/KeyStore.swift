import Foundation
import Security

public protocol KeyStore: Sendable {
    func key(for id: UUID) throws -> String?
    func setKey(_ key: String?, for id: UUID) throws
}

public struct KeyStoreError: LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "错误码 \(status)"
        return "钥匙串操作失败：\(detail)"
    }
}

/// 主密钥存放在系统钥匙串。
public struct KeychainStore: KeyStore {
    public let service: String

    public init(service: String = "ModelBar") {
        self.service = service
    }

    private func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    public func key(for id: UUID) throws -> String? {
        var query = query(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyStoreError(status: status) }
        return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setKey(_ key: String?, for id: UUID) throws {
        let base = query(for: id)
        guard let key, !key.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeyStoreError(status: status)
            }
            return
        }
        let data = Data(key.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeyStoreError(status: update) }
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "\(service) API Key"
        let add = SecItemAdd(attributes as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeyStoreError(status: add) }
    }
}

/// 只用于测试和隔离运行，不写入真实钥匙串。
public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]

    public init() {}

    public func key(for id: UUID) throws -> String? {
        lock.withLock { values[id] }
    }

    public func setKey(_ key: String?, for id: UUID) throws {
        lock.withLock { values[id] = (key?.isEmpty == false) ? key : nil }
    }
}

/// 隔离运行时使用的文件版本，让沙盒模式下重启应用后密钥仍在。
public struct SandboxFileKeyStore: KeyStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func file(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).master")
    }

    public func key(for id: UUID) throws -> String? {
        try? String(contentsOf: file(for: id), encoding: .utf8)
    }

    public func setKey(_ key: String?, for id: UUID) throws {
        guard let key, !key.isEmpty else {
            try? FileManager.default.removeItem(at: file(for: id))
            return
        }
        try FileSupport.writePrivate(Data(key.utf8), to: file(for: id))
    }
}
