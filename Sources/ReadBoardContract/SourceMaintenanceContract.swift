import Foundation

public enum SourceScopeKind: String, Codable, Sendable {
    case source
    case folder
}

public struct SourceScope: Codable, Equatable, Sendable {
    public let kind: SourceScopeKind
    public let id: Int64

    public init(kind: SourceScopeKind, id: Int64) {
        self.kind = kind
        self.id = id
    }
}

public enum SourcePolicyKey: String, Codable, CaseIterable, Sendable {
    case score = "auto_score"
    case translate = "auto_translate"
    case summarize = "auto_summarize"
    case transcribe = "auto_transcribe"
}

public enum SourceFetchMode: String, Codable, CaseIterable, Sendable {
    case automatic = "auto"
    case feedFull = "feed_full"
    case defuddle
    case youtubeSubtitle = "youtube_subtitle"
    case bilibiliSubtitle = "bilibili_subtitle"
    case externalFulltext = "external_fulltext"
    case summary
}

public struct SourceMaintenanceResult: Codable, Equatable, Sendable {
    public let affectedCount: Int
    public let message: String

    public init(affectedCount: Int = 0, message: String) {
        self.affectedCount = affectedCount
        self.message = message
    }
}

public struct SourceSyncSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var intervalMinutes: Int

    public init(enabled: Bool, intervalMinutes: Int) {
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
    }
}

public enum SourceManagementGatewayError: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest
    case sourceNotFound(Int64)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "订阅源操作无效"
        case .sourceNotFound: return "订阅源不存在或已被删除"
        case .operationFailed(let message): return message
        }
    }
}

/// 订阅源和文件夹的命令端口。列表快照将在下一阶段接入，命令先统一从 UI 移出。
public protocol SourceManagementGateway: Sendable {
    func syncSettings() async -> SourceSyncSettings
    func updateSyncSettings(_ settings: SourceSyncSettings) async throws
    func createFolder(name: String) async throws -> SourceMaintenanceResult
    func syncAll() async throws -> SourceMaintenanceResult
    func rename(scope: SourceScope, name: String) async throws -> SourceMaintenanceResult
    func remove(scope: SourceScope) async throws -> SourceMaintenanceResult
    func assignSource(sourceID: Int64, folderID: Int64?) async throws
    func sync(scope: SourceScope) async throws -> SourceMaintenanceResult
    func setPolicy(scope: SourceScope, key: SourcePolicyKey, enabled: Bool) async throws
    func backfillProcessing(scope: SourceScope, key: SourcePolicyKey?) async throws -> SourceMaintenanceResult
    func setFetchMode(scope: SourceScope, mode: SourceFetchMode) async throws
    func redetectFetchMode(scope: SourceScope) async throws
    func setFetchInterval(scope: SourceScope, minutes: Int) async throws
    func setEnabled(sourceID: Int64, enabled: Bool) async throws
    func setMaximumRetainedContent(sourceID: Int64, count: Int) async throws
    func refetchFulltext(scope: SourceScope, fullHistory: Bool) async throws -> SourceMaintenanceResult
    func retryFulltext(contentID: Int64) async throws -> SourceMaintenanceResult
}
