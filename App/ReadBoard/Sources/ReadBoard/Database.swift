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

    /// 拉取内容列表（可按 source 过滤、按评分/时间排序）
    func fetchContents(source: String? = nil, minScore: Int? = nil, limit: Int = 200) -> [ContentItem] {
        guard open() else { return [] }
        var sql = """
        SELECT id, ctype, source, title, author, url, language, published_at,
               excerpt, content_md, llm_score, llm_summary, llm_translated_md, fetch_status, feed_id, meta
        FROM content
        """
        var conds: [String] = []
        if source != nil { conds.append("source = ?") }
        if minScore != nil { conds.append("llm_score >= ?") }
        if !conds.isEmpty { sql += " WHERE " + conds.joined(separator: " AND ") }
        // 有评分的优先，再按发布时间倒序
        sql += " ORDER BY (llm_score IS NULL), llm_score DESC, published_at DESC LIMIT ?;"

        var stmt: OpaquePointer?
        var items: [ContentItem] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            var idx: Int32 = 1
            if let s = source { sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)); idx += 1 }
            if let m = minScore { sqlite3_bind_int64(stmt, idx, Int64(m)); idx += 1 }
            sqlite3_bind_int64(stmt, idx, Int64(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                items.append(Self.rowToItem(stmt))
            }
        }
        sqlite3_finalize(stmt)
        return items
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
            audioUrl: audioUrl
        )
    }
}
