import Foundation
import SQLite3

// MARK: - 缓存清理统一服务
// 缓存散落各处：转录临时目录、超期备份、retention 天数、抓完丢弃的全文 HTML、DB 膨胀。
// 统一一个服务：各项可配置（UserDefaults 持久化）+ 统计占用 + 一键清理。
// 安全红线：星标内容 retention 不动；HTML 只在 content_md 已生成后清理；
// 备份滚动只删超额的旧文件；临时目录只删 readboard- 前缀自己建的。

@MainActor
public final class CacheCleanupService: ObservableObject {
    static let shared = CacheCleanupService()

    // 各项磁盘占用（字节）+ 条目数，供设置页展示
    @Published var tempBytes: Int64 = 0
    @Published var tempCount = 0
    @Published var backupBytes: Int64 = 0
    @Published var backupCount = 0
    @Published var contentHtmlCount = 0          // 可清理的全文 HTML 条数（已有 content_md 且未读未标）
    @Published var dbBytes: Int64 = 0
    @Published var trashBytesPublished: Int64 = 0   // 回收站占用（供 UI 展示）
    @Published var lastRunSummary = ""
    @Published var isRunning = false

    private let db = Database.shared
    private let backupDir = Database.dataDirectory + "/backups"
    private let dbPath = Database.databasePath

    // MARK: 可配置项（UserDefaults 持久化）

