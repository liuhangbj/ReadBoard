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

    /// 相等/哈希只比 id——默认 Hashable 全字段参与，contentMd/llmTranslatedMd/excerpt
    /// 几十 KB 大字段让 items.contains(sel) 和 List.tag(item) 每次渲染都 hash 整个
    /// 结构体（300 条/页性能炸弹）。同一篇文章 id 唯一，比 id 即可（修 P0-4）。
    public static func == (lhs: ContentItem, rhs: ContentItem) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
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
    var imageUrl: String? = nil  // 首图（列表缩略图，从 content_html 抽）
    /// 原始 HTML（feed 给的 content_html，原网页视图用——点开阅读时查，列表轻列不取）
    var contentHtml: String? = nil
    /// feed 简介的中文翻译（播客三标签的「译文」——点开阅读时查，列表轻列不取）
    /// 已废弃——018 迁移后统一走 llm_translated_md
    @available(*, deprecated, message: "Use llm_translated_md instead")
    var excerptTranslated: String? = nil
    /// 列表标签用轻量标记（不扛译文全文/媒体地址，只存是否有）
    var hasTranslation: Bool = false  // 有译文（llm_translated_md 非空）
    var hasTranscript: Bool = false   // 有转录（llm_transcript_md 非空）
    var isMedia: Bool = false          // 媒体项（podcast/video/youtube/含 audio_url）
    /// 译文开头 120 字符（中栏标题显示中文用——llm_translated_md 第一行是中文标题）
    var translatedHead: String? = nil
    /// 标题的中文翻译（媒体项翻译时连标题一起翻——中栏/标题栏显示中文标题，列表轻列直查）
    var titleTranslated: String? = nil
    /// 有全文（content_md 非空）——全文 badge 用，列表轻列不扛 content_md 大字段
    var hasFulltext: Bool = false

    /// 返回一个标记为已读的副本（本地状态同步用）
    func markingRead() -> ContentItem {
        var copy = ContentItem(id: id, ctype: ctype, source: source, title: title, author: author,
                    url: url, language: language, publishedAt: publishedAt, excerpt: excerpt,
                    contentMd: contentMd, llmScore: llmScore, llmSummary: llmSummary,
                    llmTranslatedMd: llmTranslatedMd, fetchStatus: fetchStatus, feedId: feedId,
                    audioUrl: audioUrl, readAt: "now", starred: starred, archived: archived)
        copy.imageUrl = imageUrl
        copy.hasTranslation = hasTranslation
        copy.hasTranscript = hasTranscript
        copy.isMedia = isMedia
        copy.translatedHead = translatedHead
        copy.titleTranslated = titleTranslated
        copy.hasFulltext = hasFulltext
        return copy
    }

    /// 返回切换星标的副本
    func togglingStar() -> ContentItem {
        var copy = ContentItem(id: id, ctype: ctype, source: source, title: title, author: author,
                    url: url, language: language, publishedAt: publishedAt, excerpt: excerpt,
                    contentMd: contentMd, llmScore: llmScore, llmSummary: llmSummary,
                    llmTranslatedMd: llmTranslatedMd, fetchStatus: fetchStatus, feedId: feedId,
                    audioUrl: audioUrl, readAt: readAt, starred: !starred, archived: archived)
        copy.imageUrl = imageUrl
        copy.hasTranslation = hasTranslation
        copy.hasTranscript = hasTranscript
        copy.isMedia = isMedia
        copy.translatedHead = translatedHead
        copy.titleTranslated = titleTranslated
        copy.hasFulltext = hasFulltext
        return copy
    }

    /// 返回切换归档的副本
    func togglingArchive() -> ContentItem {
        var copy = ContentItem(id: id, ctype: ctype, source: source, title: title, author: author,
                    url: url, language: language, publishedAt: publishedAt, excerpt: excerpt,
                    contentMd: contentMd, llmScore: llmScore, llmSummary: llmSummary,
                    llmTranslatedMd: llmTranslatedMd, fetchStatus: fetchStatus, feedId: feedId,
                    audioUrl: audioUrl, readAt: readAt, starred: starred, archived: !archived)
        copy.imageUrl = imageUrl
        copy.hasTranslation = hasTranslation
        copy.hasTranscript = hasTranscript
        copy.isMedia = isMedia
        copy.translatedHead = translatedHead
        copy.titleTranslated = titleTranslated
        copy.hasFulltext = hasFulltext
        return copy
    }

    /// 填充正文的副本（点开阅读时 fetchContentBody 补大字段）
    /// 保留轻量字段（imageUrl/hasTranslation/isMedia/translatedHead/hasFulltext）——否则点开文章后中栏/右栏中文标题丢失
    func withBody(contentMd: String?, llmTranslatedMd: String?, audioUrl: String?, contentHtml: String? = nil, titleTranslated: String? = nil) -> ContentItem {
        var copy = ContentItem(id: id, ctype: ctype, source: source, title: title, author: author,
                    url: url, language: language, publishedAt: publishedAt, excerpt: excerpt,
                    contentMd: contentMd, llmScore: llmScore, llmSummary: llmSummary,
                    llmTranslatedMd: llmTranslatedMd, fetchStatus: fetchStatus, feedId: feedId,
                    audioUrl: audioUrl, readAt: readAt, starred: starred, archived: archived)
        copy.imageUrl = imageUrl
        copy.hasTranslation = hasTranslation
        copy.hasTranscript = hasTranscript
        copy.isMedia = isMedia
        copy.translatedHead = translatedHead
        copy.titleTranslated = titleTranslated ?? self.titleTranslated
        copy.hasFulltext = hasFulltext
        copy.contentHtml = contentHtml ?? self.contentHtml
        return copy
    }
}

