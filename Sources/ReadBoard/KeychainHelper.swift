import Foundation
import Security

/// Keychain 轻量封装：API key / token 等敏感配置的存取。
/// 不存 UserDefaults——plist 明文可被其他进程读取，也会进备份/同步。
public enum KeychainHelper {

    private static let service = "com.readboard"

    /// 一次性「治愈」旧版写入、带有「需授权访问」ACL 的 Keychain 项。
    /// 历史原因：早期 save 没设 kSecAttrAccessControl，导致每次读取都弹钥匙串密码框。
    /// 这里在新版首次启动时，把已知 LLM Key 读出来用新 ACL 重写（幂等，只跑一次）。
    /// 注意：第一次重写时，旧项的读取本身仍会触发一次授权弹框（不可避免），
    /// 但之后所有读取都不再弹——属于一次性的阵痛。
    static func healACLIfNeeded() {
        let flag = "com.readboard.keychainACLHealed"
        let d = UserDefaults.standard
        guard !d.bool(forKey: flag) else { return }
        d.set(true, forKey: flag)  // 先置位，避免重写失败时死循环重试

        // 已知走 Keychain 的 Key：llm.slot{0..<16}.apiKey
        for i in 0..<16 {
            let k = "llm.slot\(i).apiKey"
            if let v = load(forKey: k), !v.isEmpty {
                _ = saveWithStatus(v, forKey: k)
            }
        }
        // 溢出处理：扫描 service 下所有 generic password，统一重写（覆盖不规范的 account 名）
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      let v = load(forKey: account), !v.isEmpty else { continue }
                _ = saveWithStatus(v, forKey: account)
            }
        }
    }

    static func save(_ value: String, forKey key: String) -> Bool {
        saveWithStatus(value, forKey: key) == errSecSuccess
    }

    /// 带状态码的版本（诊断用）：返回 OSStatus 而非 Bool
    /// ⚠️ 关键不变量：本方法【绝不先删后加】。任何情况下都不能在「新值写入成功」之前
    /// 删除旧值——否则一旦 SecItemAdd 因 AccessControl 等配置失败，旧 Key 会永久丢失。
    /// 采用 update-or-add 语义：
    ///   1) 先尝试 SecItemUpdate（就地改 data + ACL，旧值始终安全）
    ///   2) 仅当 errSecItemNotFound 才 SecItemAdd（新增）
    static func saveWithStatus(_ value: String, forKey key: String) -> OSStatus {
        guard let data = value.data(using: .utf8) else { return -1 }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // 无弹框 ACL：解锁即可用、无附加授权约束。
        guard let acc = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [], nil) else { return -1 }
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessControl as String: acc,
        ]
        // 1) 就地更新（不碰旧值，旧值在此步失败也绝不丢失）
        let upd = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if upd == errSecSuccess { return upd }
        if upd == errSecItemNotFound {
            // 2) 不存在才新增，新增只 add 不删任何东西
            var attrs = query
            attrs[kSecValueData as String] = data
            attrs[kSecAttrAccessControl as String] = acc
            return SecItemAdd(attrs as CFDictionary, nil)
        }
        // 其他错误（如权限/ACL 冲突）：原样返回，旧值完好无损
        return upd
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

    /// 诊断探针：用固定 ACL 尝试写一条临时 Keychain 项并立即删除，返回 OSStatus。
    /// 0 = 写入成功（Keychain 可用）；-34018 等 = 进程缺 entitlement 或环境受限。
    static func probeWrite() -> Int {
        let probeKey = "com.readboard.__probe__"
        let _ = delete(forKey: probeKey)  // 清掉历史残留
        guard let data = "probe".data(using: .utf8) else { return -1 }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: probeKey,
        ]
        guard let acc = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [], nil) else { return -2 }
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessControl as String] = acc
        let st = SecItemAdd(attrs as CFDictionary, nil)
        let _ = delete(forKey: probeKey)
        return Int(st)
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
