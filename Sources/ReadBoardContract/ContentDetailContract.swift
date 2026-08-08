import Foundation

/// 单篇阅读所需的完整载荷。列表 DTO 保持轻量，只有用户打开文章时才获取这里的大字段。
public struct ContentDetail: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let contentMarkdown: String?
    public let translatedMarkdown: String?
    public let transcriptMarkdown: String?
    public let translatedTitle: String?
    public let audioURL: String?
    public let videoID: String?
    public let score: Int?
    public let summary: String?

    public init(
        id: Int64,
        contentMarkdown: String?,
        translatedMarkdown: String?,
        transcriptMarkdown: String?,
        translatedTitle: String?,
        audioURL: String?,
        videoID: String?,
        score: Int?,
        summary: String?
    ) {
        self.id = id
        self.contentMarkdown = contentMarkdown
        self.translatedMarkdown = translatedMarkdown
        self.transcriptMarkdown = transcriptMarkdown
        self.translatedTitle = translatedTitle
        self.audioURL = audioURL
        self.videoID = videoID
        self.score = score
        self.summary = summary
    }
}

public enum ContentDetailGatewayError: Error, Equatable, Sendable, LocalizedError {
    case storageUnavailable
    case contentNotFound(Int64)

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "内容存储不可用"
        case .contentNotFound:
            return "内容不存在或已被删除"
        }
    }
}

/// 本地阅读器和未来远程 Reader 共用的单篇详情端口。
public protocol ContentDetailGateway: Sendable {
    func detail(contentID: Int64) async throws -> ContentDetail
}
