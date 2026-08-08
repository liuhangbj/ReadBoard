import CryptoKit
import Darwin
import Foundation
import ReadBoardContract

struct StoredRemoteDevice: Codable, Equatable, Sendable {
    let id: String
    var name: String
    let tokenHash: String
    let createdAt: TimeInterval
    var lastSeenAt: TimeInterval?
    var scopes: [RemoteAccessScope]

    var publicValue: PairedRemoteDevice {
        PairedRemoteDevice(id: id, name: name, createdAt: createdAt,
                           lastSeenAt: lastSeenAt, scopes: scopes)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, tokenHash, createdAt, lastSeenAt, scopes
    }

    init(id: String, name: String, tokenHash: String, createdAt: TimeInterval,
         lastSeenAt: TimeInterval?, scopes: [RemoteAccessScope]) {
        self.id = id; self.name = name; self.tokenHash = tokenHash
        self.createdAt = createdAt; self.lastSeenAt = lastSeenAt; self.scopes = scopes
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        tokenHash = try values.decode(String.self, forKey: .tokenHash)
        createdAt = try values.decode(TimeInterval.self, forKey: .createdAt)
        lastSeenAt = try values.decodeIfPresent(TimeInterval.self, forKey: .lastSeenAt)
        scopes = try values.decodeIfPresent([RemoteAccessScope].self, forKey: .scopes)
            ?? RemoteAccessScope.fullControl
    }
}

