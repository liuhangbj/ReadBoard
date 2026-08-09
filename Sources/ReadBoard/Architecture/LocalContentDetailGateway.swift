import ReadBoardContract

/// 单篇阅读契约的本地 SQLite 适配器。本机不经过 HTTP，远程实现只需遵守同一协议。
public final class LocalContentDetailGateway: ContentDetailGateway, @unchecked Sendable {
    private let db: Database

    init(database: Database = .shared) {
        db = database
    }

    public func detail(contentID: Int64) async throws -> ContentDetail {
        try await Task.detached(priority: .userInitiated) { [self] in
            guard db.open() else { throw ContentDetailGatewayError.storageUnavailable }
            guard let payload = db.fetchReaderPayload(id: contentID) else {
                throw ContentDetailGatewayError.contentNotFound(contentID)
            }
            let translatedMarkdown = MarkdownImageReconciler.reconcile(
                translation: payload.llmTranslatedMd,
                source: payload.contentMd)
            return ContentDetail(
                id: contentID,
                contentMarkdown: payload.contentMd,
                translatedMarkdown: translatedMarkdown,
                transcriptMarkdown: payload.llmTranscriptMd,
                translatedTitle: payload.titleTranslated,
                audioURL: payload.audioUrl,
                videoID: payload.videoId,
                score: payload.score,
                summary: payload.summary
            )
        }.value
    }
}
