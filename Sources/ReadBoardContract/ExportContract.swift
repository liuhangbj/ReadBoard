import Foundation

public struct ExportRuleDTO: Identifiable, Codable, Equatable, Sendable {
    public struct Criteria: Codable, Equatable, Sendable {
        public var minimumScore: Int?
        public var sourceIDs: [Int64]?
        public var folderIDs: [Int64]?
        public var requireTranslated: Bool
        public var requireTranscribed: Bool
        public var requireSummary: Bool
        public var requireScored: Bool
        public var starredOnly: Bool
        public var readStatus: String?
        public var keywords: [String]?
        public var contentTypes: [String]?
        public var languages: [String]?
        public var platforms: [String]?
        public var excludedSourceIDs: [Int64]?
        public var excludedKeywords: [String]?
        public var publishedAfter: String?
        public var publishedBefore: String?

        public init(
            minimumScore: Int? = nil,
            sourceIDs: [Int64]? = nil,
            folderIDs: [Int64]? = nil,
            requireTranslated: Bool = false,
            requireTranscribed: Bool = false,
            requireSummary: Bool = false,
            requireScored: Bool = false,
            starredOnly: Bool = false,
            readStatus: String? = nil,
            keywords: [String]? = nil,
            contentTypes: [String]? = nil,
            languages: [String]? = nil,
            platforms: [String]? = nil,
            excludedSourceIDs: [Int64]? = nil,
            excludedKeywords: [String]? = nil,
            publishedAfter: String? = nil,
            publishedBefore: String? = nil
        ) {
            self.minimumScore = minimumScore
            self.sourceIDs = sourceIDs
            self.folderIDs = folderIDs
            self.requireTranslated = requireTranslated
            self.requireTranscribed = requireTranscribed
            self.requireSummary = requireSummary
            self.requireScored = requireScored
            self.starredOnly = starredOnly
            self.readStatus = readStatus
            self.keywords = keywords
            self.contentTypes = contentTypes
            self.languages = languages
            self.platforms = platforms
            self.excludedSourceIDs = excludedSourceIDs
            self.excludedKeywords = excludedKeywords
            self.publishedAfter = publishedAfter
            self.publishedBefore = publishedBefore
        }
    }

    public let id: Int64
    public var name: String
    public var enabled: Bool
    public var criteria: Criteria
    public var trigger: String
    public var target: String
    public var lastRunAt: String?
    public var revision: Int
    public var artifact: String
    public var missingPolicy: String
    public var outputFormat: String
    public var subfolderTemplate: String
    public var titleTemplate: String
    public var writePolicy: String
    public var historyScope: String
    public var frontmatterFields: [String]?
    public var attachmentsPolicy: String
    public var createdAt: String?
    public var useTranslatedTitle: Bool
    public var frontmatterLabels: [String: String]?
    public var historyAfter: String?
    public var scheduleInterval: String

    public init(
        id: Int64 = 0,
        name: String = "",
        enabled: Bool = true,
        criteria: Criteria = Criteria(),
        trigger: String = "manual",
        target: String = "obsidian",
        lastRunAt: String? = nil,
        revision: Int = 1,
        artifact: String = "original",
        missingPolicy: String = "wait",
        outputFormat: String = "markdown",
        subfolderTemplate: String = "",
        titleTemplate: String = "{title}-{id}",
        writePolicy: String = "overwrite",
        historyScope: String = "all",
        frontmatterFields: [String]? = nil,
        attachmentsPolicy: String = "remote",
        createdAt: String? = nil,
        useTranslatedTitle: Bool = false,
        frontmatterLabels: [String: String]? = nil,
        historyAfter: String? = nil,
        scheduleInterval: String = "daily"
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.criteria = criteria
        self.trigger = trigger
        self.target = target
        self.lastRunAt = lastRunAt
        self.revision = revision
        self.artifact = artifact
        self.missingPolicy = missingPolicy
        self.outputFormat = outputFormat
        self.subfolderTemplate = subfolderTemplate
        self.titleTemplate = titleTemplate
        self.writePolicy = writePolicy
        self.historyScope = historyScope
        self.frontmatterFields = frontmatterFields
        self.attachmentsPolicy = attachmentsPolicy
        self.createdAt = createdAt
        self.useTranslatedTitle = useTranslatedTitle
        self.frontmatterLabels = frontmatterLabels
        self.historyAfter = historyAfter
        self.scheduleInterval = scheduleInterval
    }
}

public struct ExportRuleStatsDTO: Codable, Equatable, Sendable {
    public let delivered: Int
    public let failed: Int

    public init(delivered: Int, failed: Int) {
        self.delivered = delivered
        self.failed = failed
    }
}

public struct ExportRulePreviewDTO: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public let contentID: Int64
        public let title: String
        public let markdown: String?
        public let destination: String?
        public let issue: String?

        public init(
            contentID: Int64,
            title: String,
            markdown: String?,
            destination: String?,
            issue: String?
        ) {
            self.contentID = contentID
            self.title = title
            self.markdown = markdown
            self.destination = destination
            self.issue = issue
        }
    }

    public let matchingCount: Int
    public let samples: [Sample]

    public init(matchingCount: Int, samples: [Sample]) {
        self.matchingCount = matchingCount
        self.samples = samples
    }
}

public struct ExportExecutionResult: Codable, Equatable, Sendable {
    public let affectedRuleCount: Int
    public let message: String

    public init(affectedRuleCount: Int, message: String) {
        self.affectedRuleCount = affectedRuleCount
        self.message = message
    }
}

public enum ExportGatewayError: Error, Equatable, Sendable, LocalizedError {
    case invalidRule
    case ruleNotFound(Int64)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRule: return "导出规则无效"
        case .ruleNotFound: return "导出规则不存在或已被删除"
        case .operationFailed(let message): return message
        }
    }
}

public protocol ExportGateway: Sendable {
    func rules() async throws -> [ExportRuleDTO]
    func save(rule: ExportRuleDTO) async throws -> ExportRuleDTO
    func delete(ruleID: Int64) async throws
    func stats(ruleID: Int64) async throws -> ExportRuleStatsDTO
    func preview(rule: ExportRuleDTO) async throws -> ExportRulePreviewDTO
    func run(ruleID: Int64) async throws -> ExportExecutionResult
    func forceExport(contentID: Int64) async throws -> ExportExecutionResult
}
