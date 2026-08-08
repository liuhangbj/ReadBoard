import Foundation
import ReadBoardContract

/// 本地平台凭证仍只保存在服务端。challenge 状态由 actor 隔离，HTTP 响应不会泄漏 cookie/token。
public actor LocalAuthenticationGateway: AuthenticationGateway {
    private var bilibiliPendingSessions: [String: String] = [:]

    public init() {}

    public func statuses() async -> [PlatformAuthenticationStatus] {
        var result = [PlatformAuthenticationStatus(
            platformID: "bilibili",
            displayName: "BiliBili",
            phase: BilibiliAuth.isLoggedIn ? .authenticated : .signedOut,
            accountName: BilibiliAuth.uname,
            message: BilibiliAuth.isLoggedIn ? nil : "尚未登录"
        )]
        let connectorStatuses = await MainActor.run {
            ReadBoardSourceConnectorRegistry.shared.connectorsSupportingAddSource()
        }
        for connector in connectorStatuses {
            let state = await connector.authenticationState()
            let mapped: (PlatformAuthenticationPhase, String?) = switch state {
            case .notRequired: (.notRequired, nil)
            case .authenticated: (.authenticated, nil)
            case .repairing(let message): (.repairing, message)
            case .needsAttention(let message): (.needsAttention, message)
            }
            result.append(PlatformAuthenticationStatus(
                platformID: connector.sourceType,
                displayName: connector.displayName,
                phase: mapped.0,
                message: mapped.1,
                settingsModuleIdentifier: connector.settingsModuleIdentifier
            ))
        }
        return result
    }

    public func beginAuthentication(platformID: String) async throws -> PlatformAuthenticationChallenge {
        if platformID == "bilibili" {
            let (url, key) = try await BilibiliAuth.generateQRCode()
            return PlatformAuthenticationChallenge(
                platformID: platformID, challengeID: key, qrPayload: url,
                expiresAt: Date().addingTimeInterval(180).timeIntervalSince1970)
        }
        let connector = try await connector(for: platformID)
        return try await connector.beginAuthentication()
    }

    public func pollAuthentication(platformID: String, challengeID: String) async throws -> PlatformAuthenticationPoll {
        if platformID == "bilibili" {
            if let sessdata = bilibiliPendingSessions.removeValue(forKey: challengeID) {
                return try await finishBilibili(sessdata: sessdata)
            }
            guard let sessdata = try await BilibiliAuth.pollQRCode(key: challengeID) else {
                return PlatformAuthenticationPoll(
                    status: .init(platformID: platformID, displayName: "BiliBili",
                                  phase: .waitingForScan, message: "请使用 BiliBili App 扫码"),
                    completed: false)
            }
            bilibiliPendingSessions[challengeID] = sessdata
            return try await finishBilibili(sessdata: sessdata)
        }
        return try await connector(for: platformID).pollAuthentication(challengeID: challengeID)
    }

    public func signOut(platformID: String) async throws {
        if platformID == "bilibili" {
            BilibiliAuth.clearAuth()
            return
        }
        try await connector(for: platformID).signOut()
    }

    private func finishBilibili(sessdata: String) async throws -> PlatformAuthenticationPoll {
        let (uid, uname) = try await BilibiliAuth.fetchUserInfo(sessdata: sessdata)
        guard BilibiliAuth.saveAuth(sessdata: sessdata, uid: uid, uname: uname) else {
            throw AuthenticationGatewayError.credentialSaveFailed
        }
        return PlatformAuthenticationPoll(
            status: .init(platformID: "bilibili", displayName: "BiliBili",
                          phase: .authenticated, accountName: uname, message: "登录成功"),
            completed: true)
    }

    private func connector(for platformID: String) async throws -> any ReadBoardSourceConnector {
        guard let value = await MainActor.run(body: {
            ReadBoardSourceConnectorRegistry.shared.connector(for: platformID)
        }) else { throw AuthenticationGatewayError.unknownPlatform(platformID) }
        return value
    }
}

private enum AuthenticationGatewayError: LocalizedError {
    case unknownPlatform(String)
    case credentialSaveFailed
    var errorDescription: String? {
        switch self {
        case .unknownPlatform(let id): "未知平台：\(id)"
        case .credentialSaveFailed: "保存平台登录态失败"
        }
    }
}
