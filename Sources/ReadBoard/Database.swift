import Foundation
import SQLite3

// MARK: - 数据模型

public struct ContentItem: Identifiable, Hashable, Sendable {
    public let id: Int64
    let ctype: String
    let source: String
    /// 订阅源名称；source 仍保留 rss/podcast/youtube 等平台标识。
    var sourceName: String? = nil
    /// 订阅源真实平台类型（content_source.stype）；列表平台图标以它为准，
    /// 不再使用内容 ctype 或历史 content.source。
    var sourceStype: String? = nil
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
    var feedId: Int64?
    let audioUrl: String?     // 播客/视频的音频流地址（来自 meta.audio_url）
    let readAt: String?       // 已读时间，nil = 未读
    var isRead: Bool { readAt != nil }
    let starred: Bool         // 星标
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
    var hasExport: Bool = false   // 已导出（export_record 有记录）
    var hasUnmetProcessing: Bool = false // 尚未达到条目 auto_* 所要求的处理标准
    /// 平台访问限制（当前用于 B站付费/充电专属试看）。
    var accessState: String? = nil

/// 返回一个标记为已读的副本（本地状态同步用）
    func markingRead() -> ContentItem {
        var copy = ContentItem(id: id, ctype: ctype, source: source, title: title, author: author,
                    url: url, language: language, publishedAt: publishedAt, excerpt: excerpt,
                    contentMd: contentMd, llmScore: llmScore, llmSummary: llmSummary,
                    llmTranslatedMd: llmTranslatedMd, fetchStatus: fetchStatus, feedId: feedId,
                    audioUrl: audioUrl, readAt: "now", starred: starred)
        copy.imageUrl = imageUrl
        copy.sourceName = sourceName
        copy.sourceStype = sourceStype
        copy.hasTranslation = hasTranslation
        copy.hasTranscript = hasTranscript
        copy.isMedia = isMedia
        copy.translatedHead = translatedHead
        copy.titleTranslated = titleTranslated
        copy.hasFulltext = hasFulltext
        copy.hasExport = hasExport
        copy.hasUnmetProcessing = hasUnmetProcessing
        copy.accessState = accessState
        return copy
    }

    /// 返回切换星标的副本
    func togglingStar() -> ContentItem {
        var copy = ContentItem(id: id, ctype: ctype, source: source, title: title, author: author,
                    url: url, language: language, publishedAt: publishedAt, excerpt: excerpt,
                    contentMd: contentMd, llmScore: llmScore, llmSummary: llmSummary,
                    llmTranslatedMd: llmTranslatedMd, fetchStatus: fetchStatus, feedId: feedId,
                    audioUrl: audioUrl, readAt: readAt, starred: !starred)
        copy.imageUrl = imageUrl
        copy.sourceName = sourceName
        copy.sourceStype = sourceStype
        copy.hasTranslation = hasTranslation
        copy.hasTranscript = hasTranscript
        copy.isMedia = isMedia
        copy.translatedHead = translatedHead
        copy.titleTranslated = titleTranslated
        copy.hasFulltext = hasFulltext
        copy.hasExport = hasExport
        copy.hasUnmetProcessing = hasUnmetProcessing
        copy.accessState = accessState
        return copy
    }

