import Foundation
import SQLite3

// MARK: - 数据模型

public struct ContentItem: Identifiable, Hashable {
    public let id: Int64
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

    /// 填充正文的副本（点开阅读时 fetchContentBody 补大字段）
    func withBody(contentMd: String?, llmTranslatedMd: String?, audioUrl: String?) -> ContentItem {
        ContentItem(id: id, ctype: ctype, source: source, title: title, author: author,
                    url: url, language: language, publishedAt: publishedAt, excerpt: excerpt,
                    contentMd: contentMd, llmScore: llmScore, llmSummary: llmSummary,
                    llmTranslatedMd: llmTranslatedMd, fetchStatus: fetchStatus, feedId: feedId,
                    audioUrl: audioUrl, readAt: readAt, starred: starred, archived: archived)
    }
}

public struct SourceGroup: Identifiable, Hashable {
    public var id: String { name }
    let name: String      // source 或 feed 显示名
    let kind: String      // rss / podcast / youtube / wechat
    let count: Int
}

// MARK: - SQLite 只读访问

public final class Database: @unchecked Sendable {
    static let shared = Database()
    /// 读连接：供 UI 查询（fetchContents/fetchSourceGroups/queryRows 等）
    private var db: OpaquePointer?
    /// 写连接：供写入（execute/upsertContent/markJob 等）。WAL 下读写并发互不阻塞
    private var wdb: OpaquePointer?

    // 默认指向迁移好的库；可用环境变量覆盖便于测试
    private let dbPath: String = {
        if let p = ProcessInfo.processInfo.environment["READBOARD_DB"] { return p }
        return NSHomeDirectory() + "/readboard/Data/readboard.db"
    }()

    private init() {}

    /// 配置一条连接的 pragma（WAL/同步级别/忙等）
    private func configure(_ handle: OpaquePointer?) {
        var stmt: OpaquePointer?
        for sql in ["PRAGMA journal_mode=WAL;", "PRAGMA synchronous=NORMAL;", "PRAGMA busy_timeout=5000;"] {
            if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            stmt = nil
        }
    }

    @discardableResult
    func open() -> Bool {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        // 读连接
        if db == nil {
            if sqlite3_open_v2(dbPath, &db, flags, nil) != SQLITE_OK {
                sqlite3_close(db); db = nil
            } else {
                configure(db)
                runMigrations()
            }
        }
        // 写连接
        if wdb == nil {
            if sqlite3_open_v2(dbPath, &wdb, flags, nil) != SQLITE_OK {
                sqlite3_close(wdb); wdb = nil
            } else {
                configure(wdb)
            }
        }
        return db != nil && wdb != nil
    }

    // MARK: 迁移机制（PRAGMA user_version 版本化执行 Data/migrations/*.sql）
    // 每次启动检查版本，按文件名顺序补跑未执行的迁移。WAL/FTS/索引/export 表都走这里挂载。