public struct SourceGroup: Identifiable, Hashable {
    public var id: String { name }
    let name: String      // 显示名
    let kind: String      // 过滤用：source_id 或 folder_id（带前缀）
    let count: Int
}

/// 左栏树节点：文件夹（含子源）或独立源
public struct SidebarNode: Identifiable, Hashable {
    public let id: String
    let name: String
    let count: Int
    let unread: Int          // 未读数（角标）
    let isFolder: Bool
    let filterKey: String?       // 点击过滤用：source_id=N / folder_id=N / nil=全部
    let sourceId: Int64?         // 源 id（右键设置用，文件夹为 nil）
    let folderId: Int64?         // 文件夹 id（右键设置用）
    var children: [SidebarNode]?
}

// MARK: - SQLite 只读访问

public final class Database: @unchecked Sendable {
    static let shared = Database()
    /// 读连接：供 UI 查询（fetchContents/fetchSourceGroups/queryRows 等）
    private var db: OpaquePointer?
    /// 写连接：供写入（execute/upsertContent/markJob 等）。WAL 下读写并发互不阻塞
    private var wdb: OpaquePointer?

    /// 串行队列：所有写操作 + 事务统一排队执行。
    /// 修 P0-3（跨线程脏写）：@MainActor 服务与非隔离服务并发访问 db/wdb，
    /// FULLMUTEX 只保单条语句，多语句序列（事务、INSERT+lastInsertId）跨线程交错。
    /// 写路径全部走这个串行队列后，多语句序列原子化，不再交错。
    /// 修 P0-2（事务跨连接）：事务内的去重 SELECT 也强制走 wdb（同一连接），
    /// 不再走读连接 db（WAL 快照隔离下读连接看不到事务内写入）。
    private let writeQueue = DispatchQueue(label: "readboard.db.write")
    /// 当前是否在 writeQueue 上（事务内嵌套调用不重复入队，防死锁）
    private let queueKey = DispatchSpecificKey<Bool>()

    // 默认指向迁移好的库；可用环境变量覆盖便于测试
    private let dbPath: String = {
        if let p = ProcessInfo.processInfo.environment["READBOARD_DB"] { return p }
        return NSHomeDirectory() + "/readboard/Data/readboard.db"
    }()

    private init() {
        writeQueue.setSpecific(key: queueKey, value: true)
    }