    /// 填充正文的副本（点开阅读时 fetchContentBody 补大字段）
    /// 保留轻量字段（imageUrl/hasTranslation/isMedia/translatedHead/hasFulltext）——否则点开文章后中栏/右栏中文标题丢失
    func withBody(contentMd: String?, llmTranslatedMd: String?, audioUrl: String?, contentHtml: String? = nil, titleTranslated: String? = nil) -> ContentItem {
        var copy = ContentItem(id: id, ctype: ctype, source: source, title: title, author: author,
                    url: url, language: language, publishedAt: publishedAt, excerpt: excerpt,
                    contentMd: contentMd, llmScore: llmScore, llmSummary: llmSummary,
                    llmTranslatedMd: llmTranslatedMd, fetchStatus: fetchStatus, feedId: feedId,
                    audioUrl: audioUrl, readAt: readAt, starred: starred)
        copy.imageUrl = imageUrl
        copy.sourceName = sourceName
        copy.sourceStype = sourceStype
        copy.hasTranslation = hasTranslation
        copy.hasTranscript = hasTranscript
        copy.isMedia = isMedia
        copy.translatedHead = translatedHead
        copy.titleTranslated = titleTranslated ?? self.titleTranslated
        copy.hasFulltext = hasFulltext
        copy.contentHtml = contentHtml ?? self.contentHtml
        copy.hasExport = hasExport
        copy.hasUnmetProcessing = hasUnmetProcessing
        copy.accessState = accessState
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
public struct SidebarNode: Identifiable, Hashable, Sendable {
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

struct LibraryCounts: Sendable {
    var total = 0
    var unread = 0
    var pending = 0
    var pendingUnread = 0
    var exported = 0
    var exportedUnread = 0
    var articles = 0
    var articleUnread = 0
    var podcasts = 0
    var podcastUnread = 0
    var videos = 0
    var videoUnread = 0
}

struct ReaderPayload: Sendable {
    let contentMd: String?
    let llmTranslatedMd: String?
    let audioUrl: String?
    let titleTranslated: String?
    let llmTranscriptMd: String?
    let videoId: String?
    let score: Int?
    let summary: String?
}

// MARK: - SQLite 只读访问

public final class Database: @unchecked Sendable {
    /// sqlite 绑定参数只允许 bindParams 支持的不可变标量。用受控盒跨写队列传递，
    /// 避免把开放的 `[Any?]` 直接捕获进 @Sendable closure。
    private struct SQLParameters: @unchecked Sendable {
        let values: [Any?]
    }

    static let shared = Database()
    /// 读连接：供 UI 查询（fetchContents/fetchSourceGroups/queryRows 等）
    private var db: OpaquePointer?
    /// 写连接：供写入（execute/upsertContent/markJob 等）。WAL 下读写并发互不阻塞
    private var wdb: OpaquePointer?
    /// 阅读器专用读连接。列表统计、Worker 扫描再慢，也不能占住点文章所需的连接。
    private var readerDB: OpaquePointer?
    /// 中栏列表与左栏统计专用读连接，与 Worker/订阅抓取的通用读连接隔离。
    private var listDB: OpaquePointer?
    private let connectionLock = NSRecursiveLock()

    /// 串行队列：所有写操作 + 事务统一排队执行。
    /// 修 P0-3（跨线程脏写）：@MainActor 服务与非隔离服务并发访问 db/wdb，
    /// FULLMUTEX 只保单条语句，多语句序列（事务、INSERT+lastInsertId）跨线程交错。
    /// 写路径全部走这个串行队列后，多语句序列原子化，不再交错。
    /// 修 P0-2（事务跨连接）：事务内的去重 SELECT 也强制走 wdb（同一连接），
    /// 不再走读连接 db（WAL 快照隔离下读连接看不到事务内写入）。
    private let writeQueue = DispatchQueue(label: "readboard.db.write")
    /// 当前是否在 writeQueue 上（事务内嵌套调用不重复入队，防死锁）
    private let queueKey = DispatchSpecificKey<Bool>()

    /// 数据库实际路径：
    /// - 测试可用 READBOARD_DB 显式覆盖；
    /// - 正式运行统一使用 Application Support，不依赖源码仓库存在。
    static let databasePath: String = {
        if let p = ProcessInfo.processInfo.environment["READBOARD_DB"] { return p }
        return AppResourceLocator.applicationSupportDirectory
            .appendingPathComponent("readboard.db").path
    }()

    static var dataDirectory: String {
        URL(fileURLWithPath: databasePath).deletingLastPathComponent().path
    }

    private let dbPath = Database.databasePath

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
                    "PRAGMA busy_timeout=5000;", "PRAGMA foreign_keys=ON;",
                    "PRAGMA cache_size=-16384;", "PRAGMA mmap_size=268435456;",
                    "PRAGMA temp_store=MEMORY;"] {
            if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            stmt = nil
        }
    }

    @discardableResult
    func open() -> Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: dbPath).deletingLastPathComponent(),
                withIntermediateDirectories: true)
        } catch {
            fputs("[database] 无法创建数据目录：\(error.localizedDescription)\n", stderr)
            return false
        }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        // 读连接
        if db == nil {
            if sqlite3_open_v2(dbPath, &db, flags, nil) != SQLITE_OK {
                sqlite3_close(db); db = nil
            } else {
                configure(db)
                if !runMigrations() {
                    sqlite3_close(db)
                    db = nil
                }
            }
        }
        guard db != nil else { return false }
        // 写连接
        if wdb == nil {
            if sqlite3_open_v2(dbPath, &wdb, flags, nil) != SQLITE_OK {
                sqlite3_close(wdb); wdb = nil
            } else {
                configure(wdb)
            }
        }
        // 阅读器使用独立连接，避免后台列表/统计查询在 FULLMUTEX 上把单篇读取排队数百毫秒。
        if readerDB == nil {
            if sqlite3_open_v2(dbPath, &readerDB, flags, nil) != SQLITE_OK {
                sqlite3_close(readerDB); readerDB = nil
            } else {
                configure(readerDB)
            }
        }
        if listDB == nil {
            if sqlite3_open_v2(dbPath, &listDB, flags, nil) != SQLITE_OK {
                sqlite3_close(listDB); listDB = nil
            } else {
                configure(listDB)
            }
        }
        return db != nil && wdb != nil && readerDB != nil && listDB != nil
    }

    // MARK: 迁移机制（PRAGMA user_version 版本化执行 App Resources/migrations/*.sql）
    // 每次启动检查版本，按文件名顺序补跑未执行的迁移。WAL/FTS/索引/export 表都走这里挂载。

    @discardableResult
    private func runMigrations() -> Bool {
        guard let handle = db else { return false }
        let current = intVal(handle, "PRAGMA user_version;") ?? 0
        guard let migDir = Self.migrationDirectory() else {
            // 已有当前版本数据库即使资源意外缺失仍可打开；全新库则必须拒绝，
            // 防止把一个没有表的空 SQLite 文件当成正常数据库继续运行。
            if current >= 20 { return true }
            fputs("[migration] ⛔ 找不到随 App 打包的 migrations 目录，无法初始化数据库\n", stderr)
            return false
        }
        // 按数字前缀排序而非字典序——字典序下 100_xxx 会排到 99_xxx 前面导致断裂
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: migDir.path)
            .filter({ $0.hasSuffix(".sql") })
            .sorted(by: { f1, f2 in
                let n1 = Int(f1.split(separator: "_").first ?? "") ?? 0
                let n2 = Int(f2.split(separator: "_").first ?? "") ?? 0
                return n1 != n2 ? n1 < n2 : f1 < f2
            }), !files.isEmpty else {
            fputs("[migration] ⛔ migrations 目录为空，无法初始化数据库\n", stderr)
            return false
        }
        var version = current
        for file in files {
            // 文件名形如 009_export.sql → 版本号 9
            let numStr = file.split(separator: "_").first.map(String.init) ?? "0"
            guard let num = Int(numStr), num > version else { continue }
            let fileURL = migDir.appendingPathComponent(file)
            guard let sql = try? String(contentsOf: fileURL, encoding: .utf8) else {
                fputs("[migration] ⛔ 无法读取 \(fileURL.path)\n", stderr)
                return false
            }
            // 每个版本必须原子执行。否则中途失败会留下“表已改、版本未升”的半迁移状态，
            // 下次启动再次执行 RENAME/CREATE 等非幂等语句时无法自愈。
            guard execRaw(handle, "BEGIN IMMEDIATE;") else { return false }
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
            // 版本号和本文件的结构修改在同一事务提交；失败则完整回滚。
            if !allOK {
                _ = execRaw(handle, "ROLLBACK;")
                fputs("[migration] ⚠ \(file) 有语句失败，user_version 不推进，下次启动重试\n", stderr)
                return false
            }
            guard execRaw(handle, "PRAGMA user_version = \(num);") else {
                _ = execRaw(handle, "ROLLBACK;")
                return false
            }
            guard execRaw(handle, "COMMIT;") else {
                _ = execRaw(handle, "ROLLBACK;")
                return false
            }
            version = num
        }
        return version >= 20
    }

    /// 迁移资源定位：部署后的 App Resources 优先；开发/测试环境回落到
    /// SwiftPM Target 内的源码 Resources。
    private static func migrationDirectory() -> URL? {
        AppResourceLocator.existingURL("migrations", isDirectory: true)
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
        connectionLock.lock()
        defer { connectionLock.unlock() }
        sqlite3_close(db); db = nil
        sqlite3_close(wdb); wdb = nil
        sqlite3_close(readerDB); readerDB = nil
        sqlite3_close(listDB); listDB = nil
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

    /// UI 触发的单条写（标已读/星标等）：writeQueue.async 不阻塞主线程。
    /// 复查发现 execute 的 sync 会让主线程等队列里的大任务（清理/批量插入）跑完，
    /// UI 卡顿（P0-3 修复的副作用）。UI 触发、不需立即知道结果的写用这个。
    /// 完成回调在 MainActor（供 UI 刷新状态）。
    func executeAsync(_ sql: String, params: [Any?] = [],
                      completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        if onWriteQueue {
            let ok = executeInner(sql, params: params)
            if let completion {
                DispatchQueue.main.async { completion(ok) }
            }
            return
        }
        let captured = SQLParameters(values: params)
        writeQueue.async {
            let ok = self.executeInner(sql, params: captured.values)
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
        return queryRows(on: handle, sql, params: params)
    }

    private func queryRows(on handle: OpaquePointer?, _ sql: String,
                           params: [Any?] = []) -> [[String: String]] {
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
        // 一次聚合同时返回文件夹源和独立源。旧实现把同一 CTE 执行两次，
        // 每次刷新左栏都会重复扫描整个 content 计数索引。
        guard open() else { return [] }
        // 统计走通用后台读连接；中栏分页独占 listDB，不再被全库聚合挡住。
        let rows = queryRows(on: db, """
            WITH agg AS (
                SELECT source_id,
                       SUM(CASE WHEN is_duplicate = 0 AND deleted_at IS NULL THEN 1 ELSE 0 END) AS n,
                       SUM(CASE WHEN is_duplicate = 0 AND deleted_at IS NULL AND read_at IS NULL THEN 1 ELSE 0 END) AS unread
                FROM content GROUP BY source_id
            )
            SELECT s.folder_id AS fid, f.name AS fname, s.id AS sid, s.name AS sname,
                   COALESCE(agg.n, 0) AS n, COALESCE(agg.unread, 0) AS unread
            FROM content_source s
            LEFT JOIN folder f ON f.id = s.folder_id
            LEFT JOIN agg ON agg.source_id = s.id
            WHERE s.enabled = 1
            ORDER BY CASE WHEN s.folder_id IS NULL THEN 1 ELSE 0 END,
                     f.name, n DESC;
            """)

        var tree: [SidebarNode] = []
        var folderMap: [Int64: (name: String, sources: [SidebarNode])] = [:]
        var folderOrder: [Int64] = []
        var orphanNodes: [SidebarNode] = []
        for r in rows {
            let sname = r["sname"] ?? "未命名源"
            let n = Int(r["n"] ?? "0") ?? 0
            let unread = Int(r["unread"] ?? "0") ?? 0
            let sid = Int64(r["sid"] ?? "0") ?? 0
            let sidStr = r["sid"] ?? ""
            if let fidStr = r["fid"], let fid = Int64(fidStr) {
                let node = SidebarNode(id: "s\(sidStr)", name: sname, count: n, unread: unread,
                                       isFolder: false, filterKey: "source_id=\(sidStr)",
                                       sourceId: sid, folderId: fid, children: nil)
                if folderMap[fid] == nil {
                    folderMap[fid] = (r["fname"] ?? "未命名", [])
                    folderOrder.append(fid)
                }
                folderMap[fid]?.sources.append(node)
            } else {
                orphanNodes.append(SidebarNode(
                    id: "s\(sidStr)", name: sname, count: n, unread: unread,
                    isFolder: false, filterKey: "source_id=\(sidStr)",
                    sourceId: sid, folderId: nil, children: nil))
            }
        }
        for fid in folderOrder {
            guard let (fname, sources) = folderMap[fid] else { continue }
            let total = sources.reduce(0) { $0 + $1.count }
            let totalUnread = sources.reduce(0) { $0 + $1.unread }
            tree.append(SidebarNode(id: "f\(fid)", name: fname, count: total, unread: totalUnread,
                                    isFolder: true, filterKey: "folder_id=\(fid)",
                                    sourceId: nil, folderId: fid, children: sources))
        }
        tree.append(contentsOf: orphanNodes)
        return tree
    }

    /// 拉取内容列表（轻列，不取正文 content_md/llm_translated_md/meta —— 正文点开再按 id 查）
    /// 可按 source/stype、sourceId、folderId 过滤 + 评分/未读/星标/标签/关键词/处理状态筛选
    func fetchContents(source: String? = nil, sourceId: Int64? = nil, folderId: Int64? = nil,
                       minScore: Int? = nil, maxScore: Int? = nil,
                       includeUnscored: Bool = false,
                       unreadOnly: Bool = false, exportedOnly: Bool = false,
                       keyword: String? = nil, starredOnly: Bool = false,
                       tagId: Int64? = nil,
                       processedFilters: [String: Int] = [:],
                       contentCategory: String? = nil,
                       unmetProcessingOnly: Bool = false,
                       restrictToContentIds: Set<Int64>? = nil,
                       sortOrder: String = "newest",
                       limit: Int = 200, offset: Int = 0) -> [ContentItem] {
        guard open() else { return [] }
        let useFTS = (keyword?.isEmpty == false) && ftsAvailable()
        // 轻列：列表渲染够用，不扛正文、HTML、译文或 meta。首图已经在入库时缓存到
        // first_image_url，避免每次列表刷新搬运数 MB HTML 再逐条跑正则。
        var sql: String
        if useFTS {
            sql = """
            SELECT c.id, c.ctype, c.source, c.title, c.author, c.url, c.language, c.published_at,
                   c.excerpt, c.llm_score, c.llm_summary, c.fetch_status, c.read_at, c.starred,
                   c.first_image_url,
                   (c.llm_translated_md IS NOT NULL AND c.llm_translated_md != '') AS has_trans,
                   (c.llm_transcript_md IS NOT NULL AND c.llm_transcript_md != '') AS has_transcript,
                   (c.ctype IN ('podcast','video','youtube') OR c.meta LIKE '%audio_url%') AS is_media,
                   substr(c.llm_translated_md, 1, 120) AS translated_head,
                   c.llm_title_translated AS title_translated,
                   (c.content_md IS NOT NULL AND LENGTH(c.content_md) > 500) AS has_fulltext,
                   (c.llm_excerpt_translated IS NOT NULL AND c.llm_excerpt_translated != '') AS has_excerpt_trans,
                   (EXISTS (SELECT 1 FROM export_record er WHERE er.content_id = c.id AND er.status = 'delivered')) AS has_export,
                   c.source_id, COALESCE(s.name, c.source) AS source_name, s.stype AS source_stype,
                   json_extract(c.meta, '$.bilibili_access_state') AS access_state,
                   (\(Self.unmetProcessingCondition(columnPrefix: "c."))) AS has_unmet_processing
            FROM content c
            JOIN content_fts f ON f.rowid = c.id
            LEFT JOIN content_source s ON s.id = c.source_id
            """
        } else {
            sql = """
            SELECT c.id, c.ctype, c.source, c.title, c.author, c.url, c.language, c.published_at,
                   c.excerpt, c.llm_score, c.llm_summary, c.fetch_status, c.read_at, c.starred,
                   c.first_image_url,
                   (c.llm_translated_md IS NOT NULL AND c.llm_translated_md != '') AS has_trans,
                   (c.llm_transcript_md IS NOT NULL AND c.llm_transcript_md != '') AS has_transcript,
                   (c.ctype IN ('podcast','video','youtube') OR c.meta LIKE '%audio_url%') AS is_media,
                   substr(c.llm_translated_md, 1, 120) AS translated_head,
                   c.llm_title_translated AS title_translated,
                   (c.content_md IS NOT NULL AND LENGTH(c.content_md) > 500) AS has_fulltext,
                   (c.llm_excerpt_translated IS NOT NULL AND c.llm_excerpt_translated != '') AS has_excerpt_trans,
                   (EXISTS (SELECT 1 FROM export_record er WHERE er.content_id = c.id AND er.status = 'delivered')) AS has_export,
                   c.source_id, COALESCE(s.name, c.source) AS source_name, s.stype AS source_stype,
                   json_extract(c.meta, '$.bilibili_access_state') AS access_state,
                   (\(Self.unmetProcessingCondition(columnPrefix: "c."))) AS has_unmet_processing
            FROM content c
            LEFT JOIN content_source s ON s.id = c.source_id
            """
        }
        var conds: [String] = []
        // 排除重复项——is_duplicate=1 的是同内容的副本，不该在列表里重复显示。
        // 与 totalCount/文件夹计数口径对齐（三处都排除重复和软删除），计数才相符。
        conds.append("c.is_duplicate = 0")
        // 排除已删除（软删除 guid 留底防重抓，列表不显示）
        conds.append("c.deleted_at IS NULL")
        let col = "c."
        if source != nil { conds.append("\(col)source = ?") }
        if sourceId != nil { conds.append("\(col)source_id = ?") }
        if folderId != nil {
            conds.append("\(col)source_id IN (SELECT id FROM content_source WHERE folder_id = ?)")
        }
        if minScore != nil || maxScore != nil {
            var scoreRange: [String] = []
            if minScore != nil { scoreRange.append("\(col)llm_score >= ?") }
            if maxScore != nil { scoreRange.append("\(col)llm_score <= ?") }
            let range = scoreRange.joined(separator: " AND ")
            // 含未评分：未评分（NULL）也纳入，避免筛选把未评分文章藏掉。
            conds.append(includeUnscored ? "((\(range)) OR \(col)llm_score IS NULL)" : "(\(range))")
        }
        if unreadOnly { conds.append("\(col)read_at IS NULL") }
        if exportedOnly { conds.append("\(col)id IN (SELECT content_id FROM export_record WHERE status='delivered')") }
        if let category = contentCategory {
            switch category {
            case "podcast": conds.append("\(col)ctype='podcast'")
            case "video": conds.append("\(col)ctype IN ('video','youtube')")
            case "article": conds.append("\(col)ctype NOT IN ('podcast','video','youtube')")
            default: break
            }
        }
        if unmetProcessingOnly {
            conds.append(Self.unmetProcessingCondition(columnPrefix: col))
        }
        if let ids = restrictToContentIds {
            if ids.isEmpty {
                conds.append("0")
            } else {
                conds.append("\(col)id IN (\(ids.sorted().map(String.init).joined(separator: ",")))")
            }
        }
        if starredOnly { conds.append("\(col)starred = 1") }
        if tagId != nil {
            conds.append("\(col)id IN (SELECT content_id FROM content_tag WHERE tag_id = ?)")
        }
        if let processedCondition = processedFilterCondition(processedFilters, columnPrefix: col) {
            conds.append(processedCondition)
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
        if sqlite3_prepare_v2(listDB ?? db, sql, -1, &stmt, nil) == SQLITE_OK {
            var idx: Int32 = 1
            let binder: (String) -> Void = { s in
                sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)); idx += 1
            }
            if let s = source { binder(s) }
            if let sid = sourceId { sqlite3_bind_int64(stmt, idx, sid); idx += 1 }
            if let fid = folderId { sqlite3_bind_int64(stmt, idx, fid); idx += 1 }
            if let m = minScore { sqlite3_bind_int64(stmt, idx, Int64(m)); idx += 1 }
            if let m = maxScore { sqlite3_bind_int64(stmt, idx, Int64(m)); idx += 1 }
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
        // 与 fetchSidebarTree 同属后台统计，不能占住中栏分页专用连接。
        guard open(), let row = queryRows(on: db, """
            SELECT s.config AS src_cfg FROM content c
            JOIN content_source s ON c.source_id = s.id
            WHERE c.id = ?;
            """, params: [contentId]).first else { return PipelinePolicy() }
        return PipelinePolicy.from(configJson: row["src_cfg"] ?? "{}")
    }

    /// 阅读器一次性轻载：独立连接、单条 SQL，不取 content_html。
    /// 这替代旧的“后台查一次并丢弃 + onAppear 主线程再查两次”。
    func fetchReaderPayload(id: Int64) -> ReaderPayload? {
        guard open(), let handle = readerDB else { return nil }
        let sql = """
        SELECT c.content_md, c.llm_translated_md, c.meta, c.llm_title_translated,
               c.llm_transcript_md, c.llm_score, c.llm_summary
        FROM content c
        WHERE c.id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        func text(_ index: Int32) -> String? {
            guard let pointer = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: pointer)
        }
        var audioUrl: String?
        var videoId: String?
        if let meta = text(2), let data = meta.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            audioUrl = (object["audio_url"] as? String) ?? (object["video_url"] as? String)
            videoId = object["video_id"] as? String
        }
        let score = sqlite3_column_type(stmt, 5) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int(stmt, 5))
        return ReaderPayload(
            contentMd: text(0), llmTranslatedMd: text(1), audioUrl: audioUrl,
            titleTranslated: text(3), llmTranscriptMd: text(4), videoId: videoId,
            score: score, summary: text(6))
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
        let handle = readerDB ?? db
        let prepOK = sqlite3_prepare_v2(handle, "SELECT content_md, llm_translated_md, meta, content_html, llm_title_translated, llm_transcript_md FROM content WHERE id = ?", -1, &stmt, nil) == SQLITE_OK
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

    /// LLM 轻量字段（score/summary）——共享阅读页处理完成后刷新镜像用。
    /// （selectedItem 实例刻意不替换，item 里的这两字段会陈旧；单独小查询避免动 fetchContentBody 的元组签名。）
    func fetchLLMExtras(id: Int64) -> (score: Int?, summary: String?)? {
        guard open() else { return nil }
        var stmt: OpaquePointer?
        var result: (Int?, String?)?
        if sqlite3_prepare_v2(readerDB ?? db, "SELECT llm_score, llm_summary FROM content WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
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
    func markRead(contentId: Int64,
                  completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        executeAsync("UPDATE content SET read_at = datetime('now') WHERE id = ?",
                     params: [contentId], completion: completion)
    }

    /// 标记未读。UI 触发，executeAsync 不阻塞主线程。
    func markUnread(contentId: Int64,
                    completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        executeAsync("UPDATE content SET read_at = NULL WHERE id = ?",
                     params: [contentId], completion: completion)
    }

    /// 幂等设置星标状态。应用契约和远程 API 必须表达目标状态，不能使用 toggle；
    /// 否则请求重试可能把状态再次翻转。
    func setStarred(contentId: Int64, starred: Bool,
                    completion: (@MainActor @Sendable (_ ok: Bool, _ changed: Bool) -> Void)? = nil) {
        let update: @Sendable () -> Void = { [self] in
            let ok = executeInner(
                "UPDATE content SET starred = ? WHERE id = ? AND starred <> ?",
                params: [starred ? 1 : 0, contentId, starred ? 1 : 0])
            let changed = ok && writeChanges() > 0
            if let completion {
                DispatchQueue.main.async { completion(ok, changed) }
            }
        }
        if onWriteQueue {
            update()
        } else {
            writeQueue.async(execute: update)
        }
    }

    /// 切换星标，返回新状态。返回值在写前已确定（读当前状态取反），
    /// 写入 executeAsync 不阻塞主线程——读（scalarInt）走读连接不排队，快。
    @discardableResult
    func toggleStar(contentId: Int64,
                    completion: (@MainActor @Sendable (_ ok: Bool, _ starred: Bool) -> Void)? = nil) -> Bool {
        let cur = scalarInt("SELECT starred FROM content WHERE id = ?", params: [contentId]) ?? 0
        let new = cur == 1 ? 0 : 1
        executeAsync("UPDATE content SET starred = ? WHERE id = ?", params: [new, contentId]) { ok in
            completion?(ok, new == 1)
        }
        return new == 1
    }

    /// 批量标已读（严格按当前列表筛选）。返回影响条数。
    /// 筛选参数及其语义必须与 fetchContents 对齐，避免星标/处理状态视图误伤隐藏文章。
    @discardableResult
    func markAllRead(source: String? = nil, sourceId: Int64? = nil, folderId: Int64? = nil,
                     minScore: Int? = nil, maxScore: Int? = nil,
                     includeUnscored: Bool = false,
                     keyword: String? = nil, starredOnly: Bool = false,
                     exportedOnly: Bool = false,
                     tagId: Int64? = nil,
                     processedFilters: [String: Int] = [:],
                     contentCategory: String? = nil,
                     unmetProcessingOnly: Bool = false,
                     restrictToContentIds: Set<Int64>? = nil) -> Int {
        var sql = "UPDATE content SET read_at = datetime('now') WHERE read_at IS NULL AND is_duplicate = 0 AND deleted_at IS NULL"
        var conds: [String] = []
        if source != nil { conds.append("source = ?") }
        if sourceId != nil { conds.append("source_id = ?") }
        if folderId != nil { conds.append("source_id IN (SELECT id FROM content_source WHERE folder_id = ?)") }
        if minScore != nil || maxScore != nil {
            var scoreRange: [String] = []
            if minScore != nil { scoreRange.append("llm_score >= ?") }
            if maxScore != nil { scoreRange.append("llm_score <= ?") }
            let range = scoreRange.joined(separator: " AND ")
            conds.append(includeUnscored ? "((\(range)) OR llm_score IS NULL)" : "(\(range))")
        }
        if starredOnly { conds.append("starred = 1") }
        if exportedOnly {
            conds.append("id IN (SELECT content_id FROM export_record WHERE status='delivered')")
        }
        if let category = contentCategory {
            switch category {
            case "podcast": conds.append("ctype='podcast'")
            case "video": conds.append("ctype IN ('video','youtube')")
            case "article": conds.append("ctype NOT IN ('podcast','video','youtube')")
            default: break
            }
        }
        if unmetProcessingOnly {
            conds.append(Self.unmetProcessingCondition(columnPrefix: ""))
        }
        if let ids = restrictToContentIds {
            if ids.isEmpty { conds.append("0") }
            else { conds.append("id IN (\(ids.sorted().map(String.init).joined(separator: ",")))") }
        }
        if tagId != nil { conds.append("id IN (SELECT content_id FROM content_tag WHERE tag_id = ?)") }
        if let processedCondition = processedFilterCondition(processedFilters, columnPrefix: "") {
            conds.append(processedCondition)
        }
        let useFTS = (keyword?.isEmpty == false) && ftsAvailable()
        if useFTS {
            conds.append("id IN (SELECT rowid FROM content_fts WHERE content_fts MATCH ?)")
        } else if let kw = keyword, !kw.isEmpty {
            conds.append("(title LIKE ? OR excerpt LIKE ?)")
        }
        if !conds.isEmpty { sql += " AND " + conds.joined(separator: " AND ") }
        execute(sql, params: buildMarkParams(source: source, sourceId: sourceId, folderId: folderId,
                                             minScore: minScore, maxScore: maxScore, tagId: tagId,
                                             keyword: keyword, useFTS: useFTS))
        return writeChanges()
    }

    private func buildMarkParams(source: String?, sourceId: Int64?, folderId: Int64?,
                                 minScore: Int?, maxScore: Int?, tagId: Int64?,
                                 keyword: String?, useFTS: Bool) -> [Any?] {
        var params: [Any?] = []
        if let s = source { params.append(s) }
        if let sid = sourceId { params.append(Int(sid)) }
        if let fid = folderId { params.append(Int(fid)) }
        if let m = minScore { params.append(m) }
        if let m = maxScore { params.append(m) }
        if let tid = tagId { params.append(Int(tid)) }
        if useFTS, let kw = keyword {
            params.append(ftsQuery(kw))
        } else if let kw = keyword, !kw.isEmpty {
            let like = "%\(kw)%"; params.append(like); params.append(like)
        }
        return params
    }

    /// fetchContents 与 markAllRead 共用处理状态 SQL，防止两个“当前范围”口径再次漂移。
    private func processedFilterCondition(_ processedFilters: [String: Int],
                                          columnPrefix col: String) -> String? {
        var orConds: [String] = []
        for (key, state) in processedFilters where state != 0 {
            switch key {
            case "fulltext":
                orConds.append(state == 1
                    ? "LENGTH(TRIM(COALESCE(\(col)content_md,''))) > 500"
                    : "LENGTH(TRIM(COALESCE(\(col)content_md,''))) <= 500")
            case "score":
                orConds.append(state == 1 ? "\(col)llm_score IS NOT NULL"
                                          : "\(col)llm_score IS NULL")
            case "summary":
                orConds.append(state == 1
                    ? "(\(col)llm_summary IS NOT NULL AND \(col)llm_summary != '')"
                    : "(\(col)llm_summary IS NULL OR \(col)llm_summary = '')")
            case "translate":
                orConds.append(state == 1
                    ? "(\(col)llm_translated_md IS NOT NULL AND \(col)llm_translated_md != '')"
                    : "(\(col)llm_translated_md IS NULL OR \(col)llm_translated_md = '')")
            case "transcribe":
                let completed = "(\(col)ctype IN ('podcast','video','youtube') OR \(col)meta LIKE '%audio_url%') AND \(col)llm_transcript_md IS NOT NULL AND \(col)llm_transcript_md != ''"
                orConds.append(state == 1 ? "(\(completed))" : "(NOT (\(completed)))")
            default:
                break
            }
        }
        return orConds.isEmpty ? nil : "(" + orConds.joined(separator: " OR ") + ")"
    }

    /// 「全部文章」计数——口径与文件夹计数对齐（非重复、未软删除）。
    func totalCount() -> Int {
        guard open() else { return 0 }
        var stmt: OpaquePointer?
        var n = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM content WHERE is_duplicate = 0 AND deleted_at IS NULL;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int64(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return n
    }

    /// 已导出文章数（export_record 中有 delivered 记录的 content 数）
    func totalExported() -> Int {
        guard open() else { return 0 }
        return scalarInt("SELECT COUNT(DISTINCT er.content_id) FROM export_record er JOIN content c ON c.id=er.content_id WHERE er.status='delivered' AND c.is_duplicate=0 AND c.deleted_at IS NULL;") ?? 0
    }

    /// 「全部文章」未读数——与 totalCount 同口径（活跃有效 + 未读）。
    /// 全部文章行显示「未读/总数」，和文件夹行的计数格式一致。
    func totalUnread() -> Int {
        guard open() else { return 0 }
        var stmt: OpaquePointer?
        var n = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM content WHERE is_duplicate = 0 AND deleted_at IS NULL AND read_at IS NULL;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int64(stmt, 0)) }
        }
        sqlite3_finalize(stmt)
        return n
    }

    /// 左栏全局与内容类型计数一次完成，避免 total/unread/type 分别扫描大表。
    func libraryCounts() -> LibraryCounts {
        let unmet = Self.unmetProcessingCondition(columnPrefix: "")
        guard let row = queryRows("""
            SELECT COUNT(*) AS total,
                   SUM(CASE WHEN read_at IS NULL THEN 1 ELSE 0 END) AS unread,
                   SUM(CASE WHEN \(unmet) THEN 1 ELSE 0 END) AS pending,
                   SUM(CASE WHEN read_at IS NULL AND \(unmet) THEN 1 ELSE 0 END) AS pending_unread,
                   SUM(CASE WHEN ctype NOT IN ('podcast','video','youtube') THEN 1 ELSE 0 END) AS articles,
                   SUM(CASE WHEN ctype NOT IN ('podcast','video','youtube') AND read_at IS NULL THEN 1 ELSE 0 END) AS article_unread,
                   SUM(CASE WHEN ctype='podcast' THEN 1 ELSE 0 END) AS podcasts,
                   SUM(CASE WHEN ctype='podcast' AND read_at IS NULL THEN 1 ELSE 0 END) AS podcast_unread,
                   SUM(CASE WHEN ctype IN ('video','youtube') THEN 1 ELSE 0 END) AS videos,
                   SUM(CASE WHEN ctype IN ('video','youtube') AND read_at IS NULL THEN 1 ELSE 0 END) AS video_unread,
                   (SELECT COUNT(DISTINCT er.content_id)
                    FROM export_record er JOIN content ec ON ec.id=er.content_id
                    WHERE er.status='delivered' AND ec.is_duplicate=0 AND ec.deleted_at IS NULL) AS exported,
                   (SELECT COUNT(DISTINCT er.content_id)
                    FROM export_record er JOIN content ec ON ec.id=er.content_id
                    WHERE er.status='delivered' AND ec.is_duplicate=0
                      AND ec.deleted_at IS NULL AND ec.read_at IS NULL) AS exported_unread
            FROM content
            WHERE is_duplicate=0 AND deleted_at IS NULL;
            """).first else { return LibraryCounts() }
        func value(_ key: String) -> Int { Int(row[key] ?? "0") ?? 0 }
        return LibraryCounts(
            total: value("total"), unread: value("unread"),
            pending: value("pending"), pendingUnread: value("pending_unread"),
            exported: value("exported"),
            exportedUnread: value("exported_unread"),
            articles: value("articles"), articleUnread: value("article_unread"),
            podcasts: value("podcasts"), podcastUnread: value("podcast_unread"),
            videos: value("videos"), videoUnread: value("video_unread"))
    }

    /// 条目设置要求的处理结果仍有任一缺失。这里刻意不判断 Worker 水位线、退避、
    /// 死信、源开关或媒体资源：它描述的是内容是否达到设定标准，而不是当前能否执行。
    private static func unmetProcessingCondition(columnPrefix: String) -> String {
        let c = columnPrefix
        return """
        ((\(c)auto_score=1 AND \(c)llm_score IS NULL
          AND NOT EXISTS (SELECT 1 FROM content_processing_ignore i WHERE i.content_id=\(c)id AND i.jtype='score'))
         OR (\(c)auto_summarize=1 AND LENGTH(TRIM(COALESCE(\(c)llm_summary,'')))=0
          AND NOT EXISTS (SELECT 1 FROM content_processing_ignore i WHERE i.content_id=\(c)id AND i.jtype='summarize'))
         OR (\(c)auto_translate=1 AND LENGTH(TRIM(COALESCE(\(c)llm_translated_md,'')))=0
          AND NOT EXISTS (SELECT 1 FROM content_processing_ignore i WHERE i.content_id=\(c)id AND i.jtype='translate'))
         OR (\(c)auto_transcribe=1 AND LENGTH(TRIM(COALESCE(\(c)llm_transcript_md,'')))=0
          AND NOT EXISTS (SELECT 1 FROM content_processing_ignore i WHERE i.content_id=\(c)id AND i.jtype='transcribe')))
        """
    }

    // MARK: 辅助

    /// 轻列列表行 → ContentItem（正文/audioUrl 留空，点开时 fetchContentBody 补）
    /// 列序：id,ctype,source,title,author,url,language,published_at,excerpt,llm_score,llm_summary,fetch_status,read_at,starred
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
            starred: sqlite3_column_int(stmt, 13) == 1
        )
        // 首图已经在 first_image_url 缓存列中，不再把完整 HTML 带进列表查询。
        if sqlite3_column_count(stmt) > 14 { item.imageUrl = text(14) }
        // 列表标签轻量标记（列 15 has_trans / 16 has_transcript / 17 is_media / 18 translated_head / 19 title_translated / 20 has_fulltext / 21 has_excerpt_trans）
        if sqlite3_column_count(stmt) > 16 {
            item.hasTranslation = sqlite3_column_int(stmt, 15) == 1
            item.hasTranscript = sqlite3_column_int(stmt, 16) == 1
        }
        if sqlite3_column_count(stmt) > 17 {
            item.isMedia = sqlite3_column_int(stmt, 17) == 1
        }
        if sqlite3_column_count(stmt) > 18 {
            item.translatedHead = text(18)
        }
        if sqlite3_column_count(stmt) > 19 {
            item.titleTranslated = text(19)
        }
        if sqlite3_column_count(stmt) > 20 {
            item.hasFulltext = sqlite3_column_int(stmt, 20) == 1
        }
        if sqlite3_column_count(stmt) > 22 {
            item.hasExport = sqlite3_column_int(stmt, 22) == 1
        }
        if sqlite3_column_count(stmt) > 23 {
            item.feedId = int64(23)
        }
        if sqlite3_column_count(stmt) > 24 {
            item.sourceName = text(24)
        }
        if sqlite3_column_count(stmt) > 25 {
            item.sourceStype = text(25)
        }
        if sqlite3_column_count(stmt) > 26 {
            item.accessState = text(26)
        }
        if sqlite3_column_count(stmt) > 27 {
            item.hasUnmetProcessing = sqlite3_column_int(stmt, 27) == 1
        }
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
