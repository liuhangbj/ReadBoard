import Foundation
import SQLite3
import CryptoKit

// MARK: - 订阅源模型

/// 管线开关（存于 content_source.config JSON，默认全关）
public struct PipelinePolicy: Hashable, Sendable {
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

public struct FeedSource: Identifiable, Hashable {
    public let id: Int64
    let stype: String          // rss / podcast / youtube / wechat
    let name: String
    let identifier: String     // feed url / channel id
    let enabled: Bool
    let lastFetchedAt: String?
    let error: String?
    let config: String         // JSON 原文
    let folderId: Int64?       // 所属文件夹，nil = 未分组

    var policy: PipelinePolicy { PipelinePolicy.from(configJson: config) }

    /// 全文提取模式（config.fetch_mode, 默认 summary）
    var fetchMode: FetchMode {
        guard let data = config.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["fetch_mode"] as? String,
              let m = FetchMode(rawValue: raw) else { return .summary }
        return m
    }

    /// 是否「关闭全文提取/显示摘要」——fetch_mode == summary。
    /// 统一语义：summary = 不抓全文只留 feed 摘要（文章抓不到兜底 / 播客显示摘要，本质相同）。
    var isFetchOff: Bool { fetchMode == .summary }

    /// 是否自动检测的（config.fetch_mode_auto）
    var fetchModeAuto: Bool {
        guard let data = config.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["fetch_mode_auto"] as? Bool ?? false
    }

    /// 抓取间隔（分钟，config.fetch_interval_min，默认 60）
    var fetchIntervalMin: Int {
        guard let data = config.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 60 }
        if let v = obj["fetch_interval_min"] as? Int { return v }
        if let v = obj["fetch_interval_min"] as? Double { return Int(v) }
        return 60
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

    /// 最多保留条数（config.max_keep，0 = 不限制，默认 0）
    /// 超出后最旧的自动软删除。播客源几百上千条时用于限制列表保留量。
    var maxKeep: Int {
        guard let data = config.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        if let v = obj["max_keep"] as? Int { return v }
        if let v = obj["max_keep"] as? Double { return Int(v) }
        return 0
    }
}

// MARK: - 文件夹

public struct Folder: Identifiable, Hashable {
    public let id: Int64
    let name: String
    let config: String

    var policy: PipelinePolicy { PipelinePolicy.from(configJson: config) }
}

// MARK: - 订阅源管理（写入 + 抓取调度）

@MainActor
public final class SourceStore: ObservableObject {
    /// 常驻单例：自动抓取调度挂在它上面（App 生命周期内不被释放）
    static let shared = SourceStore()

    @Published var sources: [FeedSource] = []
    @Published var folders: [Folder] = []
    @Published var isSyncing = false
    @Published var lastSyncMessage = ""

    private let db = Database.shared

    enum SyncError: LocalizedError {
        case alreadyRunning
        var errorDescription: String? { "已有抓取任务正在运行" }
    }

    // MARK: 自动抓取调度

