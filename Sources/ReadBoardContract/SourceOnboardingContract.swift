import Foundation

public struct SourceTypeDescriptor: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public enum SourceHistoryScope: String, Codable, CaseIterable, Sendable {
    case recent30Days = "recent_30d"
    case recentYear = "recent_1y"
    case all
}

public struct SourceDiscoveryResult: Codable, Equatable, Sendable {
    public let canonicalIdentifier: String
    public let suggestedName: String
    public let sourceType: String
    public let previewItemCount: Int
    public let fetchMode: SourceFetchMode
    public let fetchModeDisplayName: String
    public let existingSourceID: Int64?

    public init(
        canonicalIdentifier: String,
        suggestedName: String,
        sourceType: String,
        previewItemCount: Int,
        fetchMode: SourceFetchMode,
        fetchModeDisplayName: String,
        existingSourceID: Int64? = nil
    ) {
        self.canonicalIdentifier = canonicalIdentifier
        self.suggestedName = suggestedName
        self.sourceType = sourceType
        self.previewItemCount = previewItemCount
        self.fetchMode = fetchMode
        self.fetchModeDisplayName = fetchModeDisplayName
        self.existingSourceID = existingSourceID
    }
}

public struct SourceCreationRequest: Codable, Equatable, Sendable {
    public let identifier: String
    public let name: String
    public let sourceType: String
    public let folderID: Int64?
    public let policy: SourcePolicySnapshot
    public let fetchMode: SourceFetchMode?
    public let historyScope: SourceHistoryScope?
    public let refreshAfterCreation: Bool

    public init(
        identifier: String,
        name: String,
        sourceType: String,
        folderID: Int64? = nil,
        policy: SourcePolicySnapshot = .init(),
        fetchMode: SourceFetchMode? = nil,
        historyScope: SourceHistoryScope? = nil,
        refreshAfterCreation: Bool = true
    ) {
        self.identifier = identifier
        self.name = name
        self.sourceType = sourceType
        self.folderID = folderID
        self.policy = policy
        self.fetchMode = fetchMode
        self.historyScope = historyScope
        self.refreshAfterCreation = refreshAfterCreation
    }
}

public struct SourceCreationResult: Codable, Equatable, Sendable {
    public let sourceID: Int64
    public let importedContentCount: Int
    public let message: String

    public init(sourceID: Int64, importedContentCount: Int = 0, message: String) {
        self.sourceID = sourceID
        self.importedContentCount = importedContentCount
        self.message = message
    }
}

public struct SourceBatchImportItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let identifier: String
    public let sourceType: String
    public let folderName: String?
    public let policy: SourcePolicySnapshot
    public let fetchMode: SourceFetchMode

    public init(
        id: String = UUID().uuidString,
        name: String,
        identifier: String,
        sourceType: String,
        folderName: String? = nil,
        policy: SourcePolicySnapshot = .init(),
        fetchMode: SourceFetchMode = .summary
    ) {
        self.id = id
        self.name = name
        self.identifier = identifier
        self.sourceType = sourceType
        self.folderName = folderName
        self.policy = policy
        self.fetchMode = fetchMode
    }
}

public struct SourceBatchImportResult: Codable, Equatable, Sendable {
    public let createdSourceIDs: [Int64]
    public let skippedCount: Int
    public let importedContentCount: Int
    public let message: String

    public init(
        createdSourceIDs: [Int64],
        skippedCount: Int,
        importedContentCount: Int,
        message: String
    ) {
        self.createdSourceIDs = createdSourceIDs
        self.skippedCount = skippedCount
        self.importedContentCount = importedContentCount
        self.message = message
    }
}

public struct PlatformSubscriptionCandidate: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let identifier: String
    public let alreadySubscribed: Bool

    public init(id: String, name: String, identifier: String, alreadySubscribed: Bool) {
        self.id = id
        self.name = name
        self.identifier = identifier
        self.alreadySubscribed = alreadySubscribed
    }
}

public enum SourceOnboardingGatewayError: Error, Equatable, Sendable, LocalizedError {
    case invalidIdentifier
    case duplicateSource(Int64?)
    case unsupportedSource(String)
    case authenticationRequired(String)
    case discoveryFailed(String)
    case creationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: return "订阅地址无效"
        case .duplicateSource: return "该源已存在于订阅源列表"
        case .unsupportedSource(let message): return message
        case .authenticationRequired(let message): return message
        case .discoveryFailed(let message): return message
        case .creationFailed(let message): return message
        }
    }
}

public protocol SourceOnboardingGateway: Sendable {
    func supportedSourceTypes() async -> [SourceTypeDescriptor]
    func discover(identifier: String, suggestedType: String?) async throws -> SourceDiscoveryResult
    func create(request: SourceCreationRequest) async throws -> SourceCreationResult
    func importSources(
        items: [SourceBatchImportItem],
        refreshAfterCreation: Bool
    ) async throws -> SourceBatchImportResult
    func platformSubscriptions(platform: String) async throws -> [PlatformSubscriptionCandidate]
    func exportOPML() async -> String
}