    /// 天数安全插值进 SQL datetime 修饰符——datetime('-N days') 不能参数绑定只能插值，
    /// 钳制到 0...3650 防 UserDefaults 异常值（负数/超大）导致 SQL 静默失效（修 P1-7）
    private func safeDays(_ d: Int) -> Int { min(max(d, 0), 3650) }
    /// 已读内容超过该天数自动软删除（默认 90；0 = 不删除）
    var deleteAfterDays: Int {
        get { UserDefaults.standard.integer(forKey: "cleanup.deleteAfterDays") }  // 0 是合法值（不删），未设过也是 0→给默认
        set { UserDefaults.standard.set(newValue, forKey: "cleanup.deleteAfterDays") }
    }
    /// 「已读 N 天后自动删除」是否启用
    var deleteEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "cleanup.deleteEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cleanup.deleteEnabled") }
    }
    /// deleteAfterDays 是否初始化过（区分"未设过"和"用户显式设为 0"）
    private var deleteDaysInitialized: Bool {
        get { UserDefaults.standard.bool(forKey: "cleanup.deleteDaysInit") }
        set { UserDefaults.standard.set(newValue, forKey: "cleanup.deleteDaysInit") }
    }
    /// 备份保留份数（默认 5）
    var backupKeepCount: Int {
        get { let v = UserDefaults.standard.integer(forKey: "cleanup.backupKeep"); return v > 0 ? v : 5 }
        set { UserDefaults.standard.set(newValue, forKey: "cleanup.backupKeep") }
    }
    /// 「备份滚动保留」是否启用（默认开；关闭则备份不自动滚动清理）
    var backupKeepEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "cleanup.backupKeepEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cleanup.backupKeepEnabled") }
    }
    /// 是否清理全文 HTML（默认开）
    var cleanContentHtml: Bool {
        get { UserDefaults.standard.object(forKey: "cleanup.cleanHtml") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cleanup.cleanHtml") }
    }
    /// 全文 HTML 超过该天数才清（默认 7 天，给最近阅读留原文渲染）
    var cleanHtmlAfterDays: Int {
        get { let v = UserDefaults.standard.integer(forKey: "cleanup.cleanHtmlDays"); return v > 0 ? v : 7 }
        set { UserDefaults.standard.set(newValue, forKey: "cleanup.cleanHtmlDays") }
    }

    private init() {
        // 首次启动初始化 deleteAfterDays 默认 90（之后用户改 0 也是合法持久值）
        if !deleteDaysInitialized {
            deleteAfterDays = 90
            deleteDaysInitialized = true
        }
    }

    // MARK: 统计各项占用

    func refreshStats() {
        // 临时目录（readboard- 前缀）
        var tBytes: Int64 = 0, tCount = 0
        let tmp = NSTemporaryDirectory()
        if let items = try? FileManager.default.contentsOfDirectory(atPath: tmp) {
            for item in items where item.hasPrefix("readboard-") {
                let path = tmp + item
                tCount += 1
                tBytes += Self.dirSize(path)
            }
        }
        tempBytes = tBytes; tempCount = tCount

        // 备份目录
        var bBytes: Int64 = 0, bCount = 0
        if let items = try? FileManager.default.contentsOfDirectory(atPath: backupDir) {
            for item in items where item.hasPrefix("readboard-") && item.hasSuffix(".db") {
                bCount += 1
                if let attr = try? FileManager.default.attributesOfItem(atPath: "\(backupDir)/\(item)"),
                   let sz = attr[.size] as? Int64 { bBytes += sz }
            }
        }
        backupBytes = bBytes; backupCount = bCount

        // 可清理的全文 HTML 条数
        contentHtmlCount = db.scalarInt("""
            SELECT COUNT(*) FROM content
            WHERE content_html IS NOT NULL AND LENGTH(content_html) > 0
              AND content_md IS NOT NULL AND LENGTH(content_md) > 0
              AND read_at IS NULL AND starred = 0 AND deleted_at IS NULL
              AND updated_at < datetime('now', '-\(safeDays(cleanHtmlAfterDays)) days');
            """) ?? 0

        // DB 文件大小（含 wal）
        var dBytes: Int64 = (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? Int64) ?? 0
        if let wal = try? FileManager.default.attributesOfItem(atPath: dbPath + "-wal")[.size] as? Int64 { dBytes += wal }
        dbBytes = dBytes

        // 回收站占用
        trashBytesPublished = trashBytes
    }

    // MARK: 一键全部清理

    /// 按当前配置跑全套清理。返回各项结果汇总文本。
    @discardableResult
    func runAll() async -> String {
        isRunning = true
        defer { isRunning = false; refreshStats() }
        var parts: [String] = []

        // 1. 临时目录
        let t = cleanTemp()
        if t.count > 0 { parts.append("临时文件 \(t.count) 项（\(Self.humanBytes(t.bytes))）") }

        // 2. 备份滚动
        let b = pruneBackups()
        if b > 0 { parts.append("旧备份 \(b) 份") }

        // 3. 已读超期软删除
        let deleted = runRetention()
        if deleted > 0 { parts.append("内容 \(deleted) 条") }

        // 4. 全文 HTML 清理
        if cleanContentHtml {
            let h = cleanHtml()
            if h > 0 { parts.append("全文 HTML \(h) 条") }
        }

        // 5. 增量 vacuum（不锁库，只回收空闲页；完整 VACUUM 会重写整个 800MB 库太重，不做）
        db.execute("PRAGMA incremental_vacuum;")

        lastRunSummary = parts.isEmpty ? "没有可清理的内容" : "已清理：" + parts.joined(separator:"，")
        return lastRunSummary
    }

    // MARK: 分项清理

    /// 清临时目录里 readboard- 前缀的目录（转录/下载残留）
    @discardableResult
    func cleanTemp() -> (count: Int, bytes: Int64) {
        let tmp = NSTemporaryDirectory()
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: tmp) else { return (0, 0) }
        var count = 0, bytes: Int64 = 0
        for item in items where item.hasPrefix("readboard-") {
            let path = tmp + item
            bytes += Self.dirSize(path)
            if (try? FileManager.default.removeItem(atPath: path)) != nil { count += 1 }
        }
        return (count, bytes)
    }

    /// 备份滚动：只保留最新 backupKeepCount 份（可通过 backupKeepEnabled 关闭）
    @discardableResult
    func pruneBackups() -> Int {
        guard backupKeepEnabled else { return 0 }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: backupDir) else { return 0 }
        let backups = items.filter { $0.hasPrefix("readboard-") && $0.hasSuffix(".db") }.sorted()
        let excess = backups.count - backupKeepCount
        guard excess > 0 else { return 0 }
        var removed = 0
        for f in backups.prefix(excess) {
            if (try? FileManager.default.removeItem(atPath: "\(backupDir)/\(f)")) != nil { removed += 1 }
        }
        return removed
    }

    /// 已读内容超期后静默软删除，并释放正文和 AI 结果等大字段。
    /// guid、source、url、title 等最小元数据留在数据库中，继续承担防重复抓取作用。
    /// 星标内容永久保护；当前版本不为自动清理生成回收站文件。
    @discardableResult
    func runRetention() -> Int {
        guard deleteEnabled && deleteAfterDays > 0 else { return 0 }
        var deleted = 0
        let candidates = db.queryRows("""
            SELECT id FROM content
            WHERE read_at IS NOT NULL AND starred = 0
              AND read_at < datetime('now', '-\(safeDays(deleteAfterDays)) days')
              AND deleted_at IS NULL;
            """)
        for row in candidates {
            guard let cid = Int64(row["id"] ?? "") else { continue }
            db.execute("""
                UPDATE content SET
                    deleted_at = datetime('now'),
                    content_html = NULL,
                    content_md = NULL,
                    excerpt = NULL,
                    llm_summary = NULL,
                    llm_translated_md = NULL,
                    llm_excerpt_translated = NULL,
                    llm_title_translated = NULL,
                    llm_transcript_md = NULL,
                    llm_model = NULL,
                    fetch_error = NULL,
                    updated_at = datetime('now')
                WHERE id = ?;
                """, params: [cid])
            deleted += 1
        }
        return deleted
    }
    /// 清全文 HTML。只有已经生成 content_md、未读未标且超过保留天数的内容会被清理；
    /// content_md 仍保留在数据库，阅读器不依赖原始 HTML。
    @discardableResult
    func cleanHtml() -> Int {
        db.execute("""
            UPDATE content SET content_html = NULL
            WHERE content_html IS NOT NULL AND LENGTH(content_html) > 0
              AND content_md IS NOT NULL AND LENGTH(content_md) > 0
              AND read_at IS NULL AND starred = 0 AND deleted_at IS NULL
              AND updated_at < datetime('now', '-\(safeDays(cleanHtmlAfterDays)) days');
            """)
        return db.writeChanges()
    }

    // MARK: 回收站（trash 恢复 + 统计）

    /// 回收站根目录
    private var trashDir: String { Database.dataDirectory + "/trash" }

    /// 回收站批次（按日期目录 + 文件）
    struct TrashBatch: Identifiable, Hashable {
        let id = UUID()
        let path: String
        let date: String
        let itemCount: Int
        let sizeBytes: Int64
    }

    /// 列出回收站批次（新→旧）
    func listTrash() -> [TrashBatch] {
        let fm = FileManager.default
        guard let days = try? fm.contentsOfDirectory(atPath: trashDir)
            .filter({ !$0.hasPrefix(".") }).sorted().reversed() else { return [] }
        var out: [TrashBatch] = []
        for day in days {
            let dayDir = trashDir + "/" + day
            guard let files = try? fm.contentsOfDirectory(atPath: dayDir)
                .filter({ $0.hasSuffix(".jsonl") }) else { continue }
            for f in files {
                let p = dayDir + "/" + f
                let content = (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
                let count = content.split(separator: "\n").filter { !$0.isEmpty }.count
                let size = (try? fm.attributesOfItem(atPath: p)[.size] as? Int64) ?? 0
                out.append(TrashBatch(path: p, date: day, itemCount: count, sizeBytes: size))
            }
        }
        return out
    }

    /// 回收站总占用（清理统计纳入）
    var trashBytes: Int64 { Self.dirSize(trashDir) }

    /// 恢复某批次：清理留下的软删除行会原位回填；旧式物理删除备份则重新插入。
    /// 正常可见的同 id 内容仍按幂等规则跳过。
    /// 返回 (恢复条数, 跳过条数)。恢复后的内容直接回到普通文章列表。
    @discardableResult
    func restoreTrash(batch: TrashBatch) -> (restored: Int, skipped: Int) {
        guard let content = try? String(contentsOfFile: batch.path, encoding: .utf8) else { return (0, 0) }
        var restored = 0, skipped = 0
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = Self.intValue(obj["id"]) else { continue }

            if db.scalarInt("SELECT COUNT(*) FROM content WHERE id = ?", params: [id]) == 1 {
                guard db.scalarString("SELECT deleted_at FROM content WHERE id = ?", params: [id]) != nil else {
                    skipped += 1
                    continue
                }
                let ok = db.execute("""
                    UPDATE content SET
                        content_html = ?, content_md = ?, excerpt = ?,
                        word_count = ?, reading_minutes = ?, fetch_status = ?,
                        fetch_engine = ?, fetch_error = ?, fetched_full_at = ?,
                        llm_score = ?, llm_summary = ?, llm_translated_md = ?,
                        llm_excerpt_translated = ?, llm_title_translated = ?,
                        llm_transcript_md = ?, llm_model = ?, llm_processed_at = ?,
                        read_at = ?, deleted_at = NULL, updated_at = datetime('now')
                    WHERE id = ? AND deleted_at IS NOT NULL;
                    """, params: [
                        Self.stringValue(obj["content_html"]), Self.stringValue(obj["content_md"]),
                        Self.stringValue(obj["excerpt"]), Self.intValue(obj["word_count"]),
                        Self.intValue(obj["reading_minutes"]), Self.intValue(obj["fetch_status"]) ?? 0,
                        Self.stringValue(obj["fetch_engine"]), Self.stringValue(obj["fetch_error"]),
                        Self.stringValue(obj["fetched_full_at"]), Self.intValue(obj["llm_score"]),
                        Self.stringValue(obj["llm_summary"]), Self.stringValue(obj["llm_translated_md"]),
                        Self.stringValue(obj["llm_excerpt_translated"]),
                        Self.stringValue(obj["llm_title_translated"]),
                        Self.stringValue(obj["llm_transcript_md"]), Self.stringValue(obj["llm_model"]),
                        Self.stringValue(obj["llm_processed_at"]), Self.stringValue(obj["read_at"]), id,
                    ])
                if ok && db.writeChanges() == 1 { restored += 1 } else { skipped += 1 }
                continue
            }
            // guid 是 NOT NULL：旧备份没有 guid 字段时用合成值兜底（此前缺失 guid 导致 INSERT 静默全失败）
            let guid = Self.stringValue(obj["guid"]).flatMap { $0.isEmpty ? nil : $0 } ?? "restored-\(id)"
            // 修 P2-14：恢复补回译文/星标/语言/fetch_status——双语产出不再丢
            let ok = db.execute("""
                INSERT INTO content (id, guid, ctype, source, title, url, author, published_at,
                                     excerpt, content_md, llm_summary, llm_score,
                                     llm_translated_md, llm_transcript_md, starred, language, fetch_status,
                                     updated_at)
                VALUES (?, ?, 'article', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'));
                """, params: [
                    id,
                    guid,
                    Self.stringValue(obj["source"]) ?? "",
                    Self.stringValue(obj["title"]) ?? "",
                    Self.stringValue(obj["url"]) ?? "",
                    Self.stringValue(obj["author"]),
                    Self.stringValue(obj["published_at"]),
                    Self.stringValue(obj["content_md"]).map { String($0.prefix(200)) },
                    Self.stringValue(obj["content_md"]),
                    Self.stringValue(obj["llm_summary"]),
                    Self.intValue(obj["llm_score"]),
                    Self.stringValue(obj["llm_translated_md"]),
                    Self.stringValue(obj["llm_transcript_md"]),
                    Self.intValue(obj["starred"]) ?? 0,
                    Self.stringValue(obj["language"]),
                    Self.intValue(obj["fetch_status"]) ?? 0,
                ])
            if ok { restored += 1 } else { skipped += 1 }
        }
        return (restored, skipped)
    }

    /// 清空回收站某批次文件
    func deleteTrash(batch: TrashBatch) {
        try? FileManager.default.removeItem(atPath: batch.path)
    }

    /// 清空整个回收站
    func clearAllTrash() {
        try? FileManager.default.removeItem(atPath: trashDir)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    // MARK: 工具

    static func dirSize(_ path: String) -> Int64 {
        guard let en = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let f = en.nextObject() as? String {
            if let attr = try? FileManager.default.attributesOfItem(atPath: path + "/" + f),
               let sz = attr[.size] as? Int64 { total += sz }
        }
        return total
    }

    static func humanBytes(_ b: Int64) -> String {
        if b >= 1 << 30 { return String(format: "%.1f GB", Double(b) / Double(1 << 30)) }
        if b >= 1 << 20 { return String(format: "%.1f MB", Double(b) / Double(1 << 20)) }
        if b >= 1 << 10 { return String(format: "%.0f KB", Double(b) / Double(1 << 10)) }
        return "\(b) B"
    }
}
