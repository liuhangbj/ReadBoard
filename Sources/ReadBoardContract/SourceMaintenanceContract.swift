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
    case summarize = "auto_summarize"
    case translate = "auto_translate"
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

public enum SourceOperationJobKind: String, Codable, Equatable, Sendable {
    case processingBackfill
    case sourceSync
    case fulltextRefetch
}

public enum SourceOperationJobPhase: String, Codable, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .queued, .running: false
        case .succeeded, .failed, .cancelled: true
        }
    }
}

/// 跨本地/远程边界的长任务快照。提交接口必须立即返回该值，客户端随后按 id 查询，
/// 不能让一个 HTTP 请求等待整批历史内容处理完成。
public struct SourceOperationJobSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: SourceOperationJobKind
    public let scope: SourceScope?
    public let phase: SourceOperationJobPhase
    public let progress: Double?
    public let message: String
    public let affectedCount: Int?
    public let startedAt: TimeInterval
    public let finishedAt: TimeInterval?

    public init(
        id: String = UUID().uuidString,
        kind: SourceOperationJobKind,
        scope: SourceScope?,
        phase: SourceOperationJobPhase,
        progress: Double? = nil,
        message: String,
        affectedCount: Int? = nil,
        startedAt: TimeInterval = Date().timeIntervalSince1970,
        finishedAt: TimeInterval? = nil
    ) {
        self.id = id
        self.kind = kind
        self.scope = scope
        self.phase = phase
        self.progress = progress
        self.message = message
        self.affectedCount = affectedCount
        self.startedAt = startedAt
        self.finishedAt = finishedAt
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
    func syncSettings() async throws -> SourceSyncSettings
    func updateSyncSettings(_ settings: SourceSyncSettings) async throws
    func createFolder(name: String) async throws -> SourceMaintenanceResult
    func syncAll() async throws -> SourceMaintenanceResult
    func rename(scope: SourceScope, name: String) async throws -> SourceMaintenanceResult
    func remove(scope: SourceScope) async throws -> SourceMaintenanceResult
    func assignSource(sourceID: Int64, folderID: Int64?) async throws
    func sync(scope: SourceScope) async throws -> SourceMaintenanceResult
    func setPolicy(scope: SourceScope, key: SourcePolicyKey, enabled: Bool) async throws
    func backfillProcessing(scope: SourceScope, key: SourcePolicyKey?) async throws -> SourceMaintenanceResult
    func submitBackfillProcessing(scope: SourceScope, key: SourcePolicyKey?) async throws -> SourceOperationJobSnapshot
    func submitSourceSync(scope: SourceScope?) async throws -> SourceOperationJobSnapshot
    func submitFulltextRefetch(scope: SourceScope, fullHistory: Bool) async throws -> SourceOperationJobSnapshot
    func sourceOperationStatus(id: String) async throws -> SourceOperationJobSnapshot
    func cancelSourceOperation(id: String) async
    func setFetchMode(scope: SourceScope, mode: SourceFetchMode) async throws
    func redetectFetchMode(scope: SourceScope) async throws
    func setFetchInterval(scope: SourceScope, minutes: Int) async throws
    func setEnabled(sourceID: Int64, enabled: Bool) async throws
    func setMaximumRetainedContent(scope: SourceScope, count: Int) async throws
    func refetchFulltext(scope: SourceScope, fullHistory: Bool) async throws -> SourceMaintenanceResult
    func retryFulltext(contentID: Int64) async throws -> SourceMaintenanceResult
}

public extension SourceManagementGateway {
    /// 旧 gateway 的兼容桥。新本地和远程实现必须覆盖它并立即返回 queued/running。
    func submitBackfillProcessing(
        scope: SourceScope,
        key: SourcePolicyKey?
    ) async throws -> SourceOperationJobSnapshot {
        let result = try await backfillProcessing(scope: scope, key: key)
        return SourceOperationJobSnapshot(
            kind: .processingBackfill,
            scope: scope,
            phase: .succeeded,
            message: result.message,
            affectedCount: result.affectedCount,
            finishedAt: Date().timeIntervalSince1970)
    }

    func submitSourceSync(scope: SourceScope?) async throws -> SourceOperationJobSnapshot {
        let result: SourceMaintenanceResult
        if let scope {
            result = try await sync(scope: scope)
        } else {
            result = try await syncAll()
        }
        return SourceOperationJobSnapshot(
            kind: .sourceSync,
            scope: scope,
            phase: .succeeded,
            message: result.message,
            affectedCount: result.affectedCount,
            finishedAt: Date().timeIntervalSince1970)
    }

    func submitFulltextRefetch(
        scope: SourceScope,
        fullHistory: Bool
    ) async throws -> SourceOperationJobSnapshot {
        let result = try await refetchFulltext(scope: scope, fullHistory: fullHistory)
        return SourceOperationJobSnapshot(
            kind: .fulltextRefetch,
            scope: scope,
            phase: .succeeded,
            message: result.message,
            affectedCount: result.affectedCount,
            finishedAt: Date().timeIntervalSince1970)
    }

    func sourceOperationStatus(id: String) async throws -> SourceOperationJobSnapshot {
        throw SourceManagementGatewayError.operationFailed("长任务不存在或已过期")
    }

    func cancelSourceOperation(id: String) async {}
}
