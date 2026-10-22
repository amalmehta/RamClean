import Foundation
import Security

/// A small key-value store for the trial clock and the licence. The app keeps two copies,
/// one in the Keychain and one in UserDefaults, so deleting either one doesn't reset the trial.
public protocol SecureStore: AnyObject {
    func data(for key: String) -> Data?
    /// nil removes the value.
    func set(_ data: Data?, for key: String)
}

/// Generic-password items in the login Keychain, one per key. It survives deleting
/// RamClean's preferences and data folder.
public final class KeychainStore: SecureStore {
    public let service: String

    public init(service: String) { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    public func data(for key: String) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func set(_ data: Data?, for key: String) {
        guard let data else { SecItemDelete(query(key) as CFDictionary); return }
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// UserDefaults under a prefix: the second copy of the trial start.
public final class DefaultsStore: SecureStore {
    private let defaults: UserDefaults
    private let prefix: String

    public init(_ defaults: UserDefaults = .standard, prefix: String = "RamCleanLicensing.") {
        self.defaults = defaults; self.prefix = prefix
    }

    public func data(for key: String) -> Data? { defaults.data(forKey: prefix + key) }
    public func set(_ data: Data?, for key: String) { defaults.set(data, forKey: prefix + key) }
}

/// In memory only; for tests.
public final class MemoryStore: SecureStore {
    public var values: [String: Data] = [:]
    public init() {}
    public func data(for key: String) -> Data? { values[key] }
    public func set(_ data: Data?, for key: String) { values[key] = data }
}
