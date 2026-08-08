import Foundation

public enum PlatformAuthenticationPhase: String, Codable, Equatable, Sendable {
    case notRequired, authenticated, waitingForScan, waitingForConfirmation
    case repairing, needsAttention, signedOut, expired
}

public struct PlatformAuthenticationStatus: Identifiable, Codable, Equatable, Sendable {
    public var id: String { platformID }
    public let platformID: String
    public let displayName: String
    public let phase: PlatformAuthenticationPhase
    public let accountName: String?
    public let message: String?
    public let settingsModuleIdentifier: String?
    public init(platformID: String, displayName: String, phase: PlatformAuthenticationPhase,
                accountName: String? = nil, message: String? = nil,
                settingsModuleIdentifier: String? = nil) {
        self.platformID = platformID; self.displayName = displayName; self.phase = phase
        self.accountName = accountName; self.message = message
        self.settingsModuleIdentifier = settingsModuleIdentifier
    }
}

public struct PlatformAuthenticationChallenge: Codable, Equatable, Sendable {
    public let platformID: String
    public let challengeID: String
    /// QR 内容。HTTP 客户端可以本地渲染，避免把图片编码耦合进协议。
    public let qrPayload: String
    public let expiresAt: TimeInterval
    public init(platformID: String, challengeID: String, qrPayload: String, expiresAt: TimeInterval) {
        self.platformID = platformID; self.challengeID = challengeID
        self.qrPayload = qrPayload; self.expiresAt = expiresAt
    }
}

public struct PlatformAuthenticationPoll: Codable, Equatable, Sendable {
    public let status: PlatformAuthenticationStatus
    public let completed: Bool
    public init(status: PlatformAuthenticationStatus, completed: Bool) {
        self.status = status; self.completed = completed
    }
}

public protocol AuthenticationGateway: Sendable {
    func statuses() async -> [PlatformAuthenticationStatus]
    func beginAuthentication(platformID: String) async throws -> PlatformAuthenticationChallenge
    func pollAuthentication(platformID: String, challengeID: String) async throws -> PlatformAuthenticationPoll
    func signOut(platformID: String) async throws
}
