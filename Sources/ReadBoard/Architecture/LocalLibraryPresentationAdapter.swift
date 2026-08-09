import Foundation
import ReadBoardContract

/// Core 迁移期适配器：本地轻量记录转换为与 Go 相同的 Contract 行模型。
enum LocalLibraryPresentationAdapter {
    private static let dateLock = NSLock()
    private nonisolated(unsafe) static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private nonisolated(unsafe) static let iso = ISO8601DateFormatter()
    private static let sqliteDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func summary(item: ContentItem, isReadOverride: Bool? = nil) -> ContentSummary {
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
            isRead: isReadOverride ?? item.isRead,
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
            accessState: item.accessState)
    }

    private static func epochSeconds(_ raw: String?) -> Int64? {
        guard let raw, !raw.isEmpty else { return nil }
        if let numeric = Double(raw) { return Int64(numeric) }
        dateLock.lock()
        defer { dateLock.unlock() }
        let date = isoWithFractional.date(from: raw)
            ?? iso.date(from: raw)
            ?? sqliteDate.date(from: raw)
        return date.map { Int64($0.timeIntervalSince1970) }
    }
}
