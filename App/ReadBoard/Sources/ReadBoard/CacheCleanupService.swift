import Foundation
import SQLite3

// MARK: - 缓存清理统一服务
// 缓存散落各处：转录临时目录、超期备份、retention 天数、抓完丢弃的全文 HTML、DB 膨胀。
// 统一一个服务：各项可配置（UserDefaults 持久化）+ 统计占用 + 一键清理。
// 安全红线：星标/有标签的内容 retention 不动（沿用 RetentionService 的保护）；HTML 清理只清已转 md 的；
// 备份滚动只删超额的旧文件；临时目录只删 readboard- 前缀自己建的。

@MainActor
public final class CacheCleanupService: ObservableObject {
    static let shared = CacheCleanupService()

    // 各项磁盘占用（字节）+ 条目数，供设置页展示
    @Published var tempBytes: Int64 = 0
    @Published var tempCount = 0
    @Published var backupBytes: Int64 = 0
    @Published var backupCount = 0
    @Published var contentHtmlCount = 0          // 可清理的全文 HTML 条数（已转 md 且未读未标）
    @Published var dbBytes: Int64 = 0
    @Published var trashBytesPublished: Int64 = 0   // 回收站占用（供 UI 展示）
    @Published var lastRunSummary = ""
    @Published var isRunning = false

    private let db = Database.shared
    private let backupDir = NSHomeDirectory() + "/readboard/Data/backups"
    private let dbPath = NSHomeDirectory() + "/readboard/Data/readboard.db"

    // MARK: 可配置项（UserDefaults 持久化）

