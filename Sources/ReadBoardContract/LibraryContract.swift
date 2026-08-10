import Foundation

// MARK: - Stable reader contract

/// 阅读列表的内容筛选。该类型属于本地实现与未来 HTTP API 共同遵守的稳定契约，
/// 不包含 SQL、SwiftUI 状态或具体传输协议细节。
public struct ContentFilter: Codable, Equatable, Sendable {
    public var sourceID: Int64?
    public var folderID: Int64?
    public var category: ContentCategory?
    public var minimumScore: Int?
    public var maximumScore: Int?
    public var includeUnscored: Bool
    public var readState: ContentReadState
    public var exportedOnly: Bool
    public var keyword: String?
    public var processing: [ProcessingCriterion]
    public var unmetProcessingOnly: Bool

    public init(
        sourceID: Int64? = nil,
        folderID: Int64? = nil,
        category: ContentCategory? = nil,
        minimumScore: Int? = nil,
        maximumScore: Int? = nil,
        includeUnscored: Bool = false,
        readState: ContentReadState = .all,
        exportedOnly: Bool = false,
        keyword: String? = nil,
        processing: [ProcessingCriterion] = [],
        unmetProcessingOnly: Bool = false
    ) {
        self.sourceID = sourceID
        self.folderID = folderID
        self.category = category
        self.minimumScore = minimumScore
        self.maximumScore = maximumScore
        self.includeUnscored = includeUnscored
        self.readState = readState
        self.exportedOnly = exportedOnly
        self.keyword = keyword
        self.processing = processing
        self.unmetProcessingOnly = unmetProcessingOnly
    }
}

public enum ContentCategory: String, Codable, CaseIterable, Sendable {
    case article
    case podcast
    case video
}

public enum ContentReadState: String, Codable, CaseIterable, Sendable {
    case all
    case unread
    case starred
}

public enum ContentSort: String, Codable, CaseIterable, Sendable {
    case newest
    case oldest
    case score
}

public enum ProcessingKind: String, Codable, CaseIterable, Hashable, Sendable {
    case fulltext
    case score
    case summary
    case translate
    case transcribe
}

public enum ProcessingMatch: String, Codable, CaseIterable, Hashable, Sendable {
    case complete
    case incomplete
}

public struct ProcessingCriterion: Codable, Equatable, Hashable, Sendable {
    public let kind: ProcessingKind
    public let match: ProcessingMatch

    public init(kind: ProcessingKind, match: ProcessingMatch) {
        self.kind = kind
        self.match = match
    }
}

/// `cursor` 是不透明值。调用方只能原样传回，不能依赖其编码方式。
public struct ContentQuery: Codable, Equatable, Sendable {
    public var filter: ContentFilter
    public var sort: ContentSort
    public var pageSize: Int
    public var cursor: String?

    public init(
        filter: ContentFilter = ContentFilter(),
        sort: ContentSort = .newest,
        pageSize: Int = 50,
        cursor: String? = nil
    ) {
        self.filter = filter
        self.sort = sort
        self.pageSize = pageSize
        self.cursor = cursor
    }
}

/// 列表专用轻量内容，不承载正文、原始 HTML、完整译文或完整 meta。
/// `publishedAt` 使用 Unix epoch 秒，避免数据库日期格式泄漏到客户端。
public struct ContentSummary: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let contentType: String
    public let source: String
    public let sourceType: String?
    public let sourceID: Int64?
    public let sourceName: String?
    public let title: String
    public let author: String?
    public let url: String
    public let language: String?
    public let publishedAt: Int64?
    public let excerpt: String?
    public let score: Int?
    public let summary: String?
    public let fetchStatus: Int
    public let isRead: Bool
    public let isStarred: Bool
    public let imageURL: String?
    public let hasTranslation: Bool
    public let hasTranscript: Bool
    public let isMedia: Bool
    public let translatedHead: String?
    public let translatedTitle: String?
    public let hasFulltext: Bool
    public let hasExport: Bool
    public let hasUnmetProcessing: Bool
    public let accessState: String?

    public init(
        id: Int64,
        contentType: String,
        source: String,
        sourceType: String?,
        sourceID: Int64?,
        sourceName: String?,
        title: String,
        author: String?,
        url: String,
        language: String?,
        publishedAt: Int64?,
        excerpt: String?,
        score: Int?,
        summary: String?,
        fetchStatus: Int,
        isRead: Bool,
        isStarred: Bool,
        imageURL: String?,
        hasTranslation: Bool,
        hasTranscript: Bool,
        isMedia: Bool,
        translatedHead: String?,
        translatedTitle: String?,
        hasFulltext: Bool,
        hasExport: Bool,
        hasUnmetProcessing: Bool,
        accessState: String?
    ) {
        self.id = id
        self.contentType = contentType
        self.source = source
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.title = title
        self.author = author
        self.url = url
        self.language = language
        self.publishedAt = publishedAt
        self.excerpt = excerpt
        self.score = score
        self.summary = summary
        self.fetchStatus = fetchStatus
        self.isRead = isRead
        self.isStarred = isStarred
        self.imageURL = imageURL
        self.hasTranslation = hasTranslation
        self.hasTranscript = hasTranscript
        self.isMedia = isMedia
        self.translatedHead = translatedHead
        self.translatedTitle = translatedTitle
        self.hasFulltext = hasFulltext
        self.hasExport = hasExport
        self.hasUnmetProcessing = hasUnmetProcessing
        self.accessState = accessState
    }
}

