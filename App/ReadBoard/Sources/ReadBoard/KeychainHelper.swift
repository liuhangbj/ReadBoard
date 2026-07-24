import Foundation
import Security

/// Keychain 轻量封装：API key / token 等敏感配置的存取。
/// 不存 UserDefaults——plist 明文可被其他进程读取，也会进备份/同步。
public enum KeychainHelper {

    private static let service = "com.readboard"

    static func save(_ value: String, forKey key: String) -> Bool {
        saveWithStatus(value, forKey: key) == errSecSuccess
    }

    /// 带状态码的版本（诊断用）：返回 OSStatus 而非 Bool
    static func saveWithStatus(_ value: String, forKey key: String) -> OSStatus {
        guard let data = value.data(using: .utf8) else { return -1 }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // 先删后加，避免重复项；kSecAttrAccessible 默认解锁后可访问即可
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        return SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load(forKey key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    static func delete(forKey key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    static func exists(forKey key: String) -> Bool {
        var query = baseQuery(key)
        query[kSecReturnData as String] = false
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
