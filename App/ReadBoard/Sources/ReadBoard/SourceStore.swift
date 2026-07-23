import Foundation
import SQLite3
import CryptoKit

// MARK: - 订阅源模型

/// 管线开关（存于 content_source.config JSON，默认全关）
struct PipelinePolicy: Hashable {
    var autoScore = false
    var autoTranslate = false
    var autoTranscribe = false
    var autoSummarize = false

    static func from(configJson: String) -> PipelinePolicy {
        guard let data = configJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PipelinePolicy()
        }
        func flag(_ k: String) -> Bool { (obj[k] as? Bool) ?? ((obj[k] as? Int) == 1) }
        return PipelinePolicy(
            autoScore: flag("auto_score"),
            autoTranslate: flag("auto_translate"),
            autoTranscribe: flag("auto_transcribe"),
            autoSummarize: flag("auto_summarize")
        )
    }
}

struct FeedSource: Identifiable, Hashable {
    let id: Int64
    let stype: String          // rss / podcast / youtube / wechat
    let name: String
    let identifier: String     // feed url / channel id
    let enabled: Bool
    let lastFetchedAt: String?
    let error: String?
    let config: String         // JSON 原文
    let folderId: Int64?       // 所属文件夹，nil = 未分组

    var policy: PipelinePolicy { PipelinePolicy.from(configJson: config) }

    /// 全文获取模式（config.fetch_mode, 默认 summary）
    var fetchMode: FetchMode {
        guard let data = config.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["fetch_mode"] as? String,
              let m = FetchMode(rawValue: raw) else { return .summary }
        return m
    }

    /// 抓取间隔（分钟，config.fetch_interval_min，默认 15）
    var fetchIntervalMin: Int {
        guard let data = config.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 15 }
        if let v = obj["fetch_interval_min"] as? Int { return v }
        if let v = obj["fetch_interval_min"] as? Double { return Int(v) }
        return 15
    }

    /// 是否到期该抓（距 last_fetched_at 超过间隔；从未抓过 = 到期）
    var isDue: Bool {
        guard let t = lastFetchedAt, !t.isEmpty else { return true }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        guard let last = f.date(from: t) else { return true }
        return Date().timeIntervalSince(last) >= TimeInterval(fetchIntervalMin * 60)
    }

    /// 该源是否可转录（播客/视频才有音频流）
    var transcribable: Bool { stype == "podcast" || stype == "youtube" }
}

// MARK: - 文件夹

struct Folder: Identifiable, Hashable {
    let id: Int64
    let name: String
    let config: String

    var policy: PipelinePolicy { PipelinePolicy.from(configJson: config) }
}

// MARK: - 订阅源管理（写入 + 抓取调度）

@MainActor
final class SourceStore: ObservableObject {
    /// 常驻单例：自动抓取调度挂在它上面（App 生命周期内不被释放）
    static let shared = SourceStore()

    @Published var sources: [FeedSource] = []
    @Published var folders: [Folder] = []
    @Published var isSyncing = false
    @Published var lastSyncMessage = ""

    private let db = Database.shared

    // MARK: 自动抓取调度