public extension ContentSummary {
    func replacingState(isRead: Bool, isStarred: Bool) -> ContentSummary {
        ContentSummary(
            id: id, contentType: contentType, source: source, sourceType: sourceType,
            sourceID: sourceID, sourceName: sourceName, title: title, author: author,
            url: url, language: language, publishedAt: publishedAt, excerpt: excerpt,
            score: score, summary: summary, fetchStatus: fetchStatus, isRead: isRead,
            isStarred: isStarred, imageURL: imageURL, hasTranslation: hasTranslation,
            hasTranscript: hasTranscript, isMedia: isMedia, translatedHead: translatedHead,
            translatedTitle: translatedTitle, hasFulltext: hasFulltext,
            hasExport: hasExport, hasUnmetProcessing: hasUnmetProcessing,
            accessState: accessState)
    }
}

public struct ContentPage: Codable, Equatable, Sendable {
    public let items: [ContentSummary]
    public let nextCursor: String?

    public init(items: [ContentSummary], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum LibraryNodeKind: String, Codable, Sendable {
    case folder
    case source
}

public struct LibraryNode: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: LibraryNodeKind
    public let name: String
    public let count: Int
    public let unread: Int
    public let sourceID: Int64?
    public let folderID: Int64?
    public let children: [LibraryNode]

    public init(
        id: String,
        kind: LibraryNodeKind,
        name: String,
        count: Int,
        unread: Int,
        sourceID: Int64?,
        folderID: Int64?,
        children: [LibraryNode] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.count = count
        self.unread = unread
        self.sourceID = sourceID
        self.folderID = folderID
        self.children = children
    }
}

public struct LibraryCountsSnapshot: Codable, Equatable, Sendable {
    public let total: Int
    public let unread: Int
    public let pending: Int
    public let pendingUnread: Int
    public let exported: Int
    public let exportedUnread: Int
    public let articles: Int
    public let articleUnread: Int
    public let podcasts: Int
    public let podcastUnread: Int
    public let videos: Int
    public let videoUnread: Int

    public init(
        total: Int,
        unread: Int,
        pending: Int,
        pendingUnread: Int,
        exported: Int,
        exportedUnread: Int,
        articles: Int,
        articleUnread: Int,
        podcasts: Int,
        podcastUnread: Int,
        videos: Int,
        videoUnread: Int
    ) {
        self.total = total
        self.unread = unread
        self.pending = pending
        self.pendingUnread = pendingUnread
        self.exported = exported
        self.exportedUnread = exportedUnread
        self.articles = articles
        self.articleUnread = articleUnread
        self.podcasts = podcasts
        self.podcastUnread = podcastUnread
        self.videos = videos
        self.videoUnread = videoUnread
    }
}

public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public let nodes: [LibraryNode]
    public let counts: LibraryCountsSnapshot

    public init(nodes: [LibraryNode], counts: LibraryCountsSnapshot) {
        self.nodes = nodes
        self.counts = counts
    }
}

public struct ContentState: Codable, Equatable, Sendable {
    public let contentID: Int64
    public let isRead: Bool
    public let isStarred: Bool
    public let updatedAt: Int64

    public init(contentID: Int64, isRead: Bool, isStarred: Bool, updatedAt: Int64) {
        self.contentID = contentID
        self.isRead = isRead
        self.isStarred = isStarred
        self.updatedAt = updatedAt
    }
}

public struct MutationSummary: Codable, Equatable, Sendable {
    public let affectedCount: Int

    public init(affectedCount: Int) {
        self.affectedCount = affectedCount
    }
}

public enum LibraryGatewayError: Error, Equatable, Sendable, LocalizedError {
    case storageUnavailable
    case invalidCursor
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable: return "内容存储不可用"
        case .invalidCursor: return "分页游标无效或不属于当前查询"
        case .operationFailed(let message): return message
        }
    }
}

/// 本地前端与未来远程 Reader 共同依赖的阅读列表端口。
/// 所有修改操作都是显式目标状态，保证网络重试时幂等。
public protocol LibraryGateway: Sendable {
    func page(_ query: ContentQuery) async throws -> ContentPage
    func snapshot() async throws -> LibrarySnapshot
    func setRead(contentID: Int64, isRead: Bool) async throws -> ContentState
    func setStarred(contentID: Int64, isStarred: Bool) async throws -> ContentState
    func markRead(filter: ContentFilter) async throws -> MutationSummary
}
