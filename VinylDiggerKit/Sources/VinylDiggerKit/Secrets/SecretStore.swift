import Foundation
import Security

public enum SecretKey: String, CaseIterable, Sendable {
    case discogsToken
    case discogsUsername
}

public enum SecretStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case malformedData
}

public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) throws -> String?
    func write(_ value: String, for key: SecretKey) throws
    func delete(_ key: SecretKey) throws
}

public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "de.schakal.VinylDigger") {
        self.service = service
    }

    private func baseQuery(_ key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }

    public func read(_ key: SecretKey) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.unexpectedStatus(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.malformedData
        }
        return value
    }

    public func write(_ value: String, for key: SecretKey) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(
            baseQuery(key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError.unexpectedStatus(update) }

        var insert = baseQuery(key)
        insert[kSecValueData as String] = data
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.unexpectedStatus(status) }
    }

    public func delete(_ key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretKey: String] = [:]

    public init() {}

    public func read(_ key: SecretKey) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    public func write(_ value: String, for key: SecretKey) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    public func delete(_ key: SecretKey) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = nil
    }
}