    /// 是否在写队列上（事务/写操作内部）
    private var onWriteQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) == true
    }

    /// 配置一条连接的 pragma（WAL/同步级别/忙等/外键）
    private func configure(_ handle: OpaquePointer?) {
        var stmt: OpaquePointer?
        // foreign_keys：content_source.folder_id / content.source_id 有 ON DELETE SET NULL 声明，
        // 不开 pragma 外键不生效（SQLite 默认关），删文件夹/源时子行外键悬挂
        for sql in ["PRAGMA journal_mode=WAL;", "PRAGMA synchronous=NORMAL;",
                    "PRAGMA busy_timeout=5000;", "PRAGMA foreign_keys=ON;"] {
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
        // 按数字前缀排序而非字典序——字典序下 100_xxx 会排到 99_xxx 前面导致断裂
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: migDir)
            .filter({ $0.hasSuffix(".sql") })
            .sorted(by: { f1, f2 in
                let n1 = Int(f1.split(separator: "_").first ?? "") ?? 0
                let n2 = Int(f2.split(separator: "_").first ?? "") ?? 0
                return n1 != n2 ? n1 < n2 : f1 < f2
            }) else { return }
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

    // MARK: 事务（写连接 + 串行队列）

    /// 把多条写操作包进一个事务（BEGIN IMMEDIATE），任一步失败回滚。
    /// 串行队列执行：嵌套事务（已在队列上）直接跑不再入队防死锁。
    /// BEGIN 失败（busy_timeout 耗尽）返回 false，不静默继续（修 P0-2）。
    func transaction(_ block: () -> Bool) -> Bool {
        if onWriteQueue {
            return transactionInner(block)
        }
        return writeQueue.sync { transactionInner(block) }
    }

    private func transactionInner(_ block: () -> Bool) -> Bool {
        guard open() else { return false }
        // BEGIN 失败要返回 false——busy_timeout 耗尽时 BEGIN 失败，block 在事务外执行，
        // COMMIT 也失败，但旧实现却返回 true（静默错）。
        guard execRaw(wdb, "BEGIN IMMEDIATE;") else { return false }
        if block() {
            execRaw(wdb, "COMMIT;")
            return true
        } else {
            execRaw(wdb, "ROLLBACK;")
            return false
        }
    }

    // MARK: 写操作

    /// 执行无返回值的写 SQL（带参数绑定，走写连接 + 串行队列）。
    /// 嵌套（事务内/已在队列上）直接跑不入队防死锁。
    /// writeQueue.sync 阻塞调用方——需要返回值的场景用（多数在后台 worker）。
    @discardableResult
    func execute(_ sql: String, params: [Any?] = []) -> Bool {
        if onWriteQueue { return executeInner(sql, params: params) }
        return writeQueue.sync { executeInner(sql, params: params) }
    }

    /// UI 触发的单条写（标已读/星标/归档等）：writeQueue.async 不阻塞主线程。
    /// 复查发现 execute 的 sync 会让主线程等队列里的大任务（清理/批量插入）跑完，
    /// UI 卡顿（P0-3 修复的副作用）。UI 触发、不需立即知道结果的写用这个。
    /// 完成回调在 MainActor（供 UI 刷新状态）。
    func executeAsync(_ sql: String, params: [Any?] = [], completion: ((Bool) -> Void)? = nil) {
        if onWriteQueue {
            let ok = executeInner(sql, params: params)
            completion?(ok)
            return
        }
        writeQueue.async {
            let ok = self.executeInner(sql, params: params)
            if let completion {
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }

    private func executeInner(_ sql: String, params: [Any?]) -> Bool {
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
        // 事务内（在写队列上）强制走 wdb——读连接 db 在 WAL 快照隔离下看不到
        // 事务内写入，去重 SELECT 会失效（修 P0-2）。非事务走读连接（读写并发不阻塞）。
        let handle = onWriteQueue ? wdb : db
        var stmt: OpaquePointer?
        var result: Int?
        if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK {
            bindParams(stmt, params)
            if sqlite3_step(stmt) == SQLITE_ROW { result = Int(sqlite3_column_int64(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return result
    }

    /// 查询单个 String 值
    func scalarString(_ sql: String, params: [Any?] = []) -> String? {
        guard open() else { return nil }
        let handle = onWriteQueue ? wdb : db
        var stmt: OpaquePointer?
        var result: String?
        if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK {
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
        let handle = onWriteQueue ? wdb : db
        var stmt: OpaquePointer?
        var out: [[String: String]] = []
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
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

    /// 各 source 分组及数量（旧版按 ctype 分组，已废弃——左栏改用 fetchSidebarTree）
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

    /// 左栏树：文件夹（含子源）→ 无文件夹的独立源。count = 有效内容数，unread = 未读数。
    /// 这是订阅源视角的组织方式（你的文件夹结构），不是按内容类型分。
    func fetchSidebarTree() -> [SidebarNode] {
        guard open() else { return [] }
        // 文件夹 + 其下源 + 内容数/未读数。
        // ⚠️ 聚合 CTE 版（17:18 实测：1.693s → 21ms）：
        // 原版每个源两条相关子查询 COUNT(*)（302 源 × 2 = 604 次全表扫）；
        // 改为 content 单次分组聚合 + LEFT JOIN，配合迁移 017 覆盖索引只扫索引页。
        let folderRows = queryRows("""
            WITH agg AS (
                SELECT source_id,
                       SUM(CASE WHEN is_duplicate = 0 AND is_archived = 0 THEN 1 ELSE 0 END) AS n,
                       SUM(CASE WHEN is_duplicate = 0 AND is_archived = 0 AND read_at IS NULL THEN 1 ELSE 0 END) AS unread
                FROM content GROUP BY source_id
            )
            SELECT f.id AS fid, f.name AS fname, s.id AS sid, s.name AS sname,
                   COALESCE(agg.n, 0) AS n, COALESCE(agg.unread, 0) AS unread
            FROM folder f
            JOIN content_source s ON s.folder_id = f.id AND s.enabled = 1
            LEFT JOIN agg ON agg.source_id = s.id
            ORDER BY f.name, n DESC;
            """)
        // 无文件夹的独立源
        let orphanRows = queryRows("""
            WITH agg AS (
                SELECT source_id,
                       SUM(CASE WHEN is_duplicate = 0 AND is_archived = 0 THEN 1 ELSE 0 END) AS n,
                       SUM(CASE WHEN is_duplicate = 0 AND is_archived = 0 AND read_at IS NULL THEN 1 ELSE 0 END) AS unread
                FROM content GROUP BY source_id
            )
            SELECT s.id AS sid, s.name AS sname,
                   COALESCE(agg.n, 0) AS n, COALESCE(agg.unread, 0) AS unread
            FROM content_source s
            LEFT JOIN agg ON agg.source_id = s.id
            WHERE s.folder_id IS NULL AND s.enabled = 1
            ORDER BY n DESC;
            """)

        var tree: [SidebarNode] = []
        // 按文件夹聚合
        var folderMap: [Int64: (name: String, sources: [SidebarNode])] = [:]
        var folderOrder: [Int64] = []
        for r in folderRows {
            guard let fidStr = r["fid"], let fid = Int64(fidStr) else { continue }
            let fname = r["fname"] ?? "未命名"
            let sname = r["sname"] ?? "未命名源"
            let n = Int(r["n"] ?? "0") ?? 0
            let unread = Int(r["unread"] ?? "0") ?? 0
            let sid = Int64(r["sid"] ?? "0") ?? 0
            let sidStr = r["sid"] ?? ""
            let node = SidebarNode(id: "s\(sidStr)", name: sname, count: n, unread: unread,
                                   isFolder: false, filterKey: "source_id=\(sidStr)",
                                   sourceId: sid, folderId: fid, children: nil)
            if folderMap[fid] == nil {
                folderMap[fid] = (fname, [])
                folderOrder.append(fid)
            }
            folderMap[fid]?.sources.append(node)
        }
        for fid in folderOrder {
            guard let (fname, sources) = folderMap[fid] else { continue }
            let total = sources.reduce(0) { $0 + $1.count }
            let totalUnread = sources.reduce(0) { $0 + $1.unread }
            tree.append(SidebarNode(id: "f\(fid)", name: fname, count: total, unread: totalUnread,
                                    isFolder: true, filterKey: "folder_id=\(fid)",
                                    sourceId: nil, folderId: fid, children: sources))
        }
        // 独立源（无文件夹）
        for r in orphanRows {
            let sname = r["sname"] ?? "未命名源"
            let n = Int(r["n"] ?? "0") ?? 0
            let unread = Int(r["unread"] ?? "0") ?? 0
            let sid = Int64(r["sid"] ?? "0") ?? 0
            let sidStr = r["sid"] ?? ""
            tree.append(SidebarNode(id: "s\(sidStr)", name: sname, count: n, unread: unread,
                                    isFolder: false, filterKey: "source_id=\(sidStr)",
                                    sourceId: sid, folderId: nil, children: nil))
        }
        return tree
    }

    /// 拉取内容列表（轻列，不取正文 content_md/llm_translated_md/meta —— 正文点开再按 id 查）
    /// 可按 source/stype、sourceId、folderId 过滤 + 评分/未读/星标/归档/标签/关键词/处理状态筛选
    func fetchContents(source: String? = nil, sourceId: Int64? = nil, folderId: Int64? = nil,
                       minScore: Int? = nil, includeUnscored: Bool = false,
                       unreadOnly: Bool = false,
                       keyword: String? = nil, starredOnly: Bool = false,
                       archived: Bool = false, tagId: Int64? = nil,
                       processedFilters: [String: Int] = [:],
                       sortOrder: String = "newest",
                       limit: Int = 200, offset: Int = 0) -> [ContentItem] {
        guard open() else { return [] }
        let useFTS = (keyword?.isEmpty == false) && ftsAvailable()
        // 轻列：列表渲染够用，不扛正文。列序固定见 rowToListItem
        // content_html 只用于抽首图（缩略图），不进 ContentItem.contentMd
        var sql: String
        if useFTS {
            sql = """
            SELECT c.id, c.ctype, c.source, c.title, c.author, c.url, c.language, c.published_at,
                   c.excerpt, c.llm_score, c.llm_summary, c.fetch_status, c.read_at, c.starred, c.is_archived,
                   c.content_html,
                   (c.llm_translated_md IS NOT NULL AND c.llm_translated_md != '') AS has_trans,
                   (c.llm_transcript_md IS NOT NULL AND c.llm_transcript_md != '') AS has_transcript,
                   (c.ctype IN ('podcast','video','youtube') OR c.meta LIKE '%audio_url%') AS is_media,
                   substr(c.llm_translated_md, 1, 120) AS translated_head,
                   c.llm_title_translated AS title_translated,
                   (c.content_md IS NOT NULL AND LENGTH(c.content_md) > 500) AS has_fulltext,
                   (c.llm_excerpt_translated IS NOT NULL AND c.llm_excerpt_translated != '') AS has_excerpt_trans
            FROM content c JOIN content_fts f ON f.rowid = c.id
            """
        } else {
            sql = """
            SELECT id, ctype, source, title, author, url, language, published_at,
                   excerpt, llm_score, llm_summary, fetch_status, read_at, starred, is_archived,
                   content_html,
                   (llm_translated_md IS NOT NULL AND llm_translated_md != '') AS has_trans,
                   (llm_transcript_md IS NOT NULL AND llm_transcript_md != '') AS has_transcript,
                   (ctype IN ('podcast','video','youtube') OR meta LIKE '%audio_url%') AS is_media,
                   substr(llm_translated_md, 1, 120) AS translated_head,
                   llm_title_translated AS title_translated,
                   (content_md IS NOT NULL AND LENGTH(content_md) > 500) AS has_fulltext,
                   (llm_excerpt_translated IS NOT NULL AND llm_excerpt_translated != '') AS has_excerpt_trans
            FROM content
            """
        }
        // 修 P2-15：星标筛选跨归档——星标文章不管归档与否都该能在「星标」段看到，
        // 此前写死 is_archived=0/1 导致「星标+已归档」的文章任何分段都查不到。
        let archivedCond: String
        if starredOnly {
            archivedCond = "1=1"   // 星标段不看归档状态，活跃+归档星标都显示
        } else {
            archivedCond = useFTS ? "c.is_archived = \(archived ? 1 : 0)" : "is_archived = \(archived ? 1 : 0)"
        }
        var conds: [String] = [archivedCond]
        // 排除重复项——is_duplicate=1 的是同内容的副本，不该在列表里重复显示。
        // 与 totalCount/文件夹计数口径对齐（三处都 非归档+非重复），计数才相符。
        conds.append(useFTS ? "c.is_duplicate = 0" : "is_duplicate = 0")
        // 排除已删除（软删除 guid 留底防重抓，列表不显示）
        conds.append(useFTS ? "c.deleted_at IS NULL" : "deleted_at IS NULL")
        let col = useFTS ? "c." : ""
        if source != nil { conds.append("\(col)source = ?") }
        if sourceId != nil { conds.append("\(col)source_id = ?") }
        if folderId != nil {
            conds.append("\(col)source_id IN (SELECT id FROM content_source WHERE folder_id = ?)")
        }
        if minScore != nil {
            // 含未评分：未评分（NULL）也纳入，避免筛选把未评分文章藏掉
            conds.append(includeUnscored ? "(\(col)llm_score >= ? OR \(col)llm_score IS NULL)" : "\(col)llm_score >= ?")
        }
        if unreadOnly { conds.append("\(col)read_at IS NULL") }
        if starredOnly { conds.append("\(col)starred = 1") }
        if tagId != nil {
            conds.append("\(col)id IN (SELECT content_id FROM content_tag WHERE tag_id = ?)")
        }
        // 处理状态筛选（三态「或」关系——满足任一条件即纳入）：
        // 处理状态三态：0=不筛选 / 1=已处理（实色）/ 2=未处理（淡粉）
        // 每个键按自身状态追加独立条件；同键多状态不可能（单键单一值），跨键取 OR。
        if !processedFilters.isEmpty {
            var orConds: [String] = []
            for (key, st) in processedFilters where st != 0 {
                switch key {
                case "score":
                    orConds.append(st == 1 ? "\(col)llm_score IS NOT NULL"
                                           : "\(col)llm_score IS NULL")
                case "summary":
                    orConds.append(st == 1 ? "(\(col)llm_summary IS NOT NULL AND \(col)llm_summary != '')"
                                           : "(\(col)llm_summary IS NULL OR \(col)llm_summary = '')")
                case "translate":
                    orConds.append(st == 1 ? "(\(col)llm_translated_md IS NOT NULL AND \(col)llm_translated_md != '')"
                                           : "(\(col)llm_translated_md IS NULL OR \(col)llm_translated_md = '')")
                case "transcribe":
                    let sub = "(\(col)ctype IN ('podcast','video') OR \(col)meta LIKE '%audio_url%') AND \(col)llm_translated_md IS NOT NULL AND \(col)llm_translated_md != ''"
                    orConds.append(st == 1 ? "(\(sub))" : "(NOT (\(sub)))")
                default: break
                }
            }
            if !orConds.isEmpty {
                conds.append("(" + orConds.joined(separator: " OR ") + ")")
            }
        }
        if useFTS { conds.append("content_fts MATCH ?") }
        else if let kw = keyword, !kw.isEmpty {
            conds.append("(\(col)title LIKE ? OR \(col)excerpt LIKE ?)")
        }
        sql += " WHERE " + conds.joined(separator: " AND ")
        // 排序：
        // - 有关键词：按时间倒序（搜索场景用户找的是"那篇最近的"）
        // - newest（默认）：时间倒序，RSS 阅读器标准
        // - oldest：时间正序（从头读起）
        // - score：评分优先（已评分按分数排前，未评分沉底），高质量视图
        if keyword?.isEmpty == false {
            sql += " ORDER BY \(col)published_at DESC LIMIT ? OFFSET ?;"
        } else {
            switch sortOrder {
            case "oldest":
                sql += " ORDER BY \(col)published_at ASC LIMIT ? OFFSET ?;"
            case "score":
                sql += " ORDER BY (\(col)llm_score IS NULL), \(col)llm_score DESC, \(col)published_at DESC LIMIT ? OFFSET ?;"
            default: // newest
                sql += " ORDER BY \(col)published_at DESC LIMIT ? OFFSET ?;"
            }
        }

        var stmt: OpaquePointer?
        var items: [ContentItem] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            var idx: Int32 = 1
            let binder: (String) -> Void = { s in
                sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)); idx += 1
            }
            if let s = source { binder(s) }
            if let sid = sourceId { sqlite3_bind_int64(stmt, idx, sid); idx += 1 }
            if let fid = folderId { sqlite3_bind_int64(stmt, idx, fid); idx += 1 }
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
    /// 供手动 AI 按钮做开关判定：手动触发也尊重源级配置（用户关掉 AI 评分就是不想被评分）。
    func effectivePolicyFor(contentId: Int64) -> PipelinePolicy {
        // 管线纯按源处理——只读源自己的 config，不看文件夹
        guard let row = queryRows("""
            SELECT s.config AS src_cfg FROM content c
            JOIN content_source s ON c.source_id = s.id
            WHERE c.id = ?;
            """, params: [contentId]).first else { return PipelinePolicy() }
        return PipelinePolicy.from(configJson: row["src_cfg"] ?? "{}")
    }

    /// 按需取单篇正文 + 大字段（点开阅读时调用）。返回 (contentMd, llmTranslatedMd, audioUrl, contentHtml, titleTranslated, llmTranscriptMd, videoId)
    func fetchContentBody(id: Int64) -> (contentMd: String?, llmTranslatedMd: String?, audioUrl: String?, contentHtml: String?, titleTranslated: String?, llmTranscriptMd: String?, videoId: String?)? {
        let _tAll = Date()
        let isMain = Thread.isMainThread
        let _tOpen = Date()
        guard open() else { return nil }
        let openMs = Int(Date().timeIntervalSince(_tOpen) * 1000)
        var stmt: OpaquePointer?
        var result: (String?, String?, String?, String?, String?, String?, String?)?
        let _tPrep = Date()
        let prepOK = sqlite3_prepare_v2(db, "SELECT content_md, llm_translated_md, meta, content_html, llm_title_translated, llm_transcript_md FROM content WHERE id = ?", -1, &stmt, nil) == SQLITE_OK
        let prepMs = Int(Date().timeIntervalSince(_tPrep) * 1000)
        if prepOK {
            sqlite3_bind_int64(stmt, 1, id)
            let _tStep = Date()
            let stepped = sqlite3_step(stmt)
            let stepMs = Int(Date().timeIntervalSince(_tStep) * 1000)
            let totalMs = Int(Date().timeIntervalSince(_tAll) * 1000)
            if totalMs > 50 || isMain {
                Trace.w("fetchContentBody 慢/主线程 id=\(id) open=\(openMs)ms prepare=\(prepMs)ms step=\(stepMs)ms total=\(totalMs)ms 主线程=\(isMain)", category: "dblock")
            }
            if stepped == SQLITE_ROW {
                func text(_ i: Int32) -> String? {
                    guard let p = sqlite3_column_text(stmt, i) else { return nil }
                    return String(cString: p)
                }
                var audioUrl: String? = nil
                var videoId: String? = nil
                if let metaStr = text(2), let data = metaStr.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    audioUrl = (obj["audio_url"] as? String) ?? (obj["video_url"] as? String)
                    videoId = obj["video_id"] as? String
                }
                result = (text(0), text(1), audioUrl, text(3), text(4), text(5), videoId)
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    /// LLM 轻量字段（score/summary）——ReadingView 完成后刷新镜像用。
    /// （selectedItem 实例刻意不替换，item 里的这两字段会陈旧；单独小查询避免动 fetchContentBody 的元组签名。）
    func fetchLLMExtras(id: Int64) -> (score: Int?, summary: String?)? {
        guard open() else { return nil }
        var stmt: OpaquePointer?
        var result: (Int?, String?)?
        if sqlite3_prepare_v2(db, "SELECT llm_score, llm_summary FROM content WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, id)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let score = sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 0))
                var summary: String? = nil
                if let p = sqlite3_column_text(stmt, 1) { summary = String(cString: p) }
                result = (score, summary)
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

    /// 标记已读（写入当前时间）。UI 触发，executeAsync 不阻塞主线程。
    func markRead(contentId: Int64) {
        executeAsync("UPDATE content SET read_at = datetime('now') WHERE id = ?", params: [contentId])
    }

    /// 标记未读。UI 触发，executeAsync 不阻塞主线程。
    func markUnread(contentId: Int64) {
        executeAsync("UPDATE content SET read_at = NULL WHERE id = ?", params: [contentId])
    }

    /// 切换星标，返回新状态。返回值在写前已确定（读当前状态取反），
    /// 写入 executeAsync 不阻塞主线程——读（scalarInt）走读连接不排队，快。
    @discardableResult
    func toggleStar(contentId: Int64) -> Bool {
        let cur = scalarInt("SELECT starred FROM content WHERE id = ?", params: [contentId]) ?? 0
        let new = cur == 1 ? 0 : 1
        executeAsync("UPDATE content SET starred = ? WHERE id = ?", params: [new, contentId])
        return new == 1
    }

    /// 切换归档，返回新状态。同 toggleStar——返回值写前确定，写入 async 不阻塞。
    @discardableResult
    func toggleArchive(contentId: Int64) -> Bool {
        let cur = scalarInt("SELECT is_archived FROM content WHERE id = ?", params: [contentId]) ?? 0
        let new = cur == 1 ? 0 : 1
        executeAsync("UPDATE content SET is_archived = ? WHERE id = ?", params: [new, contentId])
        return new == 1
    }

    /// 批量标已读（按条件：source/当前筛选）。返回影响条数。
    /// 关键词语义与 fetchContents 对齐：FTS 可用走 MATCH（与列表口径一致），否则 LIKE 回退。
    /// archived 参数对齐当前视图——归档视图点「全部已读」也生效（修 P0-5：
    /// 此前写死 is_archived=0，归档视图静默 0 条）。
    @discardableResult
    func markAllRead(source: String? = nil, sourceId: Int64? = nil, folderId: Int64? = nil,
                     minScore: Int? = nil, keyword: String? = nil, archived: Bool = false) -> Int {
        var sql = "UPDATE content SET read_at = datetime('now') WHERE read_at IS NULL AND is_archived = \(archived ? 1 : 0)"
        var conds: [String] = []
        if source != nil { conds.append("source = ?") }
        if sourceId != nil { conds.append("source_id = ?") }
        if folderId != nil { conds.append("source_id IN (SELECT id FROM content_source WHERE folder_id = ?)") }
        if minScore != nil { conds.append("llm_score >= ?") }
        let useFTS = (keyword?.isEmpty == false) && ftsAvailable()
        if useFTS {
            conds.append("id IN (SELECT rowid FROM content_fts WHERE content_fts MATCH ?)")
        } else if let kw = keyword, !kw.isEmpty {
            conds.append("(title LIKE ? OR excerpt LIKE ? OR content_md LIKE ?)")
        }
        if !conds.isEmpty { sql += " AND " + conds.joined(separator: " AND ") }
        execute(sql, params: buildMarkParams(source: source, sourceId: sourceId, folderId: folderId,
                                             minScore: minScore, keyword: keyword, useFTS: useFTS))
        return writeChanges()
    }

    private func buildMarkParams(source: String?, sourceId: Int64?, folderId: Int64?,
                                 minScore: Int?, keyword: String?, useFTS: Bool) -> [Any?] {
        var params: [Any?] = []
        if let s = source { params.append(s) }
        if let sid = sourceId { params.append(Int(sid)) }
        if let fid = folderId { params.append(Int(fid)) }
        if let m = minScore { params.append(m) }
        if useFTS, let kw = keyword {
            params.append(ftsQuery(kw))
        } else if let kw = keyword, !kw.isEmpty {
            let like = "%\(kw)%"; params.append(like); params.append(like); params.append(like)
        }
        return params
    }

    /// 「全部文章」计数——口径与文件夹计数对齐（活跃有效：非归档+非重复）。
    /// 此前 SELECT COUNT(*) 数全部内容（含归档+重复），比文件夹计数总和大，
    /// 用户看到「全部文章 12882 ≠ 文件夹总和 12874」（差 8 = 3 归档 + 5 重复）。
    /// 点「全部文章」看的就是活跃列表，计数应对齐。
    func totalCount() -> Int {
        guard open() else { return 0 }
        var stmt: OpaquePointer?
        var n = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM content WHERE is_archived = 0 AND is_duplicate = 0;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int64(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return n
    }

    /// 「全部文章」未读数——与 totalCount 同口径（活跃有效 + 未读）。
    /// 全部文章行显示「未读/总数」，和文件夹行的计数格式一致。
    func totalUnread() -> Int {
        guard open() else { return 0 }
        var stmt: OpaquePointer?
        var n = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM content WHERE is_archived = 0 AND is_duplicate = 0 AND read_at IS NULL;", -1, &stmt, nil) == SQLITE_OK {
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
        var item = ContentItem(
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
        // 抽首图（列 15 content_html，可能不存在——旧查询无此列时容错）
        if sqlite3_column_count(stmt) > 15, let html = text(15) {
            item.imageUrl = Self.firstImageUrl(in: html)
        }
        // 列表标签轻量标记（列 16 has_trans / 列 17 has_transcript / 列 18 is_media / 列 19 translated_head / 列 20 title_translated / 列 21 has_fulltext / 列 22 has_excerpt_trans）
        if sqlite3_column_count(stmt) > 17 {
            item.hasTranslation = sqlite3_column_int(stmt, 16) == 1
            item.hasTranscript = sqlite3_column_int(stmt, 17) == 1
        }
        if sqlite3_column_count(stmt) > 18 {
            item.isMedia = sqlite3_column_int(stmt, 18) == 1
        }
        if sqlite3_column_count(stmt) > 19 {
            item.translatedHead = text(19)
        }
        if sqlite3_column_count(stmt) > 20 {
            item.titleTranslated = text(20)
        }
        if sqlite3_column_count(stmt) > 21 {
            item.hasFulltext = sqlite3_column_int(stmt, 21) == 1
        }
        // col 22 (has_excerpt_trans) kept in SQL for column offset stability; no longer used
        return item
    }

    /// 从 HTML 抽第一个 img src（列表缩略图用）
    static func firstImageUrl(in html: String) -> String? {
        guard let range = html.range(of: "<img[^>]+src=[\"']([^\"']+)[\"']",
                                     options: .regularExpression) else { return nil }
        let tag = String(html[range])
        guard let srcRange = tag.range(of: "src=[\"']([^\"']+)[\"']",
                                       options: .regularExpression) else { return nil }
        var src = String(tag[srcRange])
        src = src.replacingOccurrences(of: "src=[\"']", with: "", options: .regularExpression)
        src = src.replacingOccurrences(of: "[\"']$", with: "", options: .regularExpression)
        return src.hasPrefix("http") ? src : nil
    }
}