    /// 已读内容超过该天数自动归档（默认 30）
    var archiveAfterDays: Int {
        get { let v = UserDefaults.standard.integer(forKey: "cleanup.archiveAfterDays"); return v > 0 ? v : 30 }
        set { UserDefaults.standard.set(newValue, forKey: "cleanup.archiveAfterDays") }
    }
    /// 天数安全插值进 SQL datetime 修饰符——datetime('-N days') 不能参数绑定只能插值，
    /// 钳制到 0...3650 防 UserDefaults 异常值（负数/超大）导致 SQL 静默失效（修 P1-7）
    private func safeDays(_ d: Int) -> Int { min(max(d, 0), 3650) }
    /// 「已读 N 天后自动归档」是否启用（默认开；关闭则已读老文章不自动归档）
    var archiveEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "cleanup.archiveEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cleanup.archiveEnabled") }
    }
    /// 归档内容超过该天数自动删除（默认 90；0 = 不删除）
    var deleteAfterDays: Int {
        get { UserDefaults.standard.integer(forKey: "cleanup.deleteAfterDays") }  // 0 是合法值（不删），未设过也是 0→给默认
        set { UserDefaults.standard.set(newValue, forKey: "cleanup.deleteAfterDays") }
    }
    /// 「归档 N 天后自动删除」是否启用（默认开；关闭则归档内容永不自动删除）
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
              AND read_at IS NULL AND starred = 0 AND is_archived = 0
              AND id NOT IN (SELECT content_id FROM content_tag)
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

        // 3. retention（归档/删除）——复用 RetentionService 的 SQL 但用本服务的可配天数
        let (archived, deleted) = runRetention()
        if archived > 0 || deleted > 0 { parts.append("归档 \(archived) / 删除 \(deleted)") }

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

    /// retention：归档超期已读 + 删除超期归档（保护星标/有标签/已落盘归档）。用本服务的可配天数。
    /// R4: 物理 DELETE 前先把待删内容备份到 Data/trash/（防误配天数导致大面积丢数据）。
    /// 已落盘归档（meta.archived_at）的记录保留不删——用户拍板：落盘 md 后数据库记录保留，
    /// 只清 html 中间产物（cleanHtml A 路径），记录本身是可检索的统一视图。
    @discardableResult
    func runRetention() -> (archived: Int, deleted: Int) {
        // 「已读 N 天后自动归档」可关闭——关闭则已读老文章留在活跃列表不自动归档
        var archived = 0
        if archiveEnabled {
            db.execute("""
                UPDATE content SET is_archived = 1
                WHERE is_archived = 0 AND starred = 0
                  AND read_at IS NOT NULL
                  AND read_at < datetime('now', '-\(safeDays(archiveAfterDays)) days')
                  AND id NOT IN (SELECT content_id FROM content_tag);
                """)
            archived = db.writeChanges()
        }

        // 「归档 N 天后自动删除」可关闭——关闭则归档内容永不自动删除
        var deleted = 0
        if deleteEnabled && deleteAfterDays > 0 {
            // 软删除：guid 留底防重抓，删 html + 删 Markdown 文件，列表不显示
            let toDelete = db.queryRows("""
                SELECT id FROM content
                WHERE is_archived = 1 AND starred = 0
                  AND meta NOT LIKE '%archived_at%'
                  AND updated_at < datetime('now', '-\(safeDays(deleteAfterDays)) days')
                  AND id NOT IN (SELECT content_id FROM content_tag)
                  AND deleted_at IS NULL;
                """)
            for row in toDelete {
                guard let cid = Int64(row["id"] ?? "") else { continue }
                // 1. 删 Markdown 文件（archiveDir/源名/标题-id.md）
                if let archivePath = ArchiveService.shared.archiveFilePath(contentId: cid),
                   FileManager.default.fileExists(atPath: archivePath) {
                    try? FileManager.default.removeItem(atPath: archivePath)
                }
                // 2. 软删除：deleted_at 标记 + 清空 content_html（产物删，guid 留底）
                db.execute("""
                    UPDATE content SET deleted_at = datetime('now'), content_html = ''
                    WHERE id = ?;
                    """, params: [cid])
                deleted += 1
            }
        }

        // content_job 日志表膨胀控制：每条管线执行都 INSERT，~40k 行/天，
        // 只留最近 30 天（死信统计只看失败次数，历史成功记录无价值）。
        db.execute("DELETE FROM content_job WHERE finished_at < datetime('now', '-30 days');")

        // 孤儿内容归档：source_id 指向已删除源的内容，worker 永远不会处理（policies 查不到），
        // 留在未归档区只会堆积。归档之（不删——内容本身可能还有阅读价值）。
        db.execute("""
            UPDATE content SET is_archived = 1
            WHERE is_archived = 0 AND source_id IS NOT NULL
              AND source_id NOT IN (SELECT id FROM content_source);
            """)

        return (archived, deleted)
    }

    /// R4 删除回收站：把即将物理删除的内容导出成 JSONL 存 Data/trash/YYYYMMDD/，留作后悔药。
    private func backupBeforeDelete(days: Int) {
        // 修 P2-14：备份补存译文/星标/语言/fetch_status——恢复时不丢双语产出
        let rows = db.queryRows("""
            SELECT id, guid, title, url, source, author, published_at, llm_summary, llm_score,
                   content_md, llm_translated_md, starred, language, fetch_status
            FROM content
            WHERE is_archived = 1 AND starred = 0
              AND updated_at < datetime('now', '-\(safeDays(days)) days')
              AND id NOT IN (SELECT content_id FROM content_tag);
            """)
        guard !rows.isEmpty else { return }
        let stamp: String = {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; return f.string(from: Date())
        }()
        let dir = NSHomeDirectory() + "/readboard/Data/trash/\(stamp)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        for r in rows {
            let obj: [String: Any?] = [
                "id": r["id"].flatMap(Int.init), "guid": r["guid"],
                "title": r["title"], "url": r["url"],
                "source": r["source"], "author": r["author"], "published_at": r["published_at"],
                "llm_summary": r["llm_summary"], "llm_score": r["llm_score"].flatMap(Int.init),
                "content_md": r["content_md"],
                "llm_translated_md": r["llm_translated_md"],
                "starred": r["starred"].flatMap(Int.init),
                "language": r["language"],
                "fetch_status": r["fetch_status"].flatMap(Int.init),
            ]
            let compact = obj.compactMapValues { $0 }
            if let data = try? JSONSerialization.data(withJSONObject: compact),
               let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }
        let file = "\(dir)/deleted-\(Int(Date().timeIntervalSince1970)).jsonl"
        try? lines.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// 清全文 HTML（Markdown 才是长期阅读格式，HTML 只是抓取中间产物，67k 条的 HTML 是 DB 膨胀大头）。
    /// 两路清理：
    ///   A. 已落盘归档的（meta.archived_at）：html 立刻可删——Markdown 文件已落盘长期保存，
    ///      数据库记录保留（标题/md/LLM 产出/元数据都在），html 纯冗余。不等天数、不看已读。
    ///   B. 未归档但已转 md 且未读未标未归档、超过 cleanHtmlAfterDays 天的（原保守路径）。
    @discardableResult
    func cleanHtml() -> Int {
        // A. 已落盘归档：立即清 html（数据库记录保留，只删中间产物）
        db.execute("""
            UPDATE content SET content_html = NULL
            WHERE content_html IS NOT NULL AND LENGTH(content_html) > 0
              AND meta LIKE '%archived_at%';
            """)
        let archivedCleaned = db.writeChanges()

        // B. 未归档的保守路径：已转 md 且未读未标未归档、超期才清
        db.execute("""
            UPDATE content SET content_html = NULL
            WHERE content_html IS NOT NULL AND LENGTH(content_html) > 0
              AND content_md IS NOT NULL AND LENGTH(content_md) > 0
              AND read_at IS NULL AND starred = 0 AND is_archived = 0
              AND id NOT IN (SELECT content_id FROM content_tag)
              AND updated_at < datetime('now', '-\(safeDays(cleanHtmlAfterDays)) days');
            """)
        return archivedCleaned + db.writeChanges()
    }

    // MARK: 回收站（trash 恢复 + 统计）

    /// 回收站根目录
    private var trashDir: String { NSHomeDirectory() + "/readboard/Data/trash" }

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

    /// 恢复某批次：逐行解析 JSONL 重新插入 content（幂等——id 已存在则跳过）。
    /// 返回 (恢复条数, 跳过条数)。恢复后内容标记 is_archived=1（原本就是要删的归档），用户可手动取消。
    @discardableResult
    func restoreTrash(batch: TrashBatch) -> (restored: Int, skipped: Int) {
        guard let content = try? String(contentsOfFile: batch.path, encoding: .utf8) else { return (0, 0) }
        var restored = 0, skipped = 0
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? Int else { continue }
            // 已存在（可能清理后又被抓回来）→ 跳过
            if db.scalarInt("SELECT id FROM content WHERE id = ?", params: [id]) != nil {
                skipped += 1
                continue
            }
            // guid 是 NOT NULL：旧备份没有 guid 字段时用合成值兜底（此前缺失 guid 导致 INSERT 静默全失败）
            let guid = (obj["guid"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "restored-\(id)"
            // 修 P2-14：恢复补回译文/星标/语言/fetch_status——双语产出不再丢
            let ok = db.execute("""
                INSERT INTO content (id, guid, ctype, source, title, url, author, published_at,
                                     excerpt, content_md, llm_summary, llm_score,
                                     llm_translated_md, starred, language, fetch_status,
                                     is_archived, updated_at)
                VALUES (?, ?, 'article', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, datetime('now'));
                """, params: [
                    id,
                    guid,
                    obj["source"] as? String ?? "",
                    obj["title"] as? String ?? "",
                    obj["url"] as? String ?? "",
                    obj["author"] as? String,
                    obj["published_at"] as? String,
                    (obj["content_md"] as? String).map { String($0.prefix(200)) },
                    obj["content_md"] as? String,
                    obj["llm_summary"] as? String,
                    obj["llm_score"] as? Int,
                    obj["llm_translated_md"] as? String,
                    obj["starred"] as? Int ?? 0,
                    obj["language"] as? String,
                    obj["fetch_status"] as? Int ?? 0,
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
