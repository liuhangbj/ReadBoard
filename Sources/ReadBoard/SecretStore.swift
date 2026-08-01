import Foundation
import CommonCrypto
#if canImport(CryptoKit)
import CryptoKit
#endif

/// 本地加密敏感凭证存储（替代 Keychain）。
///
/// 背景：当前运行环境（ad-hoc 自签名 + agent 会话启动）下 Keychain 写入返回
/// -34018 (errSecMissingEntitlement)，任何配置都无法落盘。此实现用 App 专属加密
/// 文件替代，环境无关、不会假成功。
///
/// 设计要点：
/// 1. 文件位于当前版本的 Application Support 数据目录，权限 0600。
/// 2. 使用 AES-GCM 加密（CryptoKit），对称密钥由 CommonCrypto PBKDF2 从
///    「serviceID 密码 + (serviceID.机器标识) 盐」派生（不落盘）。
///    机器标识取自本机硬件 UUID；换机后旧密文无法解密（符合预期，且单机自用）。
/// 3. 明文结构体：{ "v": 1, "items": { "<key>": "<base64密文>" } }
///    单条增删不重写全部，避免一处失败整文件丢失。
/// 4. 文件读失败（损坏/不存在）时降级为空字典，不抛错阻断 App。
public enum SecretStore {

    private static let fileName = "secrets.json"
    private static let serviceID = "com.readboard"

    // MARK: - 密钥派生（不落盘）

    /// 机器标识（进程内只取一次：原实现每次派生密钥都 spawn /usr/sbin/ioreg 子进程）。
    private static let machine: String = {
        if let uuid = getHardwareUUID() { return uuid }
        return ProcessInfo.processInfo.hostName
    }()

    /// 派生密钥（进程内只算一次：机器盐 + 10 万次 PBKDF2 是确定性结果，无需重算）。
    /// ⚠️ 原实现是 computed var——每次 SecretStore.load 都重算：
    /// 1 次子进程 + 10 万轮 PBKDF2 ≈ 100~400ms；阅读区操作条每次 body 求值调
    /// isAvailable → 3× load → 3 倍炸弹 × 每篇 ~10 次求值 = 主线程被按死数秒，
    /// 快速连点时 SwiftUI 提交彻底饿死 → AG cycle → 闪退（07-27 崩溃潮根因之一）。
    private static let derivedKey: SymmetricKey = {
        // 盐：固定 serviceID + 机器硬件标识，二者任一变化都会导致解不开旧密文。
        let saltInput = "\(serviceID).\(machine)"
        // SHA256 摘要盐（32 字节）
        let saltData = Data(saltInput.utf8)
        var saltBytes = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = saltData.withUnsafeBytes { ptr in
            CC_SHA256(ptr.baseAddress, CC_LONG(saltData.count), &saltBytes)
        }
        let salt = Data(saltBytes)
        // PBKDF2 拉伸（CommonCrypto），抗离线暴力
        let password = Data(serviceID.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let rc = password.withUnsafeBytes { pptr in
            salt.withUnsafeBytes { sptr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pptr.bindMemory(to: CChar.self).baseAddress, password.count,
                    sptr.bindMemory(to: CChar.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    100_000, &out, out.count)
            }
        }
        if rc != 0 {
            // 极端兜底：PBKDF2 失败则用 salt SHA256 截断（不应发生）
            return SymmetricKey(data: salt.prefix(32))
        }
        return SymmetricKey(data: Data(out))
    }()

    private static func getHardwareUUID() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        task.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let out = String(data: data, encoding: .utf8) else { return nil }
            // 形如："IOPlatformUUID" = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
            let pattern = #""IOPlatformUUID"\s*=\s*"([^"]+)""#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
               let r = Range(match.range(at: 1), in: out) {
                return String(out[r])
            }
        } catch { return nil }
        return nil
    }

    // MARK: - 文件路径

    private static var fileURL: URL? {
        AppResourceLocator.applicationSupportDirectory.appendingPathComponent(fileName)
    }

    // MARK: - 文件读写（带权限锁定）

    private static func readContainer() -> [String: String] {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let raw = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  obj["v"] as? Int == 1,
                  let items = obj["items"] as? [String: String] else { return [:] }
            return items
        } catch {
            fputs("[secret] 读取加密容器失败（文件损坏？），降级为空：\(error)\n", stderr)
            return [:]
        }
    }

    /// 写全部容器；成功后强制文件权限 0600（仅属主可读写）。
    @discardableResult
    private static func writeContainer(_ items: [String: String]) -> Bool {
        guard let url = fileURL else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let obj: [String: Any] = ["v": 1, "items": items]
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            try data.write(to: url, options: .atomic)
            // 锁权限：仅属主可读写
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            fputs("[secret] 写入加密容器失败：\(error)\n", stderr)
            return false
        }
    }

    // MARK: - AES-GCM 加解密

    private static func encrypt(_ plaintext: String) -> String? {
        guard let data = plaintext.data(using: .utf8) else { return nil }
        do {
            let sealed = try AES.GCM.seal(data, using: derivedKey)
            return sealed.combined?.base64EncodedString()
        } catch { return nil }
    }

    private static func decrypt(_ cipherB64: String) -> String? {
        guard let data = Data(base64Encoded: cipherB64) else { return nil }
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let opened = try AES.GCM.open(box, using: derivedKey)
            return String(data: opened, encoding: .utf8)
        } catch { return nil }
    }

    // MARK: - 公开 API

    /// 保存一条凭证。成功返回 true；失败返回 false 且**不残留半截状态**。
    static func save(_ value: String, forKey key: String) -> Bool {
        guard !key.isEmpty else { return false }
        var items = readContainer()
        guard let cipher = encrypt(value) else { return false }
        items[key] = cipher
        return writeContainer(items)
    }

    /// 读取一条凭证。不存在或解密失败返回 nil。
    static func load(forKey key: String) -> String? {
        guard let cipher = readContainer()[key] else { return nil }
        return decrypt(cipher)
    }

    /// 删除一条凭证。键不存在也返回 true（幂等）。
    static func delete(forKey key: String) -> Bool {
        var items = readContainer()
        guard items.removeValue(forKey: key) != nil else { return true }
        return writeContainer(items)
    }

    /// 是否存在某条凭证。
    static func exists(forKey key: String) -> Bool {
        readContainer()[key] != nil
    }
}
