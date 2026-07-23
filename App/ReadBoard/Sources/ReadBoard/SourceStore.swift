import Foundation
import SQLite3

// MARK: - 订阅源模型

struct FeedSource: Identifiable, Hashable {
    let id: Int64
    let stype: String          // rss / podcast / youtube / wechat
    let name: String
    let identifier: String     // feed url / channel id
    let enabled: Bool
    let lastFetchedAt: String?
    let error: String?
}

// MARK: - 订阅源管理（写入 + 抓取调度）

@MainActor
final class SourceStore: ObservableObject {
    @Published var sources: [FeedSource] = []
    @Published var isSyncing = false
    @Published var lastSyncMessage = ""

    private let db = Database.shared

    func reload() {
        sources = fetchAllSources()
    }

    // MARK: 增删改

    /// 添加订阅源（RSS/播客直接用 url；YouTube 传频道 url 或 UC id）
    @discardableResult
    func addSource(stype: String, name: String, identifier: String) -> Bool {
        let ok = db.execute(
            "INSERT OR IGNORE INTO content_source (stype, name, identifier, enabled) VALUES (?,?,?,1)",
            params: [stype, name, identifier]
        )
        if ok { reload() }
        return ok
    }

    func removeSource(id: Int64) {
        // 先删该源内容，再删源（content.source 与 stype 对应，guid 关联不可靠，按 source+identifier 不可靠，仅删源记录）
        db.execute("DELETE FROM content_source WHERE id = ?", params: [id])
        reload()
    }

    func setEnabled(id: Int64, enabled: Bool) {
        db.execute("UPDATE content_source SET enabled = ? WHERE id = ?", params: [enabled ? 1 : 0, id])
        reload()
    }

    // MARK: 抓取

    /// 抓取所有启用的源
    func syncAll() async {
        isSyncing = true
        lastSyncMessage = ""
        var total = 0
        var failed = 0
        for src in sources where src.enabled {
            do {
                let n = try await syncOne(src)
                total += n
            } catch {
                failed += 1
                db.execute("UPDATE content_source SET error = ? WHERE id = ?",
                           params: [error.localizedDescription, src.id])
            }
        }
        lastSyncMessage = failed > 0
            ? "完成：新增 \(total) 条，\(failed) 个源失败"
            : "完成：新增 \(total) 条"
        isSyncing = false
        reload()
    }

    /// 抓取单个源，返回新增条数
    @discardableResult
    func syncOne(_ src: FeedSource) async throws -> Int {
        let feed = try await FeedFetcher.fetch(urlString: src.identifier)
        var added = 0
        for entry in feed.entries {
            if upsertContent(source: src.stype, entry: entry) { added += 1 }
        }
        db.execute("UPDATE content_source SET last_fetched_at = datetime('now'), error = NULL WHERE id = ?",
                   params: [src.id])
        return added
    }

    // MARK: 私有

    private func fetchAllSources() -> [FeedSource] {
        guard db.open() else { return [] }
        var stmt: OpaquePointer?
        var list: [FeedSource] = []
        let sql = "SELECT id, stype, name, identifier, enabled, last_fetched_at, error FROM content_source ORDER BY stype, name;"
        // 直接走 Database 的底层句柄做只读遍历
        if prepareRead(sql, &stmt) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                list.append(FeedSource(
                    id: sqlite3_column_int64(stmt, 0),
                    stype: columnText(stmt, 1) ?? "rss",
                    name: columnText(stmt, 2) ?? "",
                    identifier: columnText(stmt, 3) ?? "",
                    enabled: sqlite3_column_int64(stmt, 4) == 1,
                    lastFetchedAt: columnText(stmt, 5),
                    error: columnText(stmt, 6)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return list
    }

    /// 把一条 feed entry 写进 content（按 source+guid 去重），返回是否新插入
    private func upsertContent(source: String, entry: ParsedEntry) -> Bool {
        // 已存在则跳过
        if let _ = db.scalarInt("SELECT id FROM content WHERE source = ? AND guid = ?",
                                params: [source, entry.guid]) {
            return false
        }
        let ctype: String
        if entry.meta["video_id"] != nil { ctype = "video" }
        else if entry.meta["audio_url"] != nil { ctype = "podcast" }
        else { ctype = "article" }

        let published = entry.published.map { ISO8601DateFormatter().string(from: $0) }
        let metaJson = (try? JSONSerialization.data(withJSONObject: entry.meta))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return db.execute(
            """
            INSERT INTO content (ctype, guid, source, title, author, url, published_at, content_html, fetch_status, meta)
            VALUES (?,?,?,?,?,?,?,?,0,?)
            """,
            params: [ctype, entry.guid, source, entry.title, entry.author, entry.url, published, entry.html, metaJson]
        )
    }

    // MARK: SQLite 底层（读遍历辅助）

    private func prepareRead(_ sql: String, _ stmt: inout OpaquePointer?) -> Bool {
        // 复用 Database 已打开的句柄：通过反射不可取，这里让 Database 暴露一个 prepare
        Database.shared.prepare(sql, &stmt)
    }

    private func columnText(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: p)
    }
}
