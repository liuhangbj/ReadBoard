import Foundation

public struct StatisticsOverview: Codable, Equatable, Sendable {
    public var totalSources: Int
    public var enabledSources: Int
    public var totalContent: Int
    public var unreadCount: Int
    public var starredCount: Int
    public var duplicateCount: Int
    public var withFulltext: Int
    public var scored: Int
    public var translated: Int
    public var summarized: Int
    public var tagCount: Int
    public var folderCount: Int
    public var jobTotal: Int
    public var jobFailed: Int
    public var databaseSizeMB: Double

    public init(totalSources: Int = 0, enabledSources: Int = 0, totalContent: Int = 0,
                unreadCount: Int = 0, starredCount: Int = 0, duplicateCount: Int = 0,
                withFulltext: Int = 0, scored: Int = 0, translated: Int = 0,
                summarized: Int = 0, tagCount: Int = 0, folderCount: Int = 0,
                jobTotal: Int = 0, jobFailed: Int = 0, databaseSizeMB: Double = 0) {
        self.totalSources = totalSources; self.enabledSources = enabledSources
        self.totalContent = totalContent; self.unreadCount = unreadCount
        self.starredCount = starredCount; self.duplicateCount = duplicateCount
        self.withFulltext = withFulltext; self.scored = scored; self.translated = translated
        self.summarized = summarized; self.tagCount = tagCount; self.folderCount = folderCount
        self.jobTotal = jobTotal; self.jobFailed = jobFailed; self.databaseSizeMB = databaseSizeMB
    }
}

public struct JobTypeStatistics: Identifiable, Codable, Equatable, Sendable {
    public var id: String { jobType }
    public let jobType: String
    public let succeeded: Int
    public let failed: Int
    public init(jobType: String, succeeded: Int, failed: Int) {
        self.jobType = jobType; self.succeeded = succeeded; self.failed = failed
    }
}

public struct RankedSource: Identifiable, Codable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let count: Int
    public init(name: String, count: Int) { self.name = name; self.count = count }
}

public struct ExportActivity: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(platform)|\(title)|\(time)" }
    public let platform: String
    public let title: String
    public let status: String
    public let time: String
    public init(platform: String, title: String, status: String, time: String) {
        self.platform = platform; self.title = title; self.status = status; self.time = time
    }
}

public struct DashboardStatistics: Codable, Equatable, Sendable {
    public let overview: StatisticsOverview
    public let jobs: [JobTypeStatistics]
    public let topSources: [RankedSource]
    public let exports: [ExportActivity]
    public init(overview: StatisticsOverview, jobs: [JobTypeStatistics],
                topSources: [RankedSource], exports: [ExportActivity]) {
        self.overview = overview; self.jobs = jobs; self.topSources = topSources; self.exports = exports
    }
}

public struct FilterRuleRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public var name: String
    public var field: String
    public var matchType: String
    public var pattern: String
    public var action: String
    public var sourceID: Int64?
    public var enabled: Bool
    public init(id: Int64 = 0, name: String, field: String, matchType: String,
                pattern: String, action: String, sourceID: Int64? = nil, enabled: Bool = true) {
        self.id = id; self.name = name; self.field = field; self.matchType = matchType
        self.pattern = pattern; self.action = action; self.sourceID = sourceID; self.enabled = enabled
    }
}

public struct ContentProcessingFailure: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let contentID: Int64
    public let title: String
    public let sourceName: String
    public let jobType: String
    public let error: String?
    public let consecutiveFailures: Int
    public init(id: Int64, contentID: Int64, title: String, sourceName: String,
                jobType: String, error: String?, consecutiveFailures: Int) {
        self.id = id; self.contentID = contentID; self.title = title; self.sourceName = sourceName
        self.jobType = jobType; self.error = error; self.consecutiveFailures = consecutiveFailures
    }
}

public struct FullTextFailure: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let title: String
    public let sourceName: String
    public let sourceType: String
    public let url: String
    public let error: String
    public let updatedAt: String?
    public init(id: Int64, title: String, sourceName: String, sourceType: String,
                url: String, error: String, updatedAt: String?) {
        self.id = id; self.title = title; self.sourceName = sourceName; self.sourceType = sourceType
        self.url = url; self.error = error; self.updatedAt = updatedAt
    }
}

public struct OperationalProblemCounts: Codable, Equatable, Sendable {
    public let fullTextFailures: Int
    public let persistentFullTextFailures: Int
    public let exportFailures: Int
    public let affectedExportRules: Int
    public init(fullTextFailures: Int = 0, persistentFullTextFailures: Int = 0,
                exportFailures: Int = 0, affectedExportRules: Int = 0) {
        self.fullTextFailures = fullTextFailures
        self.persistentFullTextFailures = persistentFullTextFailures
        self.exportFailures = exportFailures
        self.affectedExportRules = affectedExportRules
    }
}

public protocol AdministrationGateway: Sendable {
    func dashboardStatistics() async -> DashboardStatistics
    func filterRules() async -> [FilterRuleRecord]
    @discardableResult func createFilterRule(_ rule: FilterRuleRecord) async -> Bool
    func updateFilterRule(_ rule: FilterRuleRecord) async
    func deleteFilterRule(id: Int64) async
    func processingFailures() async -> [ContentProcessingFailure]
    @discardableResult func retryProcessingFailure(id: Int64) async -> Bool
    @discardableResult func ignoreProcessingFailure(id: Int64) async -> Bool
    func fullTextFailures(limit: Int) async -> [FullTextFailure]
    func operationalProblemCounts() async -> OperationalProblemCounts
}
