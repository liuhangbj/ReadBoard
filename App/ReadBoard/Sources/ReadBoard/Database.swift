import Foundation
import SQLite3

// MARK: - 数据模型

struct ContentItem: Identifiable, Hashable {
    let id: Int64
    let ctype: String
    let source: String
    let title: String
    let author: String?
    let url: String
    let language: String?
    let publishedAt: String?
    let excerpt: String?
    let contentMd: String?
    let llmScore: Int?
    let llmSummary: String?
    let llmTranslatedMd: String?
    let fetchStatus: Int
    let feedId: Int64?
    let audioUrl: String?     // 播客/视频的音频流地址（来自 meta.audio_url）
    let readAt: String?       // 已读时间，nil = 未读
    var isRead: Bool { readAt != nil }
    let starred: Bool         // 星标
    let archived: Bool        // 归档

    /// 返回一个标记为已读的副本（本地状态同步用）
    func markingRead() -> ContentItem {
        ContentItem(id: id, ctype: ctype, source: source, title: title, author: author,
                    url: url, language: language, publishedAt: publishedAt, excerpt: excerpt,
                    contentMd: contentMd, llmScore: llmScore, llmSummary: llmSummary,
                    llmTranslatedMd: llmTranslatedMd, fetchStatus: fetchStatus, feedId: feedId,
                    audioUrl: audioUrl, readAt: "now", starred: starred, archived: archived)
    }

    /// 返回切换星标的副本
    func togglingStar() -> ContentItem {
        ContentItem(id: id, ctype: ctype, source: source, title: title, author: author,
                    url: url, language: language, publishedAt: publishedAt, excerpt: excerpt,
                    contentMd: contentMd, llmScore: llmScore, llmSummary: llmSummary,
                    llmTranslatedMd: llmTranslatedMd, fetchStatus: fetchStatus, feedId: feedId,
                    audioUrl: audioUrl, readAt: readAt, starred: !starred, archived: archived)
    }

    /// 返回切换归档的副本
    func togglingArchive() -> ContentItem {
        ContentItem(id: id, ctype: ctype, source: source, title: title, author: author,
                    url: url, language: language, publishedAt: publishedAt, excerpt: excerpt,
                    contentMd: contentMd, llmScore: llmScore, llmSummary: llmSummary,
                    llmTranslatedMd: llmTranslatedMd, fetchStatus: fetchStatus, feedId: feedId,
                    audioUrl: audioUrl, readAt: readAt, starred: starred, archived: !archived)
    }
}

struct SourceGroup: Identifiable, Hashable {
    var id: String { name }
    let name: String      // source 或 feed 显示名
    let kind: String      // rss / podcast / youtube / wechat
    let count: Int
}

// MARK: - SQLite 只读访问

final class Database: @unchecked Sendable {
    static let shared = Database()
    private var db: OpaquePointer?

    // 默认指向迁移好的库；可用环境变量覆盖便于测试
    private let dbPath: String = {
        if let p = ProcessInfo.processInfo.environment["READBOARD_DB"] { return p }
        return NSHomeDirectory() + "/readboard/Data/readboard.db"
    }()

    private init() {}

    @discardableResult
    func open() -> Bool {
        if db != nil { return true }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK {
            return true
        }
        sqlite3_close(db)
        db = nil
        return false
    }

    func close() {
        sqlite3_close(db)
        db = nil
    }

    // MARK: 写操作

