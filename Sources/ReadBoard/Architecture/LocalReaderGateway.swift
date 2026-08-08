import CryptoKit
import Foundation
import ReadBoardContract

/// 稳定阅读契约的本地实现。它是应用层到现有 SQLite/后台服务的唯一适配点；
/// 本机阅读继续直接访问数据库，不经过 HTTP。
public final class LocalReaderGateway: LibraryGateway, @unchecked Sendable {
    private struct CursorPayload: Codable {
        let version: Int
        let offset: Int
        let querySignature: String
    }

    private struct QueryIdentity: Codable {
        let filter: ContentFilter
        let sort: ContentSort
        let pageSize: Int
    }

    private let db: Database
    private let dateLock = NSLock()
    private let isoWithFractional: ISO8601DateFormatter
    private let iso: ISO8601DateFormatter
    private let sqliteDate: DateFormatter

    init(database: Database = .shared) {
        db = database
        isoWithFractional = ISO8601DateFormatter()
        isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        sqliteDate = DateFormatter()
        sqliteDate.locale = Locale(identifier: "en_US_POSIX")
        sqliteDate.calendar = Calendar(identifier: .gregorian)
        sqliteDate.timeZone = TimeZone(secondsFromGMT: 0)
        sqliteDate.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    public func page(_ query: ContentQuery) async throws -> ContentPage {
        try await Task.detached(priority: .userInitiated) { [self] in
            guard db.open() else { throw LibraryGatewayError.storageUnavailable }
            let pageSize = min(300, max(1, query.pageSize))
            let identity = QueryIdentity(
                filter: query.filter, sort: query.sort, pageSize: pageSize)
            let signature = try querySignature(identity)
            let offset = try decodeOffset(query.cursor, expectedSignature: signature)
            let filter = query.filter
            let processed = Dictionary(uniqueKeysWithValues: filter.processing.map {
                ($0.kind.rawValue, $0.match == .complete ? 1 : 2)
            })
            let rows = db.fetchContents(
                sourceId: filter.sourceID,
                folderId: filter.folderID,
                minScore: filter.minimumScore,
                maxScore: filter.maximumScore,
                includeUnscored: filter.includeUnscored,
                unreadOnly: filter.readState == .unread,
                exportedOnly: filter.exportedOnly,
                keyword: filter.keyword,
                starredOnly: filter.readState == .starred,
                processedFilters: processed,
                contentCategory: filter.category?.rawValue,
                unmetProcessingOnly: filter.unmetProcessingOnly,
                sortOrder: query.sort.rawValue,
                limit: pageSize,
                offset: offset
            )
            let nextCursor = rows.count == pageSize
                ? try encodeCursor(offset: offset + rows.count, signature: signature)
                : nil
            return ContentPage(
                items: rows.map(makeSummary), nextCursor: nextCursor)
        }.value
    }

    public func snapshot() async throws -> LibrarySnapshot {
        try await Task.detached(priority: .utility) { [self] in
            guard db.open() else { throw LibraryGatewayError.storageUnavailable }
            let nodes = db.fetchSidebarTree().map(makeNode)
            let counts = db.libraryCounts()
            return LibrarySnapshot(
                nodes: nodes,
                counts: LibraryCountsSnapshot(
                    total: counts.total,
                    unread: counts.unread,
                    pending: counts.pending,
                    pendingUnread: counts.pendingUnread,
                    exported: counts.exported,
                    exportedUnread: counts.exportedUnread,
                    articles: counts.articles,
                    articleUnread: counts.articleUnread,
                    podcasts: counts.podcasts,
                    podcastUnread: counts.podcastUnread,
                    videos: counts.videos,
                    videoUnread: counts.videoUnread
                )
            )
        }.value
    }

    public func setRead(contentID: Int64, isRead: Bool) async throws -> ContentState {
        try await withCheckedThrowingContinuation { continuation in
            let completion: @MainActor @Sendable (Bool) -> Void = { [self] succeeded in
                guard succeeded else {
                    continuation.resume(throwing: LibraryGatewayError.operationFailed("更新已读状态失败"))
                    return
                }
                do {
                    continuation.resume(returning: try currentState(
                        contentID: contentID, readOverride: isRead, starredOverride: nil))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            if isRead {
                db.markRead(contentId: contentID, completion: completion)
            } else {
                db.markUnread(contentId: contentID, completion: completion)
            }
        }
    }

    public func setStarred(contentID: Int64, isStarred: Bool) async throws -> ContentState {
        let result: (state: ContentState, changed: Bool) = try await withCheckedThrowingContinuation { continuation in
            db.setStarred(contentId: contentID, starred: isStarred) { [self] succeeded, changed in
                guard succeeded else {
                    continuation.resume(throwing: LibraryGatewayError.operationFailed("更新收藏状态失败"))
                    return
                }
                do {
                    continuation.resume(returning: (
                        try currentState(
                            contentID: contentID, readOverride: nil, starredOverride: isStarred),
                        changed
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        if isStarred && result.changed {
            await ExportService.shared.runPending(trigger: "starred", contentId: contentID)
        }
        return result.state
    }

    public func markRead(filter: ContentFilter) async throws -> MutationSummary {
        let affected = try await Task.detached(priority: .userInitiated) { [self] in
            guard db.open() else { throw LibraryGatewayError.storageUnavailable }
            let processed = Dictionary(uniqueKeysWithValues: filter.processing.map {
                ($0.kind.rawValue, $0.match == .complete ? 1 : 2)
            })
            return db.markAllRead(
                sourceId: filter.sourceID,
                folderId: filter.folderID,
                minScore: filter.minimumScore,
                maxScore: filter.maximumScore,
                includeUnscored: filter.includeUnscored,
                keyword: filter.keyword,
                starredOnly: filter.readState == .starred,
                exportedOnly: filter.exportedOnly,
                processedFilters: processed,
                contentCategory: filter.category?.rawValue,
                unmetProcessingOnly: filter.unmetProcessingOnly
            )
        }.value
        await MainActor.run { PipelineWorker.shared.requestPendingRefresh() }
        return MutationSummary(affectedCount: affected)
    }

    private func makeSummary(_ item: ContentItem) -> ContentSummary {
        ContentSummary(
            id: item.id,
            contentType: item.ctype,
            source: item.source,
            sourceType: item.sourceStype,
            sourceID: item.feedId,
            sourceName: item.sourceName,
            title: item.title,
            author: item.author,
            url: item.url,
            language: item.language,
            publishedAt: epochSeconds(item.publishedAt),
            excerpt: item.excerpt,
            score: item.llmScore,
            summary: item.llmSummary,
            fetchStatus: item.fetchStatus,
            isRead: item.isRead,
            isStarred: item.starred,
            imageURL: item.imageUrl,
            hasTranslation: item.hasTranslation,
            hasTranscript: item.hasTranscript,
            isMedia: item.isMedia,
            translatedHead: item.translatedHead,
            translatedTitle: item.titleTranslated,
            hasFulltext: item.hasFulltext,
            hasExport: item.hasExport,
            hasUnmetProcessing: item.hasUnmetProcessing,
            accessState: item.accessState
        )
    }

    private func makeNode(_ node: SidebarNode) -> LibraryNode {
        LibraryNode(
            id: node.id,
            kind: node.isFolder ? .folder : .source,
            name: node.name,
            count: node.count,
            unread: node.unread,
            sourceID: node.sourceId,
            folderID: node.folderId,
            children: (node.children ?? []).map(makeNode)
        )
    }

    private func currentState(
        contentID: Int64,
        readOverride: Bool?,
        starredOverride: Bool?
    ) throws -> ContentState {
        guard let row = db.queryRows(
            "SELECT read_at IS NOT NULL AS is_read, starred FROM content WHERE id = ?",
            params: [contentID]
        ).first else {
            throw LibraryGatewayError.operationFailed("内容不存在")
        }
        return ContentState(
            contentID: contentID,
            isRead: readOverride ?? (row["is_read"] == "1"),
            isStarred: starredOverride ?? (row["starred"] == "1"),
            updatedAt: Int64(Date().timeIntervalSince1970)
        )
    }

    private func epochSeconds(_ raw: String?) -> Int64? {
        guard let raw, !raw.isEmpty else { return nil }
        if let numeric = Double(raw) { return Int64(numeric) }
        dateLock.lock()
        defer { dateLock.unlock() }
        let date = isoWithFractional.date(from: raw)
            ?? iso.date(from: raw)
            ?? sqliteDate.date(from: raw)
        return date.map { Int64($0.timeIntervalSince1970) }
    }

    private func querySignature(_ identity: QueryIdentity) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(identity)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func decodeOffset(_ cursor: String?, expectedSignature: String) throws -> Int {
        guard let cursor else { return 0 }
        guard let data = Data(base64URLEncoded: cursor),
              let payload = try? JSONDecoder().decode(CursorPayload.self, from: data),
              payload.version == 1,
              payload.offset >= 0,
              payload.querySignature == expectedSignature else {
            throw LibraryGatewayError.invalidCursor
        }
        return payload.offset
    }

    private func encodeCursor(offset: Int, signature: String) throws -> String {
        let payload = CursorPayload(version: 1, offset: offset, querySignature: signature)
        return try JSONEncoder().encode(payload).base64URLEncodedString()
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
