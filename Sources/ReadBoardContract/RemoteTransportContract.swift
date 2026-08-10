import Foundation

public enum ReadBoardRemoteAPI {
    public static let version = "1"
    public static let versionHeader = "X-ReadBoard-API-Version"
}

public struct RemoteAcknowledgement: Codable, Equatable, Sendable {
    public let succeeded: Bool
    public init(succeeded: Bool = true) { self.succeeded = succeeded }
}

public struct RemoteBoolValue: Codable, Equatable, Sendable {
    public let value: Bool
    public init(_ value: Bool) { self.value = value }
}

public struct RemoteStringValue: Codable, Equatable, Sendable {
    public let value: String
    public init(_ value: String) { self.value = value }
}

public struct RemoteNameRequest: Codable, Equatable, Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}

public struct RemoteStringIDRequest: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct RemoteIntIDRequest: Codable, Equatable, Sendable {
    public let id: Int
    public init(id: Int) { self.id = id }
}

public struct RemoteInt64IDRequest: Codable, Equatable, Sendable {
    public let id: Int64
    public init(id: Int64) { self.id = id }
}

public struct RemoteContentStateRequest: Codable, Equatable, Sendable {
    public let contentID: Int64
    public let value: Bool
    public init(contentID: Int64, value: Bool) { self.contentID = contentID; self.value = value }
}

public struct RemoteContentIDRequest: Codable, Equatable, Sendable {
    public let contentID: Int64
    public init(contentID: Int64) { self.contentID = contentID }
}

public struct RemoteRuntimeSnapshotRequest: Codable, Equatable, Sendable {
    public let refreshCounts: Bool
    public init(refreshCounts: Bool) { self.refreshCounts = refreshCounts }
}

public struct RemoteProcessingStatusRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public init(requestID: String) { self.requestID = requestID }
}

public struct RemoteSourceRenameRequest: Codable, Equatable, Sendable {
    public let scope: SourceScope
    public let name: String
    public init(scope: SourceScope, name: String) { self.scope = scope; self.name = name }
}

public struct RemoteSourceAssignmentRequest: Codable, Equatable, Sendable {
    public let sourceID: Int64
    public let folderID: Int64?
    public init(sourceID: Int64, folderID: Int64?) { self.sourceID = sourceID; self.folderID = folderID }
}

public struct RemoteSourcePolicyRequest: Codable, Equatable, Sendable {
    public let scope: SourceScope
    public let key: SourcePolicyKey
    public let enabled: Bool
    public init(scope: SourceScope, key: SourcePolicyKey, enabled: Bool) {
        self.scope = scope; self.key = key; self.enabled = enabled
    }
}

public struct RemoteSourceBackfillRequest: Codable, Equatable, Sendable {
    public let scope: SourceScope
    public let key: SourcePolicyKey?
    public init(scope: SourceScope, key: SourcePolicyKey?) { self.scope = scope; self.key = key }
}

public struct RemoteSourceOperationRequest: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct RemoteSourceSyncJobRequest: Codable, Equatable, Sendable {
    public let scope: SourceScope?
    public init(scope: SourceScope?) { self.scope = scope }
}

public struct RemoteSourceFetchModeRequest: Codable, Equatable, Sendable {
    public let scope: SourceScope
    public let mode: SourceFetchMode
    public init(scope: SourceScope, mode: SourceFetchMode) { self.scope = scope; self.mode = mode }
}

public struct RemoteSourceIntervalRequest: Codable, Equatable, Sendable {
    public let scope: SourceScope
    public let minutes: Int
    public init(scope: SourceScope, minutes: Int) { self.scope = scope; self.minutes = minutes }
}

public struct RemoteSourceEnabledRequest: Codable, Equatable, Sendable {
    public let sourceID: Int64
    public let enabled: Bool
    public init(sourceID: Int64, enabled: Bool) { self.sourceID = sourceID; self.enabled = enabled }
}

public struct RemoteSourceRetentionRequest: Codable, Equatable, Sendable {
    public let sourceID: Int64
    public let count: Int
    public init(sourceID: Int64, count: Int) { self.sourceID = sourceID; self.count = count }
}

public struct RemoteSourceRefetchRequest: Codable, Equatable, Sendable {
    public let scope: SourceScope
    public let fullHistory: Bool
    public init(scope: SourceScope, fullHistory: Bool) { self.scope = scope; self.fullHistory = fullHistory }
}

public struct RemoteSourceDiscoveryRequest: Codable, Equatable, Sendable {
    public let identifier: String
    public let suggestedType: String?
    public init(identifier: String, suggestedType: String?) {
        self.identifier = identifier; self.suggestedType = suggestedType
    }
}

public struct RemoteSourceImportRequest: Codable, Equatable, Sendable {
    public let items: [SourceBatchImportItem]
    public let refreshAfterCreation: Bool
    public init(items: [SourceBatchImportItem], refreshAfterCreation: Bool) {
        self.items = items; self.refreshAfterCreation = refreshAfterCreation
    }
}

public struct RemotePlatformRequest: Codable, Equatable, Sendable {
    public let platformID: String
    public init(platformID: String) { self.platformID = platformID }
}

public struct RemoteAuthenticationPollRequest: Codable, Equatable, Sendable {
    public let platformID: String
    public let challengeID: String
    public init(platformID: String, challengeID: String) {
        self.platformID = platformID; self.challengeID = challengeID
    }
}

public struct RemoteFilterRuleIDRequest: Codable, Equatable, Sendable {
    public let id: Int64
    public init(id: Int64) { self.id = id }
}

public struct RemoteLimitRequest: Codable, Equatable, Sendable {
    public let limit: Int
    public init(limit: Int) { self.limit = limit }
}

public struct RemoteConfigurationFlagRequest: Codable, Equatable, Sendable {
    public let id: String
    public let enabled: Bool
    public init(id: String, enabled: Bool) { self.id = id; self.enabled = enabled }
}

public struct RemoteMoveRequest: Codable, Equatable, Sendable {
    public let from: Int
    public let to: Int
    public init(from: Int, to: Int) { self.from = from; self.to = to }
}

public struct RemoteLLMModelsRequest: Codable, Equatable, Sendable {
    public let profileID: Int
    public let endpoint: String
    public let apiKey: String?
    public init(profileID: Int, endpoint: String, apiKey: String?) {
        self.profileID = profileID; self.endpoint = endpoint; self.apiKey = apiKey
    }
}

public struct RemoteDependencyPathRequest: Codable, Equatable, Sendable {
    public let id: String
    public let path: String
    public init(id: String, path: String) { self.id = id; self.path = path }
}

public struct RemoteExportRuleIDRequest: Codable, Equatable, Sendable {
    public let ruleID: Int64
    public init(ruleID: Int64) { self.ruleID = ruleID }
}