    /// 执行无返回值的写 SQL（带参数绑定）
    @discardableResult
    func execute(_ sql: String, params: [Any?] = []) -> Bool {
        guard open() else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        bindParams(stmt, params)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    /// 查询单个 Int 值
    func scalarInt(_ sql: String, params: [Any?] = []) -> Int? {
        guard open() else { return nil }
        var stmt: OpaquePointer?
        var result: Int?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            bindParams(stmt, params)
            if sqlite3_step(stmt) == SQLITE_ROW { result = Int(sqlite3_column_int64(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return result
    }

    /// 查询单个 String 值
    func scalarString(_ sql: String, params: [Any?] = []) -> String? {
        guard open() else { return nil }
        var stmt: OpaquePointer?
        var result: String?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            bindParams(stmt, params)
            if sqlite3_step(stmt) == SQLITE_ROW, let p = sqlite3_column_text(stmt, 0) {
                result = String(cString: p)
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    /// 通用参数化多行查询：返回 [[列名: 值]]（文本化）
    func queryRows(_ sql: String, params: [Any?] = []) -> [[String: String]] {
        guard open() else { return [] }
        var stmt: OpaquePointer?
        var out: [[String: String]] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bindParams(stmt, params)
        defer { sqlite3_finalize(stmt) }
        let ncol = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String] = [:]
            for c in 0..<ncol {
                let name = String(cString: sqlite3_column_name(stmt, c))
                if let p = sqlite3_column_text(stmt, c) { row[name] = String(cString: p) }
            }
            out.append(row)
        }
        return out
    }

    /// 最后插入行的 rowid
    func lastInsertId() -> Int64 {
        sqlite3_last_insert_rowid(db)
    }

    /// 暴露 prepare 供 SourceStore 等做只读遍历
    func prepare(_ sql: String, _ stmt: inout OpaquePointer?) -> Bool {
        guard open() else { return false }
        return sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
    }

    private func bindParams(_ stmt: OpaquePointer?, _ params: [Any?]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            default:
                if let anyV = p { sqlite3_bind_text(stmt, idx, String(describing: anyV), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                else { sqlite3_bind_null(stmt, idx) }
            }
        }
    }

    // MARK: 查询

    /// 各 source 分组及数量（用于左侧源列表）
    func fetchSourceGroups() -> [SourceGroup] {
        guard open() else { return [] }
        let sql = """
        SELECT source, ctype, COUNT(*) FROM content
        GROUP BY source, ctype
        ORDER BY COUNT(*) DESC;
        """
        var stmt: OpaquePointer?
        var groups: [SourceGroup] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let source = String(cString: sqlite3_column_text(stmt, 0))
                let ctype = String(cString: sqlite3_column_text(stmt, 1))
                let count = Int(sqlite3_column_int64(stmt, 2))
                groups.append(SourceGroup(name: "\(source)·\(ctype)", kind: source, count: count))
            }
        }
        sqlite3_finalize(stmt)
        return groups
    }

    /// 拉取内容列表（可按 source 过滤、评分筛选、未读过滤、关键词搜索、星标/归档筛选）
    func fetchContents(source: String? = nil, minScore: Int? = nil, unreadOnly: Bool = false,
                       keyword: String? = nil, starredOnly: Bool = false,
                       archived: Bool = false, limit: Int = 200) -> [ContentItem] {
        guard open() else { return [] }
        var sql = """
        SELECT id, ctype, source, title, author, url, language, published_at,
               excerpt, content_md, llm_score, llm_summary, llm_translated_md, fetch_status, feed_id, meta, read_at,
               starred, is_archived
        FROM content
        """
        var conds: [String] = ["is_archived = \(archived ? 1 : 0)"]
        if source != nil { conds.append("source = ?") }
        if minScore != nil { conds.append("llm_score >= ?") }
        if unreadOnly { conds.append("read_at IS NULL") }
        if starredOnly { conds.append("starred = 1") }
        if let kw = keyword, !kw.isEmpty {
            conds.append("(title LIKE ? OR excerpt LIKE ? OR content_md LIKE ?)")
        }
        sql += " WHERE " + conds.joined(separator: " AND ")
        // 有评分的优先，再按发布时间倒序
        sql += " ORDER BY (llm_score IS NULL), llm_score DESC, published_at DESC LIMIT ?;"

        var stmt: OpaquePointer?
        var items: [ContentItem] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            var idx: Int32 = 1
            let binder: (String) -> Void = { s in
                sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)); idx += 1
            }
            if let s = source { binder(s) }
            if let m = minScore { sqlite3_bind_int64(stmt, idx, Int64(m)); idx += 1 }
            if let kw = keyword, !kw.isEmpty {
                let like = "%\(kw)%"
                binder(like); binder(like); binder(like)
            }
            sqlite3_bind_int64(stmt, idx, Int64(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                items.append(Self.rowToItem(stmt))
            }
        }
        sqlite3_finalize(stmt)
        return items
    }