    private func runMigrations() {
        guard let handle = db else { return }
        let current = intVal(handle, "PRAGMA user_version;") ?? 0
        let migDir = NSHomeDirectory() + "/readboard/Data/migrations"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: migDir)
            .filter({ $0.hasSuffix(".sql") }).sorted() else { return }
        var version = current
        for file in files {
            // 文件名形如 009_export.sql → 版本号 9
            let numStr = file.split(separator: "_").first.map(String.init) ?? "0"
            guard let num = Int(numStr), num > current else { continue }
            guard let sql = try? String(contentsOfFile: "\(migDir)/\(file)", encoding: .utf8) else { continue }
            var allOK = true
            for statement in Self.splitSQLStatements(sql) {
                // ALTER TABLE ADD COLUMN 幂等化：列已存在则跳过（此前部分失败后重试会
                // 因 duplicate column 永远失败，user_version 卡死，后续迁移全不跑）
                if Self.isRedundantAddColumn(handle, statement) {
                    fputs("[migration] ℹ \(file): 列已存在，跳过 ADD COLUMN\n", stderr)
                    continue
                }
                if !execRaw(handle, statement) {
                    allOK = false
                    let err = String(cString: sqlite3_errmsg(handle))
                    // 迁移失败必须可见——静默跳过会导致索引/表缺失而无人知晓（011 dedup 索引曾因此缺位）
                    fputs("[migration] ⚠ \(file) 执行失败: \(err)\n  语句: \(statement.prefix(120))\n", stderr)
                }
            }
            // 只在全部成功时才推进版本；部分失败保持版本让下次重试
            if allOK {
                version = max(version, num)
            } else {
                fputs("[migration] ⚠ \(file) 有语句失败，user_version 不推进，下次启动重试\n", stderr)
                break
            }
        }
        if version != current {
            execRaw(handle, "PRAGMA user_version = \(version);")
        }
    }

    @discardableResult
    private func execRaw(_ handle: OpaquePointer?, _ sql: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        let rc = sqlite3_step(stmt)   // 只 step 一次（DDL→DONE；INSERT rebuild→DONE；查询类→ROW 也只取首步）
        sqlite3_finalize(stmt)
        return rc == SQLITE_DONE || rc == SQLITE_ROW
    }

    /// 判断一条 SQL 是否是"目标列已存在的 ADD COLUMN"——是则跳过（幂等迁移）。
    /// 解析 `ALTER TABLE <table> ADD COLUMN <col> ...`，查 PRAGMA table_info。
    private static func isRedundantAddColumn(_ handle: OpaquePointer?, _ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        // 正则抓表名和列名（容忍反引号/双引号包裹）
        let pattern = #"^\s*ALTER\s+TABLE\s+[`"']?(\w+)[`"']?\s+ADD\s+COLUMN\s+[`"']?(\w+)[`"']?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let m = re.firstMatch(in: trimmed, range: range),
              m.numberOfRanges >= 3,
              let tRange = Range(m.range(at: 1), in: trimmed),
              let cRange = Range(m.range(at: 2), in: trimmed) else { return false }
        let table = String(trimmed[tRange])
        let column = String(trimmed[cRange])
        // PRAGMA table_info 查列是否存在
        var stmt: OpaquePointer?
        let pragma = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(handle, pragma, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let p = sqlite3_column_text(stmt, 1) {
                let name = String(cString: p)
                if name.caseInsensitiveCompare(column) == .orderedSame { return true }
            }
        }
        return false
    }

    private func intVal(_ handle: OpaquePointer?, _ sql: String) -> Int? {
        var stmt: OpaquePointer?
        var r: Int?
        if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { r = Int(sqlite3_column_int64(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return r
    }

    /// 把迁移 .sql 按语句边界切分。普通语句以 ; 结尾；
    /// CREATE TRIGGER ... BEGIN ... END 是块，块内 ; 不是结束，整块到 END; 才算一条。
    static func splitSQLStatements(_ sql: String) -> [String] {
        var statements: [String] = []
        var current = ""
        var inTrigger = false
        // 去掉 -- 行注释，避免注释里的 ; 干扰
        let lines = sql.components(separatedBy: "\n").map { line -> String in
            if let range = line.range(of: "--") { return String(line[..<range.lowerBound]) }
            return line
        }
        let cleaned = lines.joined(separator: "\n")
        for rawLine in cleaned.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let upper = trimmed.uppercased()
            if upper.hasPrefix("CREATE TRIGGER") || upper.hasPrefix("CREATE TEMP TRIGGER") {
                inTrigger = true
            }
            current += rawLine + "\n"
            if inTrigger {
                // 触发器块以 END; 收尾
                if upper.hasPrefix("END") && trimmed.hasSuffix(";") {
                    let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { statements.append(s) }
                    current = ""
                    inTrigger = false
                }
            } else if trimmed.hasSuffix(";") {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { statements.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { statements.append(tail) }
        // 去掉结尾分号（execRaw 单条 prepare 不需要）
        return statements.map { $0.hasSuffix(";") ? String($0.dropLast()) : $0 }
    }

    func close() {
        sqlite3_close(db); db = nil
        sqlite3_close(wdb); wdb = nil
    }

    // MARK: 事务（写连接）

    /// 把多条写操作包进一个事务（BEGIN IMMEDIATE），任一步失败回滚
    func transaction(_ block: () -> Bool) -> Bool {
        guard open() else { return false }
        execRaw(wdb, "BEGIN IMMEDIATE;")
        if block() {
            execRaw(wdb, "COMMIT;")
            return true
        } else {
            execRaw(wdb, "ROLLBACK;")
            return false
        }
    }

    // MARK: 写操作

    /// 执行无返回值的写 SQL（带参数绑定，走写连接）
    @discardableResult
    func execute(_ sql: String, params: [Any?] = []) -> Bool {
        guard open() else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(wdb, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        bindParams(stmt, params)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    /// 写连接上的 changes()（紧跟 execute 调用，返回刚影响的行数）
    func writeChanges() -> Int {
        intVal(wdb, "SELECT changes();") ?? 0
    }

    /// 写连接上的标量 Int——last_insert_rowid()/changes() 这类"本次写入的会话状态"
    /// 必须在写连接上查，走读连接会拿到错的值（读写双连接下读连接没有这次插入的上下文）
    func writeScalarInt(_ sql: String, params: [Any?] = []) -> Int? {
        guard open() else { return nil }
        var stmt: OpaquePointer?
        var result: Int?
        if sqlite3_prepare_v2(wdb, sql, -1, &stmt, nil) == SQLITE_OK {
            bindParams(stmt, params)
            if sqlite3_step(stmt) == SQLITE_ROW { result = Int(sqlite3_column_int64(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return result
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

    /// 最后插入行的 rowid（写连接）
    func lastInsertId() -> Int64 {
        sqlite3_last_insert_rowid(wdb)
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

    /// 拉取内容列表（轻列，不取正文 content_md/llm_translated_md/meta —— 正文点开再按 id 查）
    /// 可按 source 过滤、评分筛选、未读过滤、关键词搜索(FTS5)、星标/归档筛选
    func fetchContents(source: String? = nil, minScore: Int? = nil, includeUnscored: Bool = false,
                       unreadOnly: Bool = false,
                       keyword: String? = nil, starredOnly: Bool = false,
                       archived: Bool = false, tagId: Int64? = nil, limit: Int = 200,
                       offset: Int = 0) -> [ContentItem] {
        guard open() else { return [] }
        let useFTS = (keyword?.isEmpty == false) && ftsAvailable()
        // 轻列：列表渲染够用，不扛正文。列序固定见 rowToListItem
        var sql: String
        if useFTS {
            sql = """
            SELECT c.id, c.ctype, c.source, c.title, c.author, c.url, c.language, c.published_at,
                   c.excerpt, c.llm_score, c.llm_summary, c.fetch_status, c.read_at, c.starred, c.is_archived
            FROM content c JOIN content_fts f ON f.rowid = c.id
            """
        } else {
            sql = """
            SELECT id, ctype, source, title, author, url, language, published_at,
                   excerpt, llm_score, llm_summary, fetch_status, read_at, starred, is_archived
            FROM content
            """
        }
        var conds: [String] = [useFTS ? "c.is_archived = \(archived ? 1 : 0)" : "is_archived = \(archived ? 1 : 0)"]
        let col = useFTS ? "c." : ""
        if source != nil { conds.append("\(col)source = ?") }
        if minScore != nil {
            // 含未评分：未评分（NULL）也纳入，避免筛选把未评分文章藏掉
            conds.append(includeUnscored ? "(\(col)llm_score >= ? OR \(col)llm_score IS NULL)" : "\(col)llm_score >= ?")
        }
        if unreadOnly { conds.append("\(col)read_at IS NULL") }
        if starredOnly { conds.append("\(col)starred = 1") }
        if tagId != nil {
            conds.append("\(col)id IN (SELECT content_id FROM content_tag WHERE tag_id = ?)")
        }
        if useFTS { conds.append("content_fts MATCH ?") }
        else if let kw = keyword, !kw.isEmpty {
            conds.append("(\(col)title LIKE ? OR \(col)excerpt LIKE ?)")
        }
        sql += " WHERE " + conds.joined(separator: " AND ")
        // 有关键词时按发布时间倒序（搜索场景用户找的是"那篇最近的"，不是评分最高的）；
        // 无关键词保持评分优先（高质量文章置顶）
        if keyword?.isEmpty == false {
            sql += " ORDER BY \(col)published_at DESC LIMIT ? OFFSET ?;"
        } else {
            sql += " ORDER BY (\(col)llm_score IS NULL), \(col)llm_score DESC, \(col)published_at DESC LIMIT ? OFFSET ?;"
        }

        var stmt: OpaquePointer?
        var items: [ContentItem] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            var idx: Int32 = 1
            let binder: (String) -> Void = { s in
                sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)); idx += 1
            }
            if let s = source { binder(s) }
            if let m = minScore { sqlite3_bind_int64(stmt, idx, Int64(m)); idx += 1 }
            if let t = tagId { sqlite3_bind_int64(stmt, idx, t); idx += 1 }
            if useFTS {
                binder(ftsQuery(keyword!))
            } else if let kw = keyword, !kw.isEmpty {
                let like = "%\(kw)%"; binder(like); binder(like)
            }
            sqlite3_bind_int64(stmt, idx, Int64(limit)); idx += 1
            sqlite3_bind_int64(stmt, idx, Int64(offset))

            while sqlite3_step(stmt) == SQLITE_ROW {
                items.append(Self.rowToListItem(stmt))
            }
        }
        sqlite3_finalize(stmt)
        return items
    }

    /// 某内容的有效管线开关（源 OR 文件夹）。source_id 为 NULL（存量/异常）→ 全关。
    /// 供手动 AI 按钮做开关判定：手动触发也尊重源级配置（用户关掉打分就是不想被打分）。
    func effectivePolicyFor(contentId: Int64) -> PipelinePolicy {
        guard let row = queryRows("""
            SELECT s.config AS src_cfg, f.config AS folder_cfg FROM content c
            JOIN content_source s ON c.source_id = s.id
            LEFT JOIN folder f ON s.folder_id = f.id
            WHERE c.id = ?;
            """, params: [contentId]).first else { return PipelinePolicy() }
        let sp = PipelinePolicy.from(configJson: row["src_cfg"] ?? "{}")
        let fp = PipelinePolicy.from(configJson: row["folder_cfg"] ?? "{}")
        return PipelinePolicy(
            autoScore: sp.autoScore || fp.autoScore,
            autoTranslate: sp.autoTranslate || fp.autoTranslate,
            autoTranscribe: sp.autoTranscribe || fp.autoTranscribe,
            autoSummarize: sp.autoSummarize || fp.autoSummarize)
    }

    /// 按需取单篇正文 + 大字段（点开阅读时调用）。返回 (contentMd, llmTranslatedMd, audioUrl)
    func fetchContentBody(id: Int64) -> (contentMd: String?, llmTranslatedMd: String?, audioUrl: String?)? {
        guard open() else { return nil }
        var stmt: OpaquePointer?
        var result: (String?, String?, String?)?
        if sqlite3_prepare_v2(db, "SELECT content_md, llm_translated_md, meta FROM content WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, id)
            if sqlite3_step(stmt) == SQLITE_ROW {
                func text(_ i: Int32) -> String? {
                    guard let p = sqlite3_column_text(stmt, i) else { return nil }
                    return String(cString: p)
                }
                var audioUrl: String? = nil
                if let metaStr = text(2), let data = metaStr.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    audioUrl = (obj["audio_url"] as? String) ?? (obj["video_url"] as? String)
                }
                result = (text(0), text(1), audioUrl)
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    // MARK: FTS5 搜索

    /// FTS 表是否已建（迁移 010 建）。未建则退回 LIKE 标题/摘要。
    private func ftsAvailable() -> Bool {
        intVal(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='content_fts';") == 1
    }

    /// 把用户关键词转成 FTS5 MATCH 查询（多词 AND，加前缀匹配）。
    /// 只保留 FTS 安全字符（字母/数字/CJK/下划线/连字符），其余（引号/括号/冒号/AND/OR/NEAR 等
    /// FTS 运算符）一律丢弃——防止用户输入 `"/NEAR` 之类直接打崩 MATCH 语法。
    private func ftsQuery(_ kw: String) -> String {
        let terms = kw.split(whereSeparator: { $0 == " " || $0 == "　" })
            .map { Self.sanitizeFTSWord(String($0)) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "\"\"" }
        return terms.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    /// 单词级清洗：剥离 FTS5 特殊字符，只留可匹配字符
    private static func sanitizeFTSWord(_ w: String) -> String {
        String(w.unicodeScalars.filter { s in
            CharacterSet.alphanumerics.contains(s)
            || (0x4E00...0x9FFF).contains(Int(s.value))   // CJK
            || (0x3400...0x4DBF).contains(Int(s.value))   // CJK 扩展A
            || s == "_" || s == "-"
        })
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
    /// 关键词语义与 fetchContents 对齐：FTS 可用走 MATCH（与列表口径一致），否则 LIKE 回退。
    @discardableResult
    func markAllRead(source: String? = nil, minScore: Int? = nil, keyword: String? = nil) -> Int {
        var sql = "UPDATE content SET read_at = datetime('now') WHERE read_at IS NULL AND is_archived = 0"
        var conds: [String] = []
        if source != nil { conds.append("source = ?") }
        if minScore != nil { conds.append("llm_score >= ?") }
        let useFTS = (keyword?.isEmpty == false) && ftsAvailable()
        if useFTS {
            conds.append("id IN (SELECT rowid FROM content_fts WHERE content_fts MATCH ?)")
        } else if let kw = keyword, !kw.isEmpty {
            conds.append("(title LIKE ? OR excerpt LIKE ? OR content_md LIKE ?)")
        }
        if !conds.isEmpty { sql += " AND " + conds.joined(separator: " AND ") }
        execute(sql, params: buildMarkParams(source: source, minScore: minScore, keyword: keyword, useFTS: useFTS))
        return writeChanges()
    }

    private func buildMarkParams(source: String?, minScore: Int?, keyword: String?, useFTS: Bool) -> [Any?] {
        var params: [Any?] = []
        if let s = source { params.append(s) }
        if let m = minScore { params.append(m) }
        if useFTS, let kw = keyword {
            params.append(ftsQuery(kw))
        } else if let kw = keyword, !kw.isEmpty {
            let like = "%\(kw)%"; params.append(like); params.append(like); params.append(like)
        }
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

    /// 轻列列表行 → ContentItem（正文/audioUrl 留空，点开时 fetchContentBody 补）
    /// 列序：id,ctype,source,title,author,url,language,published_at,excerpt,llm_score,llm_summary,fetch_status,read_at,starred,is_archived
    private static func rowToListItem(_ stmt: OpaquePointer?) -> ContentItem {
        func text(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: p)
        }
        func int64(_ i: Int32) -> Int64? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, i)
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
            contentMd: nil,                 // 正文点开再查
            llmScore: int64(9).map { Int($0) },
            llmSummary: text(10),
            llmTranslatedMd: nil,           // 译文点开再查
            fetchStatus: int64(11).map { Int($0) } ?? 0,
            feedId: nil,
            audioUrl: nil,                  // 媒体地址点开再查
            readAt: text(12),
            starred: sqlite3_column_int(stmt, 13) == 1,
            archived: sqlite3_column_int(stmt, 14) == 1
        )
    }
}
