import Foundation

/// 一次性 B站历史访问权限回填。只读播放器元数据并更新 meta，
/// 不下载音频、不重新转录、不修改正文。
public enum BilibiliAccessBackfill {
    public struct SourceSummary: Sendable {
        public var sourceId: Int64
        public var sourceName: String
        public var total = 0
        public var open = 0
        public var upowerExclusive = 0
        public var paidPreview = 0
        public var loginRequired = 0
        public var failed = 0
    }

    public struct Summary: Sendable {
        public var sources: [SourceSummary] = []

        public var total: Int { sources.reduce(0) { $0 + $1.total } }
        public var failed: Int { sources.reduce(0) { $0 + $1.failed } }
        public var upowerExclusive: Int { sources.reduce(0) { $0 + $1.upowerExclusive } }
        public var paidPreview: Int { sources.reduce(0) { $0 + $1.paidPreview } }
        public var loginRequired: Int { sources.reduce(0) { $0 + $1.loginRequired } }
        public var open: Int { sources.reduce(0) { $0 + $1.open } }
    }

    private struct Item: Sendable {
        let id: Int64
        let sourceId: Int64
        let sourceName: String
        let url: String
    }

    public static func run(
        itemDelayNanoseconds: UInt64 = 450_000_000,
        sourceDelayNanoseconds: UInt64 = 2_000_000_000
    ) async -> Summary {
        let db = Database.shared
        guard db.open() else { return Summary() }
        let items = db.queryRows("""
            SELECT c.id, c.source_id, c.url, COALESCE(s.name, '') AS source_name
            FROM content c
            LEFT JOIN content_source s ON s.id = c.source_id
            WHERE c.source = 'bilibili'
              AND c.deleted_at IS NULL
              AND json_extract(c.meta, '$.bilibili_access_state') IS NULL
            ORDER BY c.source_id, c.id;
            """).compactMap { row -> Item? in
                guard let id = Int64(row["id"] ?? ""),
                      let sourceId = Int64(row["source_id"] ?? "") else { return nil }
                return Item(
                    id: id,
                    sourceId: sourceId,
                    sourceName: row["source_name"] ?? "",
                    url: row["url"] ?? ""
                )
            }

        let grouped = Dictionary(grouping: items, by: \.sourceId)
        var summary = Summary()
        for (sourceId, sourceItems) in grouped.sorted(by: { $0.key < $1.key }) {
            var source = SourceSummary(
                sourceId: sourceId,
                sourceName: sourceItems.first?.sourceName ?? ""
            )
            for item in sourceItems {
                source.total += 1
                do {
                    if let access = try await BilibiliFetcher.fetchVideoAccess(videoURL: item.url) {
                        BilibiliAccessMetaStore.apply(contentId: item.id, access: access)
                        switch access.state {
                        case .open: source.open += 1
                        case .upowerExclusive: source.upowerExclusive += 1
                        case .paidPreview: source.paidPreview += 1
                        case .loginRequired: source.loginRequired += 1
                        }
                    } else {
                        source.failed += 1
                    }
                } catch {
                    source.failed += 1
                }
                if itemDelayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: itemDelayNanoseconds)
                }
            }
            print(
                "BILIBILI_ACCESS_BACKFILL source=\(sourceId) name=\(source.sourceName) "
                    + "total=\(source.total) open=\(source.open) high=\(source.upowerExclusive) "
                    + "paid=\(source.paidPreview) login=\(source.loginRequired) failed=\(source.failed)"
            )
            summary.sources.append(source)
            if sourceDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: sourceDelayNanoseconds)
            }
        }
        print(
            "BILIBILI_ACCESS_BACKFILL_DONE sources=\(summary.sources.count) total=\(summary.total) "
                + "open=\(summary.open) high=\(summary.upowerExclusive) paid=\(summary.paidPreview) "
                + "login=\(summary.loginRequired) failed=\(summary.failed)"
        )
        return summary
    }
}