    /// 标记已读（写入当前时间）
    func markRead(contentId: Int64) {
        execute("UPDATE content SET read_at = datetime('now') WHERE id = ?", params: [contentId])
    }

    /// 标记未读
    func markUnread(contentId: Int64) {
        execute("UPDATE content SET read_at = NULL WHERE id = ?", params: [contentId])
    }

    /// 切换星标，返回新状态
    @discardableResult
    func toggleStar(contentId: Int64) -> Bool {
        let cur = scalarInt("SELECT starred FROM content WHERE id = ?", params: [contentId]) ?? 0
        let new = cur == 1 ? 0 : 1
        execute("UPDATE content SET starred = ? WHERE id = ?", params: [new, contentId])
        return new == 1
    }

    /// 切换归档，返回新状态
    @discardableResult
    func toggleArchive(contentId: Int64) -> Bool {
        let cur = scalarInt("SELECT is_archived FROM content WHERE id = ?", params: [contentId]) ?? 0
        let new = cur == 1 ? 0 : 1
        execute("UPDATE content SET is_archived = ? WHERE id = ?", params: [new, contentId])
        return new == 1
    }

    /// 批量标已读（按条件：source/当前筛选）。返回影响条数。
    @discardableResult
    func markAllRead(source: String? = nil, minScore: Int? = nil, keyword: String? = nil) -> Int {
        var sql = "UPDATE content SET read_at = datetime('now') WHERE read_at IS NULL AND is_archived = 0"
        var conds: [String] = []
        if source != nil { conds.append("source = ?") }
        if minScore != nil { conds.append("llm_score >= ?") }
        if let kw = keyword, !kw.isEmpty { conds.append("(title LIKE ? OR excerpt LIKE ? OR content_md LIKE ?)") }
        if !conds.isEmpty { sql += " AND " + conds.joined(separator: " AND ") }
        execute(sql, params: buildMarkParams(source: source, minScore: minScore, keyword: keyword))
        return scalarInt("SELECT changes()") ?? 0
    }

    private func buildMarkParams(source: String?, minScore: Int?, keyword: String?) -> [Any?] {
        var params: [Any?] = []
        if let s = source { params.append(s) }
        if let m = minScore { params.append(m) }
        if let kw = keyword, !kw.isEmpty { let like = "%\(kw)%"; params.append(like); params.append(like); params.append(like) }
        return params
    }

    func totalCount() -> Int {
        guard open() else { return 0 }
        var stmt: OpaquePointer?
        var n = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM content;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int64(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return n
    }

    // MARK: 辅助

    private static func rowToItem(_ stmt: OpaquePointer?) -> ContentItem {
        func text(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: p)
        }
        func int64(_ i: Int32) -> Int64? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, i)
        }
        // meta 是第 15 列（索引 15），解析 audio_url / video_id
        var audioUrl: String? = nil
        if let metaStr = text(15), let data = metaStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            audioUrl = (obj["audio_url"] as? String) ?? (obj["video_url"] as? String)
        }
        return ContentItem(
            id: sqlite3_column_int64(stmt, 0),
            ctype: text(1) ?? "article",
            source: text(2) ?? "rss",
            title: text(3) ?? "(无标题)",
            author: text(4),
            url: text(5) ?? "",
            language: text(6),
            publishedAt: text(7),
            excerpt: text(8),
            contentMd: text(9),
            llmScore: int64(10).map { Int($0) },
            llmSummary: text(11),
            llmTranslatedMd: text(12),
            fetchStatus: int64(13).map { Int($0) } ?? 0,
            feedId: int64(14),
            audioUrl: audioUrl,
            readAt: text(16),
            starred: sqlite3_column_int(stmt, 17) == 1,
            archived: sqlite3_column_int(stmt, 18) == 1
        )
    }
}
