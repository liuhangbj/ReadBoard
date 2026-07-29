import Foundation

// MARK: - 统计面板数据
// 源数量/内容量/管线处理量/失败率聚合。

public struct StatsOverview: Sendable {
    var totalSources = 0
    var enabledSources = 0
    var totalContent = 0
    var unreadCount = 0
    var starredCount = 0
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

    /// content 表各维度计数合并成一次全表扫（原 10 条独立 COUNT，每条都全表扫一遍，
    /// 67k 行 × 10 次扫主线程卡顿明显）。CASE WHEN 聚合只扫一次。
    func overview() -> StatsOverview {
        var s = StatsOverview()
        func int(_ sql: String) -> Int { db.scalarInt(sql) ?? 0 }

        s.totalSources = int("SELECT COUNT(*) FROM content_source")
        s.enabledSources = int("SELECT COUNT(*) FROM content_source WHERE enabled = 1")

        // 单趟聚合：9 个 content 维度一次扫完
        if let row = db.queryRows("""
            SELECT
              SUM(CASE WHEN is_duplicate = 0 AND deleted_at IS NULL THEN 1 ELSE 0 END) AS total,
              SUM(CASE WHEN read_at IS NULL AND is_duplicate = 0 AND deleted_at IS NULL THEN 1 ELSE 0 END) AS unread,
              SUM(CASE WHEN starred = 1 AND is_duplicate = 0 AND deleted_at IS NULL THEN 1 ELSE 0 END) AS starred,
              SUM(CASE WHEN is_duplicate = 1 THEN 1 ELSE 0 END) AS dup,
              SUM(CASE WHEN content_md IS NOT NULL AND content_md != '' AND is_duplicate = 0 THEN 1 ELSE 0 END) AS fulltext,
              SUM(CASE WHEN llm_score IS NOT NULL AND is_duplicate = 0 THEN 1 ELSE 0 END) AS scored,
              SUM(CASE WHEN llm_translated_md IS NOT NULL AND llm_translated_md != '' AND is_duplicate = 0 THEN 1 ELSE 0 END) AS translated,
              SUM(CASE WHEN llm_summary IS NOT NULL AND llm_summary != '' AND is_duplicate = 0 THEN 1 ELSE 0 END) AS summarized
            FROM content;
            """).first {
            func v(_ k: String) -> Int { Int(row[k] ?? "0") ?? 0 }
            s.totalContent = v("total")
            s.unreadCount = v("unread")
            s.starredCount = v("starred")
            s.duplicateCount = v("dup")
            s.withFulltext = v("fulltext")
            s.scored = v("scored")
            s.translated = v("translated")
            s.summarized = v("summarized")
        }

        s.tagCount = int("SELECT COUNT(*) FROM tag")
        s.folderCount = int("SELECT COUNT(*) FROM folder")
        // job 两维合并一次扫
        if let row = db.queryRows("""
            SELECT COUNT(*) AS total,
                   SUM(CASE WHEN status = 3 THEN 1 ELSE 0 END) AS failed
            FROM content_job;
            """).first {
            s.jobTotal = Int(row["total"] ?? "0") ?? 0
            s.jobFailed = Int(row["failed"] ?? "0") ?? 0
        }

        // DB 文件大小
        let path = Database.databasePath
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

    /// 导出记录（各平台导出历史，按时间倒序取最近 20 条）
    func exportRecords(limit: Int = 20) -> [(platform: String, title: String, status: String, time: String)] {
        db.queryRows("""
            SELECT r.target, c.title, r.status, r.delivered_at
            FROM export_record er
            JOIN export_rule r ON er.rule_id = r.id
            JOIN content c ON er.content_id = c.id
            ORDER BY er.delivered_at DESC LIMIT ?;
            """, params: [limit]).map {
                let target = $0["target"] ?? ""
                let platform = switch target {
                    case "obsidian": "Obsidian"
                    case "mddir": "Markdown"
                    case "webhook": "Webhook"
                    case "cubox": "Cubox"
                    case "instapaper": "Instapaper"
                    case "readwise": "Readwise"
                    case "notebooklm": "NotebookLM"
                    case "notion": "Notion"
                    default: target
                }
                let time = String(($0["delivered_at"] ?? "").prefix(16))
                return (platform, $0["title"] ?? "", $0["status"] ?? "", time)
            }
    }
}