    private var syncTimer: Timer?
    /// 自动抓取间隔（秒），默认 15 分钟。持久化到 UserDefaults，启动时读回。
    var syncInterval: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: "sourceStore.syncIntervalMin")
            return (v > 0 ? v : 15) * 60
        }
    }
    /// 设置抓取间隔（分钟），持久化 + 重启调度 Timer 生效
    func setSyncInterval(minutes: Int) {
        UserDefaults.standard.set(Double(minutes), forKey: "sourceStore.syncIntervalMin")
        // 重启调度让新间隔生效
        if syncTimer != nil {
            stopAutoSync()
            startAutoSync()
        }
    }
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
        // 关键：sources 数组初始为空（只在 reload()/syncAll 末尾填充）。
        // 启动时若不调 reload()，syncAll 遍历空 sources → 一个源都不抓（实测重启 0 抓取）。
        // 先 reload 填充，再启动调度。
        reload()
        Task { await syncAll(manual: false) }
        // Timer 周期取 min(全局 syncInterval, 源最小 fetchIntervalMin)——修 P2-12：
        // 用户把某源设 5min 但全局 Timer 15min，该源永远不可能按 5min 抓。
        // 用最小间隔做 Timer 周期，isDue 内部再按各源间隔判断（快源按时抓，慢源跳过）。
        let minSourceInterval = sources.map { $0.fetchIntervalMin }.min() ?? Int(syncInterval / 60)
        let effectiveInterval = min(syncInterval, TimeInterval(max(minSourceInterval, 1) * 60))
        syncTimer = Timer.scheduledTimer(withTimeInterval: effectiveInterval, repeats: true) { [weak self] _ in
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

    /// 重命名订阅源
    func renameSource(id: Int64, name: String) {
        db.execute("UPDATE content_source SET name = ? WHERE id = ?", params: [name, id])
        reload()
    }

    /// 把源指派到文件夹(nil = 移出到未分组)
    func assignSource(sourceId: Int64, folderId: Int64?) {
        db.execute("UPDATE content_source SET folder_id = ? WHERE id = ?",
                   params: [folderId.map { Int($0) }, sourceId])
        reload()
    }

    /// 文件夹级管线开关
    /// 文件夹级批量设置管线开关：把该值写入组内每个源的 config（不写 folder.config）。
    /// 设计：文件夹的值没有意义，实际处理只按单个源——文件夹选项仅作批量设置入口 + 打钩显示组内一致性。
    func setFolderPolicy(id: Int64, key: String, value: Bool) {
        let col = ["auto_score":"auto_score","auto_translate":"auto_translate",
                   "auto_summarize":"auto_summarize","auto_transcribe":"auto_transcribe"][key] ?? key
        var sids: [Int64] = []
        for src in sources(inFolder: id) {
            sids.append(src.id)
            let current = db.scalarString("SELECT config FROM content_source WHERE id = ?", params: [src.id]) ?? "{}"
            var obj = (try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any]) ?? [:]
            obj[key] = value
            if let data = try? JSONSerialization.data(withJSONObject: obj),
               let str = String(data: data, encoding: .utf8) {
                db.execute("UPDATE content_source SET config = ? WHERE id = ?", params: [str, src.id])
            }
        }
        // 关→开：不碰 per-item；开→关：文件夹内所有源的条目一次批量置零
        if !value, !sids.isEmpty {
            let placeholders = sids.map { _ in "?" }.joined(separator: ",")
            db.execute("UPDATE content SET \(col)=0 WHERE source_id IN (\(placeholders)) AND \(col) IS NOT 0",
                       params: sids)
        }
        reload()
    }

    /// 查某源的文件夹开关(供生效判定)。已废弃——管线改为纯按源处理，folder 不再存管线值。
    /// 保留仅为兼容旧调用（返回空策略，不影响生效）。
    func folderPolicy(for source: FeedSource) -> PipelinePolicy {
        PipelinePolicy()
    }

    /// 该源所属文件夹的原始 config JSON。已废弃——folder 不再存管线覆盖值，恒返回空。
    func folderConfig(for source: FeedSource) -> String {
        "{}"
    }

    // MARK: 增删改

    /// 该 identifier 是否已存在于订阅源列表（OPML 预检去重用）
    func existsByIdentifier(_ identifier: String) -> Bool {
        db.scalarInt("SELECT 1 FROM content_source WHERE identifier = ? LIMIT 1", params: [identifier]) != nil
    }

    /// OPML 确认后批量写库：按保留项插入（已存在项跳过）。
    /// 一次性攒完所有 insert 再 reload（避免几百条 reload 几百次）。
    /// - Parameters:
    ///   - items: 汇总页保留的条目（已剔除移除 + 已存在）
    ///   - policies: 每个 url 对应的内容管线开关（4 选）
    /// - Returns: 新插入源的 id 列表（供添加后自动刷新）
    func commitImport(_ items: [OPMLImportItem],
                      policies: [String: PipelinePolicy]) -> [Int64] {
        var insertedIds: [Int64] = []
        // 先建文件夹并映射 name→id（保证重名文件夹只建一个）
        var folderIdByName: [String: Int64] = [:]
        for f in folders { folderIdByName[f.name] = f.id }
        func folderId(for name: String?) -> Int64? {
            guard let name, !name.isEmpty else { return nil }
            if let id = folderIdByName[name] { return id }
            db.execute("INSERT OR IGNORE INTO folder (name) VALUES (?)", params: [name])
            if let row = db.scalarInt("SELECT id FROM folder WHERE name = ?", params: [name]) {
                let id = Int64(row)
                folderIdByName[name] = id
                return id
            }
            return nil
        }
        for item in items {
            guard !existsByIdentifier(item.url) else { continue }
            let fid = folderId(for: item.folderName)
            let p = policies[item.url] ?? PipelinePolicy()
            // OPML 汇总页用 article 表示普通文章源；数据库统一使用 rss。
            let storedStype = item.stype == "article" ? "rss" : item.stype
            let configObj: [String: Any] = [
                "fetch_mode": item.fetchModeRaw,
                "fetch_mode_auto": true,
                "auto_score": p.autoScore,
                "auto_translate": p.autoTranslate,
                "auto_transcribe": p.autoTranscribe,
                "auto_summarize": p.autoSummarize,
            ]
            guard let configStr = (try? JSONSerialization.data(withJSONObject: configObj))
                    .flatMap({ String(data: $0, encoding: .utf8) }) else { continue }
            let ok = db.execute(
                "INSERT INTO content_source (stype, name, identifier, enabled, config, folder_id) VALUES (?,?,?,1,?,?)",
                params: [storedStype, item.name, item.url, configStr, fid.map { Int($0) }]
            )
            if ok, let row = db.scalarInt("SELECT id FROM content_source WHERE identifier = ?", params: [item.url]) {
                insertedIds.append(Int64(row))
            }
        }
        reload()
        return insertedIds
    }

    /// 添加订阅源（RSS/播客直接用 url；YouTube 传频道 url 或 UC id）
    /// 添加时自动探测全文模式（仅 RSS 文章类需要; 播客/YouTube 不抓正文, 跳过探测）
    @discardableResult
    func addSource(stype: String, name: String, identifier: String, folderId: Int64? = nil,
                   pipeline: PipelinePolicy = PipelinePolicy(), fetchMode: FetchMode? = nil) async -> Int64? {
        var config = "{}"
        if stype == "rss" || stype == "youtube" {
            let mode: FetchMode
            if let m = fetchMode {
                mode = m
            } else {
                mode = await FullTextFetcher.shared.probeMode(feedUrl: identifier)
            }
            config = "{\"fetch_mode\":\"\(mode.rawValue)\"}"
        }
        // 合并管线开关 + 默认抓取间隔到 config
        if let data = config.data(using: .utf8),
           var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if pipeline.autoScore || pipeline.autoTranslate || pipeline.autoSummarize || pipeline.autoTranscribe {
                obj["auto_score"] = pipeline.autoScore
                obj["auto_translate"] = pipeline.autoTranslate
                obj["auto_summarize"] = pipeline.autoSummarize
                obj["auto_transcribe"] = pipeline.autoTranscribe
            }
            if obj["fetch_interval_min"] == nil {
                obj["fetch_interval_min"] = Int(syncInterval / 60)
            }
            if let merged = try? JSONSerialization.data(withJSONObject: obj),
               let str = String(data: merged, encoding: .utf8) {
                config = str
            }
        }
        let ok = db.execute(
            "INSERT OR IGNORE INTO content_source (stype, name, identifier, enabled, config, folder_id) VALUES (?,?,?,1,?,?)",
            params: [stype, name, identifier, config, folderId.map { Int($0) } as Any?]
        )
        guard ok else { return nil }
        reload()
        // 取回刚插入（或已存在）的源 id，供立即抓取首批使用
        guard let row = db.scalarInt("SELECT id FROM content_source WHERE identifier = ?", params: [identifier]) else { return nil }
        return Int64(row)
    }

    /// 设置某源的全文提取模式——auto=自动检测（四级优先级），off=关闭全文
    /// 自动检测确定后记录 fetch_mode（后续固定用该模式）
    func setFetchMode(id: Int64, mode: String) async {
        let current = db.scalarString("SELECT config FROM content_source WHERE id = ?", params: [id]) ?? "{}"
        var obj = (try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any]) ?? [:]
        if mode == "auto" {
            // 自动检测——跑 probeMode 确定最高优先级模式
            guard let identifier = db.scalarString("SELECT identifier FROM content_source WHERE id = ?", params: [id]) else { return }
            let detected = await FullTextFetcher.shared.probeMode(feedUrl: identifier)
            obj["fetch_mode"] = detected.rawValue
            obj["fetch_mode_auto"] = true   // 标记是自动检测的
        } else if mode == "off" {
            // 关闭全文提取 = summary 兜底（不抓全文，只留 feed 摘要）。
            // 统一用 summary 表达「关闭」——播客的显示摘要和文章的抓不到兜底本质相同
            obj["fetch_mode"] = "summary"
            obj["fetch_mode_auto"] = false
        } else if FetchMode(rawValue: mode) != nil {
            // 手动指定具体模式（defuddle / feed_full / summary）
            obj["fetch_mode"] = mode
            obj["fetch_mode_auto"] = false
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let str = String(data: data, encoding: .utf8) {
            db.execute("UPDATE content_source SET config = ? WHERE id = ?", params: [str, id])
        }
        reload()
    }

    /// 重新检测某源的全文模式（强制重跑 probeMode）
    func redetectFetchMode(id: Int64) async {
        guard let identifier = db.scalarString("SELECT identifier FROM content_source WHERE id = ?", params: [id]) else { return }
        let detected = await FullTextFetcher.shared.probeMode(feedUrl: identifier)
        let current = db.scalarString("SELECT config FROM content_source WHERE id = ?", params: [id]) ?? "{}"
        var obj = (try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any]) ?? [:]
        obj["fetch_mode"] = detected.rawValue
        obj["fetch_mode_auto"] = true
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let str = String(data: data, encoding: .utf8) {
            db.execute("UPDATE content_source SET config = ? WHERE id = ?", params: [str, id])
        }
        reload()
    }

    /// 批量重新检测多个源的全文模式（OPML 导入后后台调用）。
    /// 跳过 podcast（音频无可读全文，走 summary）；rss 与 youtube 都参与探测——
    /// youtube 现在会探测成 defuddle（靠视频页抓字幕 + 转录管线出稿，而非"仅摘要"退化）。
    func probeFetchModes(ids: [Int64]) async {
        for id in ids {
            guard let stype = db.scalarString("SELECT stype FROM content_source WHERE id = ?", params: [id]),
                  stype == "rss" || stype == "youtube" else { continue }
            await redetectFetchMode(id: id)
        }
    }

    /// 批量用 feed 内容探测校正 stype（OPML 导入后后台调用）：
    /// 自动发现/URL 猜 type 都可能漏判播客或 YouTube，这里统一用 FeedFetcher.kind
    /// 重新抓取该源 feed、看 enclosure/yt:videoId 特征校正 rss→podcast/youtube。
    func redetectStypes(ids: [Int64]) async {
        for id in ids {
            guard let identifier = db.scalarString("SELECT identifier FROM content_source WHERE id = ?", params: [id]) else { continue }
            do {
                let (_, feed) = try await FeedFetcher.discoverAndFetch(urlString: identifier)
                let detected: String = {
                    switch feed.kind {
                    case .article: return "rss"
                    case .podcast: return "podcast"
                    case .video:   return "youtube"
                    }
                }()
                // 只校正更"丰富"的方向：rss→podcast/youtube；已显式 podcast/youtube 不动
                guard let current = db.scalarString("SELECT stype FROM content_source WHERE id = ?", params: [id]),
                      current == "rss", detected != "rss" else { continue }
                db.execute("UPDATE content_source SET stype = ? WHERE id = ?", params: [detected, id])
            } catch {
                // 抓不到就保留原 guessType 结果，不阻断
            }
        }
        reload()
    }

    /// 文件夹级批量设全文提取模式（对文件夹内所有源统一设置）
    func setFolderFetchMode(folderId: Int64, mode: FetchMode) {
        let ids = db.queryRows("SELECT id FROM content_source WHERE folder_id = ?",
                               params: [folderId]).compactMap { Int64($0["id"] ?? "") }
        for sid in ids {
            let current = db.scalarString("SELECT config FROM content_source WHERE id = ?", params: [sid]) ?? "{}"
            var obj = (try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any]) ?? [:]
            obj["fetch_mode"] = mode.rawValue
            if let data = try? JSONSerialization.data(withJSONObject: obj),
               let str = String(data: data, encoding: .utf8) {
                db.execute("UPDATE content_source SET config = ? WHERE id = ?", params: [str, sid])
            }
        }
        reload()
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

    /// 设置某源最多保留条数（0 = 不限制）。超出后最旧的自动软删除。
    func setMaxKeep(id: Int64, count: Int) {
        let current = db.scalarString("SELECT config FROM content_source WHERE id = ?", params: [id]) ?? "{}"
        var obj = (try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any]) ?? [:]
        obj["max_keep"] = count
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let str = String(data: data, encoding: .utf8) {
            db.execute("UPDATE content_source SET config = ? WHERE id = ?", params: [str, id])
        }
        reload()
    }

    /// 执行源级保留策略：超出 max_keep 的最旧内容自动软删除。
    /// 返回删除条数。
    @discardableResult
    func enforceMaxKeep(sourceId: Int64) -> Int {
        guard let src = sources.first(where: { $0.id == sourceId }), src.maxKeep > 0 else { return 0 }
        // 查该源超出保留量的最旧内容（按 published_at 升序，取超出部分）
        let excess = db.queryRows("""
            SELECT id FROM content
            WHERE source_id = ? AND deleted_at IS NULL AND is_duplicate = 0
            ORDER BY published_at ASC
            LIMIT MAX(0, (SELECT COUNT(*) FROM content WHERE source_id = ? AND deleted_at IS NULL AND is_duplicate = 0) - ?);
            """, params: [sourceId, sourceId, src.maxKeep])
        var n = 0
        for row in excess {
            guard let cid = Int64(row["id"] ?? "") else { continue }
            db.execute("UPDATE content SET deleted_at = datetime('now') WHERE id = ?", params: [cid])
            n += 1
        }
        return n
    }

    /// 文件夹级批量设置抓取间隔（对文件夹内所有源统一设置）
    func setFolderFetchInterval(folderId: Int64, minutes: Int) {
        let ids = db.queryRows("SELECT id FROM content_source WHERE folder_id = ?",
                               params: [folderId]).compactMap { Int64($0["id"] ?? "") }
        for sid in ids {
            setFetchInterval(id: sid, minutes: minutes)
        }
    }

    // MARK: - 文件夹抓取设置（统一菜单用）

    /// 文件夹内所有源（按 folder_id）
    func sources(inFolder folderId: Int64) -> [FeedSource] {
        sources.filter { $0.folderId == folderId }
    }

    /// 文件夹级批量设为「自动检测」模式（对每个源跑 probeMode 确定模式，标记 auto）
    func setFolderFetchModeAuto(folderId: Int64) async {
        for src in sources(inFolder: folderId) {
            await setFetchMode(id: src.id, mode: "auto")
        }
    }

    /// 文件夹级批量重新检测（对每个源强制重跑 probeMode）
    func redetectFolderFetchMode(folderId: Int64) async {
        for src in sources(inFolder: folderId) {
            await redetectFetchMode(id: src.id)
        }
    }

    /// 文件夹级批量设为「仅摘要」（关闭全文提取=summary 兜底, auto=false）
    func setFolderFetchModeOff(folderId: Int64) {
        for src in sources(inFolder: folderId) {
            let current = db.scalarString("SELECT config FROM content_source WHERE id = ?", params: [src.id]) ?? "{}"
            var obj = (try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any]) ?? [:]
            obj["fetch_mode"] = "summary"
            obj["fetch_mode_auto"] = false
            if let data = try? JSONSerialization.data(withJSONObject: obj),
               let str = String(data: data, encoding: .utf8) {
                db.execute("UPDATE content_source SET config = ? WHERE id = ?", params: [str, src.id])
            }
        }
        reload()
    }

    func removeSource(id: Int64) {
        // 只删除订阅关系；历史内容由 ON DELETE SET NULL 保留，仍可在“全部”中阅读和搜索。
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
        // 关→开：不碰 per-item 字段，由 UI 弹窗决定；开→关：该源所有条目立刻置 0
        if !value {
            let col = ["auto_score":"auto_score","auto_translate":"auto_translate",
                       "auto_summarize":"auto_summarize","auto_transcribe":"auto_transcribe"][key] ?? key
            db.execute("UPDATE content SET \(col)=0 WHERE source_id=? AND \(col) IS NOT 0", params: [id])
        }
        reload()
    }

    // MARK: 抓取

    /// 抓取所有启用的源。manual=true 忽略频率限制全抓；自动调度(false)只抓到期的源。
    func syncAll(manual: Bool = true) async {
        // @MainActor 在 await 时允许重入；isSyncing 必须既是 UI 状态也是入口锁。
        guard !isSyncing else { return }
        isSyncing = true
        defer {
            isSyncing = false
            reload()
        }
        lastSyncMessage = ""
        var total = 0
        var failed = 0
        var skipped = 0
        // B3: 媒体板块总开关——关掉后 podcast/youtube 等媒体源整组不抓（rss 文章不受影响）
        let mediaOn = FeatureBoard.media.enabled
        var mediaSkipped = 0
        for src in sources where src.enabled {
            if !mediaOn && src.transcribable { mediaSkipped += 1; continue }
            // 自动调度时按源的抓取间隔筛选：距上次抓取不足间隔的跳过
            if !manual && !src.isDue { skipped += 1; continue }
            do {
                let n = try await syncOneUnlocked(src)
                total += n
            } catch {
                failed += 1
                db.execute("UPDATE content_source SET error = ? WHERE id = ?",
                           params: [error.localizedDescription, src.id])
            }
        }
        var msg = failed > 0 ? "完成：新增 \(total) 条，\(failed) 个源失败" : "完成：新增 \(total) 条"
        if skipped > 0 { msg += "（跳过未到期 \(skipped)）" }
        if mediaSkipped > 0 { msg += "（媒体板块已关闭，跳过 \(mediaSkipped) 个媒体源）" }
        lastSyncMessage = msg
    }

    /// 抓取单个源，返回新增条数
    @discardableResult
    func syncOne(_ src: FeedSource) async throws -> Int {
        // 单源刷新、添加源后的首次刷新与 syncAll 共用同一入口锁，避免网络请求重叠。
        guard !isSyncing else { throw SyncError.alreadyRunning }
        isSyncing = true
        defer { isSyncing = false }
        return try await syncOneUnlocked(src)
    }

    /// 已持有 isSyncing 锁时执行实际抓取；只允许 syncAll/syncOne 调用。
    private func syncOneUnlocked(_ src: FeedSource) async throws -> Int {
        let feed = try await FeedFetcher.fetch(urlString: src.identifier)
        // 频道级语言可安全回填该源的历史空值；单条 entry 的语言在 upsertContent 中优先处理。
        if let feedLanguage = ContentLanguage.normalize(feed.language) {
            db.execute("""
                UPDATE content SET language = ?
                WHERE source_id = ? AND (language IS NULL OR TRIM(language) = '');
                """, params: [feedLanguage, src.id])
        }
        var added = 0
        for entry in feed.entries {
            if let newId = upsertContent(source: src.stype, sourceId: src.id, entry: entry, pipeline: src.policy) {
                added += 1
                // 新文章: 按源的 fetch_mode 立即抓全文（播客跳过——无正文，YouTube 需要 defuddle 抓原文）
                if entry.meta["audio_url"] == nil {
                    await FullTextFetcher.shared.fetchAndStore(
                        contentId: newId, url: entry.url,
                        feedHtml: entry.html.isEmpty ? nil : entry.html,
                        mode: src.fetchMode
                    )
                }
                // 入库事件只负责唤醒规则；是否已具备所需文稿由导出规则的完成条件判断。
                await ExportService.shared.runPending(trigger: "ingest", contentId: newId)
                // “加工完成”规则的就绪条件与触发分离：不要求 AI 产物的规则在全文入库后即可交付；
                // 要求评分/摘要/译文/转录的规则此时不会匹配，后续由 Worker 再次触发。
                await ExportService.shared.runPending(trigger: "ready", contentId: newId)
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
    /// R3: 判重+插入包进事务——Timer 调度与手动同步并发时，原来的"先 SELECT 再 INSERT"两条语句间存在竞态会重复插入。
    private func upsertContent(source: String, sourceId: Int64, entry: ParsedEntry, pipeline: PipelinePolicy = PipelinePolicy()) -> Int64? {
        let ctype: String
        if entry.meta["video_id"] != nil { ctype = "video" }
        else if entry.meta["audio_url"] != nil { ctype = "podcast" }
        else { ctype = "article" }

        // ── 跨源内容去重：url 规范化(去追踪参数) + 标题归一化 → content_hash ──
        let normUrl = Self.normalizeUrl(entry.url)
        let normTitle = Self.normalizeTitle(entry.title)
        let hash = Self.contentHash(url: normUrl, title: normTitle)
        let published = entry.published.map { ISO8601DateFormatter().string(from: $0) }
        let language: String? = {
            if let declared = ContentLanguage.normalize(entry.language) { return declared }
            let sample = entry.title + "\n" + Self.stripHtml(entry.html)
            return ContentLanguage.looksChinese(sample) ? "zh" : nil
        }()
        let metaJson = (try? JSONSerialization.data(withJSONObject: entry.meta))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        var newId: Int64? = nil
        // 事务内完成"查重 + 判 dup + 插入"，并发下不会出现两条重复主记录
        let committed = db.transaction {
            // 同源同 guid 已存在则跳过
            if let existingId = self.db.scalarInt("SELECT id FROM content WHERE source = ? AND guid = ?",
                                                   params: [source, entry.guid]) {
                if let language {
                    self.db.execute("""
                        UPDATE content SET language = ?
                        WHERE id = ? AND (language IS NULL OR TRIM(language) = '');
                        """, params: [language, existingId])
                }
                return true   // 已存在，提交空事务返回 nil
            }
            var isDup = 0
            var dupOf: Int64? = nil
            if let existingId = self.db.scalarInt("SELECT id FROM content WHERE content_hash = ? AND is_duplicate = 0 LIMIT 1",
                                                  params: [hash]) {
                isDup = 1
                dupOf = Int64(existingId)
            }
            // 播客/视频：简介(entry.html)剥标签写进 excerpt——播客的「摘要」存摘要字段，
            // content_html 之后可随统一规则删除（文章 content_html 是全文原料另行处理）
            let excerptForInsert: String? = (ctype == "podcast" || ctype == "video")
                ? Self.stripHtml(entry.html) : nil
            let ok = self.db.execute(
                """
                INSERT INTO content (ctype, guid, source, source_id, title, author, url, language, published_at, content_html, excerpt, fetch_status, meta, content_hash, is_duplicate, duplicate_of, auto_score, auto_translate, auto_summarize, auto_transcribe)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,0,?,?,?,?,?,?,?,?)
                """,
                params: [ctype, entry.guid, source, sourceId, entry.title, entry.author, entry.url,
                         language, published, entry.html, excerptForInsert, metaJson, hash, isDup,
                         dupOf.map { Int($0) },
                         pipeline.autoScore ? 1 : 0,
                         pipeline.autoTranslate ? 1 : 0,
                         pipeline.autoSummarize ? 1 : 0,
                         pipeline.autoTranscribe ? 1 : 0]
            )
            if ok { newId = self.db.lastInsertId() }
            return ok
        }
        guard committed, let cid = newId else { return nil }
        // 新内容应用过滤规则（标已读/加星/打标签）——事务外，不影响原子性
        FilterService.shared.applyRules(contentId: cid, sourceId: sourceId,
            title: entry.title, content: entry.html, author: entry.author ?? "", url: entry.url)
        return cid
    }

#if DEBUG
    /// 隔离数据库测试入口：验证 ParsedEntry.language 确实写入 content.language。
    func upsertContentForTesting(source: String, sourceId: Int64, entry: ParsedEntry) -> Int64? {
        upsertContent(source: source, sourceId: sourceId, entry: entry)
    }
#endif

    // MARK: 内容去重辅助

    /// 剥 HTML 标签成纯文本（压空白）——播客简介入 excerpt 用
    static func stripHtml(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return text
    }

    /// url 规范化：去 utm_*/fbclid/gclid 等追踪参数 + 去 fragment + 去尾斜杠 + 小写 scheme/host
    static func normalizeUrl(_ urlString: String) -> String {
        guard var comps = URLComponents(string: urlString) else { return urlString.lowercased() }
        comps.scheme = comps.scheme?.lowercased()
        comps.host = comps.host?.lowercased()
        comps.fragment = nil
        // 精确匹配名单（hasPrefix 会误杀 referral_id/refresh/fromage 等语义参数——
        // 比如 ?refresh=1 被当 ref 剥掉，导致同页不同参数被误判重复）
        let trackExact: Set<String> = ["fbclid", "gclid", "ref", "spm", "from", "source",
                                       "mc_cid", "mc_eid", "igshid", "dclid", "msclkid"]
        if let items = comps.queryItems {
            comps.queryItems = items.filter { item in
                let n = item.name.lowercased()
                // utm_* 前缀是安全的（utm 参数族命名规范，无语义撞车）
                if n.hasPrefix("utm_") { return false }
                return !trackExact.contains(n)
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
