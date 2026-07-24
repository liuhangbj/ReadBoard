import Foundation

// MARK: - 统计面板数据
// 源数量/内容量/管线处理量/失败率聚合。

public struct StatsOverview {
    var totalSources = 0
    var enabledSources = 0
    var totalContent = 0
    var unreadCount = 0
    var starredCount = 0
    var archivedCount = 0
    var duplicateCount = 0
    var withFulltext = 0
    var scored = 0
    var translated = 0
    var summarized = 0
    var tagCount = 0
    var folderCount = 0
    // 管线 job 统计
    var jobTotal = 0
    var jobFailed = 0
    var dbSizeMB: Double = 0
}

public final class StatsService: @unchecked Sendable {
    static let shared = StatsService()
    private let db = Database.shared
    private init() {}

    func overview() -> StatsOverview {
        var s = StatsOverview()
        func int(_ sql: String) -> Int { db.scalarInt(sql) ?? 0 }

        s.totalSources = int("SELECT COUNT(*) FROM content_source")
        s.enabledSources = int("SELECT COUNT(*) FROM content_source WHERE enabled = 1")
        // 有效内容口径统一：全部统计都排除 is_duplicate（列表/阅读/导出都不见重复，
        // 统计却算进去会虚高）。totalContent = 去重后可见总量；duplicateCount 单列。
        s.totalContent = int("SELECT COUNT(*) FROM content WHERE is_duplicate = 0")
        s.unreadCount = int("SELECT COUNT(*) FROM content WHERE read_at IS NULL AND is_archived = 0 AND is_duplicate = 0")
        s.starredCount = int("SELECT COUNT(*) FROM content WHERE starred = 1 AND is_duplicate = 0")
        s.archivedCount = int("SELECT COUNT(*) FROM content WHERE is_archived = 1 AND is_duplicate = 0")
        s.duplicateCount = int("SELECT COUNT(*) FROM content WHERE is_duplicate = 1")
        s.withFulltext = int("SELECT COUNT(*) FROM content WHERE content_md IS NOT NULL AND content_md != '' AND is_duplicate = 0")
        s.scored = int("SELECT COUNT(*) FROM content WHERE llm_score IS NOT NULL AND is_duplicate = 0")
        s.translated = int("SELECT COUNT(*) FROM content WHERE llm_translated_md IS NOT NULL AND llm_translated_md != '' AND is_duplicate = 0")
        s.summarized = int("SELECT COUNT(*) FROM content WHERE llm_summary IS NOT NULL AND llm_summary != '' AND is_duplicate = 0")
        s.tagCount = int("SELECT COUNT(*) FROM tag")
        s.folderCount = int("SELECT COUNT(*) FROM folder")
        s.jobTotal = int("SELECT COUNT(*) FROM content_job")
        s.jobFailed = int("SELECT COUNT(*) FROM content_job WHERE status = 3")

        // DB 文件大小
        let path = NSHomeDirectory() + "/readboard/Data/readboard.db"
        if let attr = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attr[.size] as? Int64 {
            s.dbSizeMB = Double(size) / 1_000_000
        }
        return s
    }

    /// 各管线 job 成功/失败分布
    func jobByType() -> [(jtype: String, ok: Int, failed: Int)] {
        db.queryRows("""
            SELECT jtype,
                   SUM(CASE WHEN status = 2 THEN 1 ELSE 0 END) AS ok,
                   SUM(CASE WHEN status = 3 THEN 1 ELSE 0 END) AS failed
            FROM content_job GROUP BY jtype ORDER BY ok DESC;
            """).map {
                ($0["jtype"] ?? "", Int($0["ok"] ?? "0") ?? 0, Int($0["failed"] ?? "0") ?? 0)
            }
    }

    /// 内容最多的源 top N
    func topSources(limit: Int = 10) -> [(name: String, count: Int)] {
        db.queryRows("""
            SELECT s.name, COUNT(c.id) AS cnt FROM content_source s
            JOIN content c ON c.source_id = s.id
            GROUP BY s.id ORDER BY cnt DESC LIMIT ?;
            """, params: [limit]).map {
                ($0["name"] ?? "", Int($0["cnt"] ?? "0") ?? 0)
            }
    }
}
