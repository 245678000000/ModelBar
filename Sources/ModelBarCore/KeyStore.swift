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

/// 旧版本的存放位置，现在只用于迁移。
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

/// 密钥存成只有当前用户能读的文件。
/// 不用钥匙串，是因为自签名的应用没有 Apple 的团队 ID，钥匙串按每次编译的哈希记录授权，每次更新都要重新授权。
public struct FileKeyStore: KeyStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func file(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).master")
    }

    public func key(for id: UUID) throws -> String? {
        guard let key = try? String(contentsOf: file(for: id), encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    public func setKey(_ key: String?, for id: UUID) throws {
        let file = file(for: id)
        guard let key, !key.isEmpty else {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            return
        }
        try FileSupport.writePrivate(Data(key.utf8), to: file)
    }
}

/// 旧版本把密钥存在钥匙串。第一次用到时才搬过来，避免一启动就连续弹窗。
public struct MigratingKeyStore: KeyStore {
    private let primary: any KeyStore
    private let legacy: any KeyStore

    public init(primary: any KeyStore, legacy: any KeyStore) {
        self.primary = primary
        self.legacy = legacy
    }

    public func key(for id: UUID) throws -> String? {
        if let key = try primary.key(for: id) { return key }
        guard let key = try legacy.key(for: id) else { return nil }
        // 确认写好了才删旧条目。写不了时这次仍然能用，下次再试。
        if (try? primary.setKey(key, for: id)) != nil, (try? primary.key(for: id)) == key {
            try? legacy.setKey(nil, for: id)
        }
        return key
    }

    public func setKey(_ key: String?, for id: UUID) throws {
        try primary.setKey(key, for: id)
        if let key, !key.isEmpty {
            // 文件优先，旧条目删不掉也不影响使用。
            try? legacy.setKey(nil, for: id)
        } else {
            // 清除 Key 时必须报错，否则下次读取它会从钥匙串里复活。
            try legacy.setKey(nil, for: id)
        }
    }
}
