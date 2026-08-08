import Foundation

public enum RemoteServiceState: String, Codable, Equatable, Sendable {
    case stopped
    case starting
    case running
    case failed
}

public struct RemoteAccessConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var allowLAN: Bool
    public var port: UInt16

    public init(enabled: Bool = true, allowLAN: Bool = true, port: UInt16 = 7331) {
        self.enabled = enabled
        self.allowLAN = allowLAN
        self.port = port
    }
}

public struct PairedRemoteDevice: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let createdAt: TimeInterval
    public let lastSeenAt: TimeInterval?

    public init(id: String, name: String, createdAt: TimeInterval, lastSeenAt: TimeInterval? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct RemoteAccessSnapshot: Codable, Equatable, Sendable {
    public let configuration: RemoteAccessConfiguration
    public let state: RemoteServiceState
    public let serviceURLs: [String]
    public let devices: [PairedRemoteDevice]
    public let lastError: String?

    public init(configuration: RemoteAccessConfiguration, state: RemoteServiceState,
                serviceURLs: [String] = [], devices: [PairedRemoteDevice] = [],
                lastError: String? = nil) {
        self.configuration = configuration
        self.state = state
        self.serviceURLs = serviceURLs
        self.devices = devices
        self.lastError = lastError
    }
}

public struct RemotePairingChallenge: Codable, Equatable, Sendable {
    public let id: String
    public let code: String
    public let qrPayload: String
    public let expiresAt: TimeInterval

    public init(id: String, code: String, qrPayload: String, expiresAt: TimeInterval) {
        self.id = id
        self.code = code
        self.qrPayload = qrPayload
        self.expiresAt = expiresAt
    }
}

public struct RemotePairingRequest: Codable, Equatable, Sendable {
    public let code: String
    public let deviceName: String

    public init(code: String, deviceName: String) {
        self.code = code
        self.deviceName = deviceName
    }
}

/// 配对成功时只返回一次。服务端仅保存 token 的 SHA-256 哈希。
public struct RemotePairingCredential: Codable, Equatable, Sendable {
    public let deviceID: String
    public let deviceName: String
    public let token: String
    public let apiVersion: String

    public init(deviceID: String, deviceName: String, token: String, apiVersion: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.token = token
        self.apiVersion = apiVersion
    }
}

public protocol RemoteAccessGateway: Sendable {
    func snapshot() async -> RemoteAccessSnapshot
    func updateConfiguration(_ configuration: RemoteAccessConfiguration) async
    func beginPairing() async throws -> RemotePairingChallenge
    func cancelPairing(challengeID: String) async
    func revokeDevice(id: String) async throws
}
