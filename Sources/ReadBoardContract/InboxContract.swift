import Foundation

public enum InboxContentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case article
    case podcast
    case video

    public var id: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = InboxContentKind(rawValue: value) ?? .article
    }
}

public struct InboxProcessingTargets: Codable, Equatable, Sendable {
    public var fulltext: Bool
    public var score: Bool
    public var summary: Bool
    public var translate: Bool
    public var transcribe: Bool

    public init(
        fulltext: Bool = true,
        score: Bool = false,
        summary: Bool = false,
        translate: Bool = false,
        transcribe: Bool = false
    ) {
        self.fulltext = fulltext
        self.score = score
        self.summary = summary
        self.translate = translate
        self.transcribe = transcribe
    }

    private enum CodingKeys: String, CodingKey {
        case fulltext, score, summary, translate, transcribe
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fulltext = try values.decodeIfPresent(Bool.self, forKey: .fulltext) ?? true
        score = try values.decodeIfPresent(Bool.self, forKey: .score) ?? false
        summary = try values.decodeIfPresent(Bool.self, forKey: .summary) ?? false
        translate = try values.decodeIfPresent(Bool.self, forKey: .translate) ?? false
        transcribe = try values.decodeIfPresent(Bool.self, forKey: .transcribe) ?? false
    }
}

public struct InboxConfiguration: Codable, Equatable, Sendable {
    public var articleTargets: InboxProcessingTargets
    public var podcastTargets: InboxProcessingTargets
    public var videoTargets: InboxProcessingTargets
    public var markNewItemsUnread: Bool
    public var allowAutomaticExport: Bool

    public init(
        articleTargets: InboxProcessingTargets = .init(fulltext: true),
        podcastTargets: InboxProcessingTargets = .init(fulltext: true),
        videoTargets: InboxProcessingTargets = .init(fulltext: true),
        markNewItemsUnread: Bool = true,
        allowAutomaticExport: Bool = false
    ) {
        self.articleTargets = articleTargets
        self.podcastTargets = podcastTargets
        self.videoTargets = videoTargets
        self.markNewItemsUnread = markNewItemsUnread
        self.allowAutomaticExport = allowAutomaticExport
    }

    public func targets(for kind: InboxContentKind) -> InboxProcessingTargets {
        switch kind {
        case .automatic, .article: articleTargets
        case .podcast: podcastTargets
        case .video: videoTargets
        }
    }

    private enum CodingKeys: String, CodingKey {
        case articleTargets, podcastTargets, videoTargets
        case markNewItemsUnread, allowAutomaticExport
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        articleTargets = try values.decodeIfPresent(
            InboxProcessingTargets.self, forKey: .articleTargets) ?? .init(fulltext: true)
        podcastTargets = try values.decodeIfPresent(
            InboxProcessingTargets.self, forKey: .podcastTargets) ?? .init(fulltext: true)
        videoTargets = try values.decodeIfPresent(
            InboxProcessingTargets.self, forKey: .videoTargets) ?? .init(fulltext: true)
        markNewItemsUnread = try values.decodeIfPresent(
            Bool.self, forKey: .markNewItemsUnread) ?? true
        allowAutomaticExport = try values.decodeIfPresent(
            Bool.self, forKey: .allowAutomaticExport) ?? false
    }
}

public struct InboxImportRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let url: String
    public let suggestedKind: InboxContentKind

    public init(
        requestID: String = UUID().uuidString,
        url: String,
        suggestedKind: InboxContentKind = .automatic
    ) {
        self.requestID = requestID
        self.url = url
        self.suggestedKind = suggestedKind
    }
}

public enum InboxImportDisposition: String, Codable, Sendable {
    case created
    case existing

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = InboxImportDisposition(rawValue: value) ?? .existing
    }
}

public struct InboxImportResult: Codable, Equatable, Sendable {
    public let requestID: String
    public let contentID: Int64
    public let disposition: InboxImportDisposition
    public let kind: InboxContentKind
    public let title: String
    public let message: String

    public init(
        requestID: String,
        contentID: Int64,
        disposition: InboxImportDisposition,
        kind: InboxContentKind,
        title: String,
        message: String
    ) {
        self.requestID = requestID
        self.contentID = contentID
        self.disposition = disposition
        self.kind = kind
        self.title = title
        self.message = message
    }
}

public struct InboxRetargetResult: Codable, Equatable, Sendable {
    public let affectedCount: Int
    public let message: String

    public init(affectedCount: Int, message: String) {
        self.affectedCount = affectedCount
        self.message = message
    }
}

public enum InboxGatewayError: Error, Equatable, Sendable, LocalizedError {
    case invalidURL
    case unsupportedURL
    case storageUnavailable
    case importFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "链接格式无效"
        case .unsupportedURL: "只支持 http 或 https 链接"
        case .storageUnavailable: "内容存储不可用"
        case .importFailed(let message): message
        }
    }
}

public protocol InboxGateway: Sendable {
    func configuration() async throws -> InboxConfiguration
    func updateConfiguration(_ configuration: InboxConfiguration) async throws
    func importURL(_ request: InboxImportRequest) async throws -> InboxImportResult
    func applyCurrentTargetsToExistingItems() async throws -> InboxRetargetResult
}