actor RemoteDeviceStore {
    private let fileURL: URL
    private var loaded = false
    private var records: [StoredRemoteDevice] = []

    init(fileURL: URL = URL(fileURLWithPath: Database.dataDirectory)
        .appendingPathComponent("remote-devices.json")) {
        self.fileURL = fileURL
    }

    func devices() -> [PairedRemoteDevice] {
        loadIfNeeded()
        return records.sorted { $0.createdAt > $1.createdAt }.map(\.publicValue)
    }

    func issue(deviceName: String,
               scopes: [RemoteAccessScope] = RemoteAccessScope.reader) throws -> RemotePairingCredential {
        loadIfNeeded()
        let token = Self.randomToken()
        let name = Self.sanitizedName(deviceName)
        let record = StoredRemoteDevice(id: UUID().uuidString, name: name,
            tokenHash: Self.hash(token), createdAt: Date().timeIntervalSince1970,
            lastSeenAt: nil, scopes: Self.normalizedScopes(scopes))
        records.append(record)
        try persist()
        return RemotePairingCredential(deviceID: record.id, deviceName: record.name,
            token: token, apiVersion: ReadBoardAPI.version, scopes: record.scopes)
    }

    func validate(token: String) -> Bool {
        authorization(token: token) != nil
    }

    func authorization(token: String) -> [RemoteAccessScope]? {
        loadIfNeeded()
        guard !token.isEmpty else { return nil }
        let digest = Self.hash(token)
        guard let index = records.firstIndex(where: { Self.constantTimeEqual($0.tokenHash, digest) }) else {
            return nil
        }
        let now = Date().timeIntervalSince1970
        if records[index].lastSeenAt.map({ now - $0 > 60 }) ?? true {
            records[index].lastSeenAt = now
            try? persist()
        }
        return records[index].scopes
    }

    func revoke(id: String) throws {
        loadIfNeeded()
        let previous = records
        records.removeAll { $0.id == id }
        guard records != previous else { return }
        do {
            try persist()
        } catch {
            records = previous
            throw error
        }
    }

    /// 兼容上一版单一 token：迁移为哈希记录后删除服务端明文。
    func migrateLegacyToken(_ token: String?) throws {
        loadIfNeeded()
        guard let token, !token.isEmpty else { return }
        let digest = Self.hash(token)
        if !records.contains(where: { Self.constantTimeEqual($0.tokenHash, digest) }) {
            let previous = records
            records.append(StoredRemoteDevice(id: UUID().uuidString,
                name: "旧版访问令牌", tokenHash: digest,
                createdAt: Date().timeIntervalSince1970, lastSeenAt: nil,
                scopes: RemoteAccessScope.fullControl))
            do {
                try persist()
            } catch {
                records = previous
                throw error
            }
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let values = try? JSONDecoder().decode([StoredRemoteDevice].self, from: data) else {
            records = []
            return
        }
        records = values
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(records)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }

    private static func sanitizedName(_ raw: String) -> String {
        let value = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未命名设备" : String(value.prefix(80))
    }

    private static func randomToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func normalizedScopes(_ scopes: [RemoteAccessScope]) -> [RemoteAccessScope] {
        let values = scopes.isEmpty ? RemoteAccessScope.reader : scopes
        return RemoteAccessScope.allCases.filter { values.contains($0) }
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

actor RemotePairingService {
    private struct ActiveChallenge: Sendable {
        let id: String
        let code: String
        let expiresAt: TimeInterval
        var failedAttempts: Int
        let scopes: [RemoteAccessScope]
    }

    private let deviceStore: RemoteDeviceStore
    private var active: ActiveChallenge?

    init(deviceStore: RemoteDeviceStore) { self.deviceStore = deviceStore }

    func begin(serviceURLs: [String], scopes: [RemoteAccessScope] = RemoteAccessScope.reader,
               lifetime: TimeInterval = 300) -> RemotePairingChallenge {
        let id = UUID().uuidString
        let code = Self.randomCode()
        let expiresAt = Date().addingTimeInterval(lifetime).timeIntervalSince1970
        let grantedScopes = RemoteAccessScope.allCases.filter { scopes.contains($0) }
        active = ActiveChallenge(id: id, code: code, expiresAt: expiresAt,
                                 failedAttempts: 0, scopes: grantedScopes)
        let payload = Self.payload(serviceURLs: serviceURLs, code: code,
                                   expiresAt: expiresAt, scopes: grantedScopes)
        return RemotePairingChallenge(id: id, code: code, qrPayload: payload,
                                      expiresAt: expiresAt, scopes: grantedScopes)
    }

    func cancel(id: String) {
        if active?.id == id { active = nil }
    }

    func redeem(_ request: RemotePairingRequest) async throws -> RemotePairingCredential {
        guard var challenge = active else { throw RemotePairingError.noActiveChallenge }
        guard challenge.expiresAt > Date().timeIntervalSince1970 else {
            active = nil
            throw RemotePairingError.expired
        }
        guard challenge.failedAttempts < 5 else {
            active = nil
            throw RemotePairingError.tooManyAttempts
        }
        guard Self.normalized(request.code) == challenge.code else {
            challenge.failedAttempts += 1
            active = challenge
            throw RemotePairingError.invalidCode
        }
        active = nil
        return try await deviceStore.issue(deviceName: request.deviceName, scopes: challenge.scopes)
    }

    private static func randomCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    private static func normalized(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func payload(serviceURLs: [String], code: String,
                                expiresAt: TimeInterval, scopes: [RemoteAccessScope]) -> String {
        var components = URLComponents()
        components.scheme = "readboard"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "servers", value: serviceURLs.joined(separator: ",")),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "expires", value: String(Int(expiresAt))),
            URLQueryItem(name: "version", value: ReadBoardAPI.version),
            URLQueryItem(name: "scopes", value: scopes.map(\.rawValue).joined(separator: ",")),
        ]
        return components.string ?? ""
    }
}

enum RemotePairingError: LocalizedError {
    case noActiveChallenge, expired, invalidCode, tooManyAttempts, serviceUnavailable

    var errorDescription: String? {
        switch self {
        case .noActiveChallenge: "当前没有可用的配对请求"
        case .expired: "配对码已过期，请重新生成"
        case .invalidCode: "配对码不正确"
        case .tooManyAttempts: "配对尝试次数过多，请重新生成配对码"
        case .serviceUnavailable: "远程访问服务尚未运行"
        }
    }
}

enum RemoteAccessNetwork {
    static func localIPv4Addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var values: [String] = []
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let address = item.pointee.ifa_addr
            guard address?.pointee.sa_family == UInt8(AF_INET),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address!.pointee.sa_len)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let value = String(decoding: host.prefix { $0 != 0 }
                .map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !values.contains(value) { values.append(value) }
        }
        return values.sorted()
    }
}
