import Foundation

public struct SourcePolicySnapshot: Codable, Equatable, Hashable, Sendable {
    public var autoScore: Bool
    public var autoTranslate: Bool
    public var autoTranscribe: Bool
    public var autoSummarize: Bool

    public init(
        autoScore: Bool = false,
        autoTranslate: Bool = false,
        autoTranscribe: Bool = false,
        autoSummarize: Bool = false
    ) {
        self.autoScore = autoScore
        self.autoTranslate = autoTranslate
        self.autoTranscribe = autoTranscribe
        self.autoSummarize = autoSummarize
    }
}

public struct SourceCatalogItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: Int64
    public let sourceType: String
    public let name: String
    public let identifier: String
    public let enabled: Bool
    public let lastFetchedAt: String?
    public let error: String?
    public let folderID: Int64?
    public let policy: SourcePolicySnapshot
    public let fetchMode: SourceFetchMode
    public let fetchModeAutomatic: Bool
    public let fetchIntervalMinutes: Int
    public let maximumRetainedContent: Int
    public let contentCount: Int
    public let hoursSinceFetch: Double?
    public let transcribable: Bool
    public let availableFetchModes: [SourceFetchMode]
    public let fulltextDisplayName: String?

    public init(
        id: Int64,
        sourceType: String,
        name: String,
        identifier: String,
        enabled: Bool,
        lastFetchedAt: String?,
        error: String?,
        folderID: Int64?,
        policy: SourcePolicySnapshot,
        fetchMode: SourceFetchMode,
        fetchModeAutomatic: Bool,
        fetchIntervalMinutes: Int,
        maximumRetainedContent: Int,
        contentCount: Int = 0,
        hoursSinceFetch: Double? = nil,
        transcribable: Bool,
        availableFetchModes: [SourceFetchMode] = [],
        fulltextDisplayName: String? = nil
    ) {
        self.id = id
        self.sourceType = sourceType
        self.name = name
        self.identifier = identifier
        self.enabled = enabled
        self.lastFetchedAt = lastFetchedAt
        self.error = error
        self.folderID = folderID
        self.policy = policy
        self.fetchMode = fetchMode
        self.fetchModeAutomatic = fetchModeAutomatic
        self.fetchIntervalMinutes = fetchIntervalMinutes
        self.maximumRetainedContent = maximumRetainedContent
        self.contentCount = contentCount
        self.hoursSinceFetch = hoursSinceFetch
        self.transcribable = transcribable
        self.availableFetchModes = availableFetchModes
        self.fulltextDisplayName = fulltextDisplayName
    }

    public var hasError: Bool { !(error?.isEmpty ?? true) }
    public var isStale: Bool { hoursSinceFetch.map { $0 > 48 } ?? true }
}

public struct SourceFolderItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

public struct SourceCatalogSnapshot: Codable, Equatable, Sendable {
    public let sources: [SourceCatalogItem]
    public let folders: [SourceFolderItem]
    public let isSyncing: Bool
    public let isExternalSyncing: Bool
    public let lastSyncMessage: String
    public let updatedAt: TimeInterval

    public init(
        sources: [SourceCatalogItem] = [],
        folders: [SourceFolderItem] = [],
        isSyncing: Bool = false,
        isExternalSyncing: Bool = false,
        lastSyncMessage: String = "",
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.sources = sources
        self.folders = folders
        self.isSyncing = isSyncing
        self.isExternalSyncing = isExternalSyncing
        self.lastSyncMessage = lastSyncMessage
        self.updatedAt = updatedAt
    }
}

public protocol SourceCatalogGateway: Sendable {
    func snapshot() async throws -> SourceCatalogSnapshot
}
