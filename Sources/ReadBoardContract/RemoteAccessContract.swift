import Foundation

public enum RemoteAccessScope: String, Codable, CaseIterable, Hashable, Sendable {
    case readLibrary
    case updateReadingState
    case manageOperations
    case runProcessing
    case manageSources
    case manageAuthentication
    case manageExports
    case manageConfiguration
    case manageMaintenance

    public static var reader: [RemoteAccessScope] {
        [.readLibrary, .updateReadingState]
    }

    public static var fullControl: [RemoteAccessScope] { allCases }
}

public enum RemoteAccessPreset: String, Codable, CaseIterable, Sendable {
    case reader
    case fullControl

    public var scopes: [RemoteAccessScope] {
        switch self {
        case .reader: RemoteAccessScope.reader
        case .fullControl: RemoteAccessScope.fullControl
        }
    }
}

public enum RemoteServiceCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case library
    case processing
    case sourceManagement
    case sourceOnboarding
    case authentication
    case export
    case administration
    case configuration
    case maintenance
}

public struct RemoteServerProfile: Codable, Equatable, Sendable {
    public let apiVersion: String
    public let serverName: String
    public let capabilities: [RemoteServiceCapability]
    public let grantedScopes: [RemoteAccessScope]
    public let transportSecurity: String

    public init(apiVersion: String, serverName: String,
                capabilities: [RemoteServiceCapability],
                grantedScopes: [RemoteAccessScope], transportSecurity: String) {
        self.apiVersion = apiVersion
        self.serverName = serverName
        self.capabilities = capabilities
        self.grantedScopes = grantedScopes
        self.transportSecurity = transportSecurity
    }
}

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
    public let scopes: [RemoteAccessScope]

    public init(id: String, name: String, createdAt: TimeInterval,
                lastSeenAt: TimeInterval? = nil,
                scopes: [RemoteAccessScope] = RemoteAccessScope.reader) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.scopes = scopes
    }
}

public struct RemoteAccessSnapshot: Codable, Equatable, Sendable {
    public let configuration: RemoteAccessConfiguration
    public let state: RemoteServiceState
    public let serviceURLs: [String]
    public let devices: [PairedRemoteDevice]
    public let lastError: String?
    public let passwordConfigured: Bool
    public let certificateFingerprint: String?
    public let bonjourServiceName: String?

    public init(configuration: RemoteAccessConfiguration, state: RemoteServiceState,
                serviceURLs: [String] = [], devices: [PairedRemoteDevice] = [],
                lastError: String? = nil, passwordConfigured: Bool = false,
                certificateFingerprint: String? = nil,
                bonjourServiceName: String? = nil) {
        self.configuration = configuration
        self.state = state
        self.serviceURLs = serviceURLs
        self.devices = devices
        self.lastError = lastError
        self.passwordConfigured = passwordConfigured
        self.certificateFingerprint = certificateFingerprint
        self.bonjourServiceName = bonjourServiceName
    }
}

public struct RemotePairingChallenge: Codable, Equatable, Sendable {
    public let id: String
    public let code: String
    public let qrPayload: String
    public let expiresAt: TimeInterval
    public let scopes: [RemoteAccessScope]

    public init(id: String, code: String, qrPayload: String, expiresAt: TimeInterval,
                scopes: [RemoteAccessScope] = RemoteAccessScope.reader) {
        self.id = id
        self.code = code
        self.qrPayload = qrPayload
        self.expiresAt = expiresAt
        self.scopes = scopes
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

public struct RemotePasswordLoginRequest: Codable, Equatable, Sendable {
    public let password: String
    public let deviceName: String

    public init(password: String, deviceName: String) {
        self.password = password
        self.deviceName = deviceName
    }
}

/// 配对成功时只返回一次。服务端仅保存 token 的 SHA-256 哈希。
public struct RemotePairingCredential: Codable, Equatable, Sendable {
    public let deviceID: String
    public let deviceName: String
    public let token: String
    public let apiVersion: String
    public let scopes: [RemoteAccessScope]

    public init(deviceID: String, deviceName: String, token: String, apiVersion: String,
                scopes: [RemoteAccessScope] = RemoteAccessScope.reader) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.token = token
        self.apiVersion = apiVersion
        self.scopes = scopes
    }
}

public protocol RemoteAccessGateway: Sendable {
    func snapshot() async -> RemoteAccessSnapshot
    func updateConfiguration(_ configuration: RemoteAccessConfiguration) async
    func beginPairing(scopes: [RemoteAccessScope]) async throws -> RemotePairingChallenge
    func cancelPairing(challengeID: String) async
    func revokeDevice(id: String) async throws
    func setAccessPassword(_ password: String) async throws
}
