import CommonCrypto
import Foundation
import ReadBoardContract

struct StoredRemotePassword: Codable, Equatable, Sendable {
    let salt: String
    let derivedKey: String
    let iterations: UInt32
    let updatedAt: TimeInterval
}

actor RemotePasswordService {
    private let fileURL: URL
    private let deviceStore: RemoteDeviceStore
    private let defaultIterations: UInt32
    private var loaded = false
    private var record: StoredRemotePassword?
    private var failedAttempts: [TimeInterval] = []
    private var blockedUntil: TimeInterval?

    init(deviceStore: RemoteDeviceStore,
         fileURL: URL = URL(fileURLWithPath: Database.dataDirectory)
            .appendingPathComponent("remote-password.json"),
         iterations: UInt32 = 600_000) {
        self.deviceStore = deviceStore
        self.fileURL = fileURL
        defaultIterations = iterations
    }

    func isConfigured() -> Bool {
        loadIfNeeded()
        return record != nil
    }

    func setPassword(_ password: String) throws {
        guard password.count >= 10, password.count <= 256 else {
            throw RemotePasswordError.invalidPasswordLength
        }
        let salt = Self.randomBytes(count: 16)
        let derived = try Self.derive(password: password, salt: salt,
                                      iterations: defaultIterations)
        let value = StoredRemotePassword(salt: salt.base64EncodedString(),
            derivedKey: derived.base64EncodedString(), iterations: defaultIterations,
            updatedAt: Date().timeIntervalSince1970)
        try persist(value)
        record = value
        loaded = true
        failedAttempts = []
        blockedUntil = nil
    }

    func login(_ request: RemotePasswordLoginRequest) async throws -> RemotePairingCredential {
        loadIfNeeded()
        guard let record,
              let salt = Data(base64Encoded: record.salt),
              let expected = Data(base64Encoded: record.derivedKey) else {
            throw RemotePasswordError.notConfigured
        }
        let now = Date().timeIntervalSince1970
        if let blockedUntil, blockedUntil > now {
            throw RemotePasswordError.rateLimited(retryAfter: Int(blockedUntil - now) + 1)
        }
        failedAttempts.removeAll { now - $0 > 300 }
        let actual = try Self.derive(password: request.password, salt: salt,
                                     iterations: record.iterations)
        guard Self.constantTimeEqual(actual, expected) else {
            failedAttempts.append(now)
            if failedAttempts.count >= 5 {
                blockedUntil = now + 300
                failedAttempts = []
                throw RemotePasswordError.rateLimited(retryAfter: 300)
            }
            throw RemotePasswordError.invalidCredentials
        }
        failedAttempts = []
        blockedUntil = nil
        return try await deviceStore.issue(deviceName: request.deviceName,
                                           scopes: RemoteAccessScope.fullControl)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        record = try? JSONDecoder().decode(StoredRemotePassword.self, from: data)
    }

    private func persist(_ value: StoredRemotePassword) throws {
        let data = try JSONEncoder().encode(value)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: fileURL.path)
    }

    static func derive(password: String, salt: Data, iterations: UInt32) throws -> Data {
        let passwordBytes = Array(password.utf8)
        var output = Data(count: 32)
        let status: Int32 = output.withUnsafeMutableBytes { outputBuffer in
            salt.withUnsafeBytes { saltBuffer in
                passwordBytes.withUnsafeBytes { passwordBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordBuffer.count,
                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        outputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        outputBuffer.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw RemotePasswordError.derivationFailed }
        return output
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

enum RemotePasswordError: LocalizedError, Equatable {
    case notConfigured
    case invalidPasswordLength
    case invalidCredentials
    case rateLimited(retryAfter: Int)
    case derivationFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured: "服务端尚未设置远程访问密码"
        case .invalidPasswordLength: "访问密码需要 10 至 256 个字符"
        case .invalidCredentials: "访问密码不正确"
        case .rateLimited(let seconds): "登录尝试过多，请在 \(seconds) 秒后重试"
        case .derivationFailed: "无法安全处理访问密码"
        }
    }
}