    private var syncTimer: Timer?
    /// 自动抓取间隔（秒），默认 15 分钟
    var syncInterval: TimeInterval = 15 * 60
    /// 是否开启自动抓取（默认开）
    var autoSyncEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "sourceStore.autoSync") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "sourceStore.autoSync")
            if newValue { startAutoSync() } else { stopAutoSync() }
        }
    }

    /// 启动周期自动抓取（立即跑一轮 + Timer 周期）。App 启动时调用。
    /// 自动调度走 manual=false：只抓到期的源（按各自抓取间隔）。
    func startAutoSync() {
        guard autoSyncEnabled, syncTimer == nil else { return }
        Task { await syncAll(manual: false) }
        syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncAll(manual: false) }
        }
    }

    func stopAutoSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    func reload() {
        sources = fetchAllSources()
        folders = fetchAllFolders()
    }

    // MARK: 文件夹 CRUD

    @discardableResult
    func addFolder(name: String) -> Bool {
        let ok = db.execute("INSERT OR IGNORE INTO folder (name) VALUES (?)", params: [name])
        if ok { reload() }
        return ok
    }

    func removeFolder(id: Int64) {
        // 该文件夹下的源 folder_id 置 NULL(ON DELETE SET NULL 兜底, 这里显式置空)
        db.execute("UPDATE content_source SET folder_id = NULL WHERE folder_id = ?", params: [id])
        db.execute("DELETE FROM folder WHERE id = ?", params: [id])
        reload()
    }

    func renameFolder(id: Int64, name: String) {
        db.execute("UPDATE folder SET name = ? WHERE id = ?", params: [name, id])
        reload()
    }

    /// 把源指派到文件夹(nil = 移出到未分组)
    func assignSource(sourceId: Int64, folderId: Int64?) {
        db.execute("UPDATE content_source SET folder_id = ? WHERE id = ?",
                   params: [folderId.map { Int($0) }, sourceId])
        reload()
    }

    /// 文件夹级管线开关
    func setFolderPolicy(id: Int64, key: String, value: Bool) {
        let current = db.scalarString("SELECT config FROM folder WHERE id = ?", params: [id]) ?? "{}"
        var obj = (try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any]) ?? [:]
        obj[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let str = String(data: data, encoding: .utf8) {
            db.execute("UPDATE folder SET config = ? WHERE id = ?", params: [str, id])
        }
        reload()
    }

    /// 查某源的文件夹开关(供生效判定)
    func folderPolicy(for source: FeedSource) -> PipelinePolicy {
        guard let fid = source.folderId,
              let f = folders.first(where: { $0.id == fid }) else { return PipelinePolicy() }
        return f.policy
    }

    // MARK: 增删改

    /// 添加订阅源（RSS/播客直接用 url；YouTube 传频道 url 或 UC id）
    /// 添加时自动探测全文模式（仅 RSS 文章类需要; 播客/YouTube 不抓正文, 跳过探测）
    @discardableResult
    func addSource(stype: String, name: String, identifier: String) async -> Bool {
        var config = "{}"
        if stype == "rss" {
            let mode = await FullTextFetcher.shared.probeMode(feedUrl: identifier)
            config = "{\"fetch_mode\":\"\(mode.rawValue)\"}"
        }
        let ok = db.execute(
            "INSERT OR IGNORE INTO content_source (stype, name, identifier, enabled, config) VALUES (?,?,?,1,?)",
            params: [stype, name, identifier, config]
        )
        if ok { reload() }
        return ok
    }

    /// 手动设置某源的全文模式（GUI 覆盖）
    func setFetchMode(id: Int64, mode: FetchMode) {
        let current = db.scalarString("SELECT config FROM content_source WHERE id = ?", params: [id]) ?? "{}"
        var obj = (try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any]) ?? [:]
        obj["fetch_mode"] = mode.rawValue
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let str = String(data: data, encoding: .utf8) {
            db.execute("UPDATE content_source SET config = ? WHERE id = ?", params: [str, id])
        }
        reload()
    }

    /// 重新探测某源的全文模式并写回
    func reprobeFetchMode(id: Int64) async {
        guard let identifier = db.scalarString("SELECT identifier FROM content_source WHERE id = ?", params: [id]) else { return }
        let mode = await FullTextFetcher.shared.probeMode(feedUrl: identifier)
        setFetchMode(id: id, mode: mode)
    }

    /// 设置某源抓取间隔（分钟）
    func setFetchInterval(id: Int64, minutes: Int) {
        let current = db.scalarString("SELECT config FROM content_source WHERE id = ?", params: [id]) ?? "{}"
        var obj = (try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any]) ?? [:]
        obj["fetch_interval_min"] = minutes
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let str = String(data: data, encoding: .utf8) {
            db.execute("UPDATE content_source SET config = ? WHERE id = ?", params: [str, id])
        }
        reload()
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

    // MARK: 管线开关

    /// 切换某条管线开关，合并写回 config JSON
    func setPolicy(id: Int64, key: String, value: Bool) {
        let current = db.scalarString("SELECT config FROM content_source WHERE id = ?", params: [id]) ?? "{}"
        var obj = (try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any]) ?? [:]
        obj[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let str = String(data: data, encoding: .utf8) {
            db.execute("UPDATE content_source SET config = ? WHERE id = ?", params: [str, id])
        }
        reload()
    }

    // MARK: 抓取

    /// 抓取所有启用的源。manual=true 忽略频率限制全抓；自动调度(false)只抓到期的源。
    func syncAll(manual: Bool = true) async {
        isSyncing = true
        lastSyncMessage = ""
        var total = 0
        var failed = 0
        var skipped = 0
        for src in sources where src.enabled {
            // 自动调度时按源的抓取间隔筛选：距上次抓取不足间隔的跳过
            if !manual && !src.isDue { skipped += 1; continue }
            do {
                let n = try await syncOne(src)
                total += n
            } catch {
                failed += 1
                db.execute("UPDATE content_source SET error = ? WHERE id = ?",
                           params: [error.localizedDescription, src.id])
            }
        }
        var msg = failed > 0 ? "完成：新增 \(total) 条，\(failed) 个源失败" : "完成：新增 \(total) 条"
        if skipped > 0 { msg += "（跳过未到期 \(skipped)）" }
        lastSyncMessage = msg
        isSyncing = false
        reload()
    }

    /// 抓取单个源，返回新增条数
    @discardableResult
    func syncOne(_ src: FeedSource) async throws -> Int {
        let feed = try await FeedFetcher.fetch(urlString: src.identifier)
        var added = 0
        for entry in feed.entries {
            if let newId = upsertContent(source: src.stype, sourceId: src.id, entry: entry) {
                added += 1
                // 新文章: 按源的 fetch_mode 立即抓全文（仅文章类）
                if entry.meta["audio_url"] == nil && entry.meta["video_id"] == nil {
                    await FullTextFetcher.shared.fetchAndStore(
                        contentId: newId, url: entry.url,
                        feedHtml: entry.html.isEmpty ? nil : entry.html,
                        mode: src.fetchMode
                    )
                }
            }
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
        let sql = "SELECT id, stype, name, identifier, enabled, last_fetched_at, error, config, folder_id FROM content_source ORDER BY stype, name;"
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
                    error: columnText(stmt, 6),
                    config: columnText(stmt, 7) ?? "{}",
                    folderId: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 8)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return list
    }

    private func fetchAllFolders() -> [Folder] {
        guard db.open() else { return [] }
        var stmt: OpaquePointer?
        var list: [Folder] = []
        if prepareRead("SELECT id, name, config FROM folder ORDER BY name;", &stmt) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                list.append(Folder(
                    id: sqlite3_column_int64(stmt, 0),
                    name: columnText(stmt, 1) ?? "",
                    config: columnText(stmt, 2) ?? "{}"
                ))
            }
        }
        sqlite3_finalize(stmt)
        return list
    }

    /// 把一条 feed entry 写进 content（按 source+guid 去重 + 跨源内容去重），返回新插入的 content id（已存在返回 nil）
    private func upsertContent(source: String, sourceId: Int64, entry: ParsedEntry) -> Int64? {
        // 同源同 guid 已存在则跳过
        if let _ = db.scalarInt("SELECT id FROM content WHERE source = ? AND guid = ?",
                                params: [source, entry.guid]) {
            return nil
        }
        let ctype: String
        if entry.meta["video_id"] != nil { ctype = "video" }
        else if entry.meta["audio_url"] != nil { ctype = "podcast" }
        else { ctype = "article" }

        // ── 跨源内容去重：url 规范化(去追踪参数) + 标题归一化 → content_hash ──
        // 同一文章多源转载(公众号+官网+RSS聚合)会命中相同 hash。重复的不跳过,
        // 标 is_duplicate + duplicate_of 保留溯源, 阅读层可选择隐藏重复。
        let normUrl = Self.normalizeUrl(entry.url)
        let normTitle = Self.normalizeTitle(entry.title)
        let hash = Self.contentHash(url: normUrl, title: normTitle)
        var isDup = 0
        var dupOf: Int64? = nil
        if let existingId = db.scalarInt("SELECT id FROM content WHERE content_hash = ? AND is_duplicate = 0 LIMIT 1",
                                         params: [hash]) {
            isDup = 1
            dupOf = Int64(existingId)
        }

        let published = entry.published.map { ISO8601DateFormatter().string(from: $0) }
        let metaJson = (try? JSONSerialization.data(withJSONObject: entry.meta))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let ok = db.execute(
            """
            INSERT INTO content (ctype, guid, source, source_id, title, author, url, published_at, content_html, fetch_status, meta, content_hash, is_duplicate, duplicate_of)
            VALUES (?,?,?,?,?,?,?,?,?,0,?,?,?,?)
            """,
            params: [ctype, entry.guid, source, sourceId, entry.title, entry.author, entry.url, published, entry.html, metaJson, hash, isDup, dupOf.map { Int($0) }]
        )
        let newId = ok ? db.lastInsertId() : nil
        // 新内容应用过滤规则（归档/标已读/加星/打标签）
        if let cid = newId {
            FilterService.shared.applyRules(contentId: cid, sourceId: sourceId,
                title: entry.title, content: entry.html, author: entry.author ?? "", url: entry.url)
        }
        return newId
    }

    // MARK: 内容去重辅助

    /// url 规范化：去 utm_*/fbclid/gclid 等追踪参数 + 去 fragment + 去尾斜杠 + 小写 scheme/host
    static func normalizeUrl(_ urlString: String) -> String {
        guard var comps = URLComponents(string: urlString) else { return urlString.lowercased() }
        comps.scheme = comps.scheme?.lowercased()
        comps.host = comps.host?.lowercased()
        comps.fragment = nil
        let trackPrefixes = ["utm_", "fbclid", "gclid", "ref", "spm", "from", "source", "mc_cid", "mc_eid"]
        if let items = comps.queryItems {
            comps.queryItems = items.filter { item in
                !trackPrefixes.contains(where: { item.name.lowercased().hasPrefix($0) })
            }
            if comps.queryItems?.isEmpty == true { comps.queryItems = nil }
        }
        var s = comps.string ?? urlString
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 标题归一化：去空白/标点/小写，用于跨源同题判重
    static func normalizeTitle(_ title: String) -> String {
        title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    /// 内容 hash：规范化 url + 归一化标题 的 SHA256（url 优先, 空 url 退化为纯标题）
    static func contentHash(url: String, title: String) -> String {
        let basis = url.isEmpty ? "t:\(title)" : "u:\(url)|t:\(title)"
        let digest = SHA256.hash(data: Data(basis.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
