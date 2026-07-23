import Foundation
import SQLite3

// MARK: - 后台管线 worker
// 周期扫描内容, 按源的"有效开关"(源 OR 文件夹)对未处理内容补跑打分/翻译/摘要/转录。
// 直接串行执行(whisper 吃 GPU、LLM 串行防限流), 同时记 content_job 追踪。
// App 内常驻 Timer 驱动, 自包含, 无 launchd/CLI。

@MainActor
final class PipelineWorker: ObservableObject {
    static let shared = PipelineWorker()

    @Published var isRunning = false
    @Published var lastRunAt: String? = nil
    @Published var lastSummary = ""
    @Published var processedTotal = 0

    private let db = Database.shared
    private let llm = LLMPipeline()
    private let transcriber = TranscribePipeline()
    private var timer: Timer?

    /// 扫描间隔（秒）
    var interval: TimeInterval = 120
    /// 每轮最多处理条数（防一次跑太久）
    var batchLimit = 30

    // MARK: 存量保护
    // worker 只处理"水位线之后"的新内容, 存量一律不碰(避免全量跑历史又贵又慢)。
    // 水位线 = 首次启动时的最大内容 id, 持久化到 UserDefaults, 重启不累加旧的。

    private let watermarkKey = "pipelineWorker.watermarkId"

    /// 存量水位线：小于等于此 id 的内容不处理
    private(set) var watermark: Int64 = 0

    /// 初始化水位线：已存则读，否则取当前最大 id 并持久化
    private func initWatermark() {
        let saved = UserDefaults.standard.integer(forKey: watermarkKey)
        if saved > 0 {
            watermark = Int64(saved)
            return
        }
        let maxId = db.scalarInt("SELECT COALESCE(MAX(id),0) FROM content;") ?? 0
        watermark = Int64(maxId)
        UserDefaults.standard.set(maxId, forKey: watermarkKey)
    }

    private init() {
        initWatermark()
    }

    // MARK: Timer 生命周期

    func start() {
        guard timer == nil else { return }
        // 立即跑一轮，再周期跑
        Task { await runOnce() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runOnce() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: 单轮执行

    /// 扫描一轮：找出所有需要处理的内容并执行。返回本轮处理条数。
    @discardableResult
    func runOnce() async -> Int {
        guard !isRunning else { return 0 }
        isRunning = true
        defer {
            isRunning = false
            lastRunAt = Self.nowString()
        }

        let tasks = collectPendingTasks()
        var done = 0
        var scored = 0, translated = 0, summarized = 0, transcribed = 0

        for t in tasks.prefix(batchLimit) {
            // 打分
            if t.needScore {
                if await llm.score(contentId: t.id, title: t.title, body: t.body) {
                    scored += 1; markJob(contentId: t.id, jtype: "score", ok: true)
                } else { markJob(contentId: t.id, jtype: "score", ok: false) }
            }
            // 翻译（仅文章；媒体走转录）
            if t.needTranslate {
                if await llm.translate(contentId: t.id, title: t.title, body: t.body) {
                    translated += 1; markJob(contentId: t.id, jtype: "translate", ok: true)
                } else { markJob(contentId: t.id, jtype: "translate", ok: false) }
            }
            // 摘要（独立管线；若打分已带摘要则跳过）
            if t.needSummary {
                if await llm.summarize(contentId: t.id, title: t.title, body: t.body) {
                    summarized += 1; markJob(contentId: t.id, jtype: "summarize", ok: true)
                } else { markJob(contentId: t.id, jtype: "summarize", ok: false) }
            }
            // 转录（媒体）
            if t.needTranscribe {
                let ok = await transcriber.transcribe(
                    contentId: t.id, title: t.title, audioUrl: t.audioUrl, pageUrl: t.url, language: t.language)
                if ok { transcribed += 1 }  // transcribe 内部已记 job
            }
            done += 1
        }

        processedTotal += done
        lastSummary = "本轮 \(done) 条：评分\(scored) 翻译\(translated) 摘要\(summarized) 转录\(transcribed)"
        if done > 0 {
            NotificationCenter.default.post(name: .contentUpdated, object: nil)
        }
        return done
    }

    // MARK: 待处理任务收集

    private struct PendingTask {
        let id: Int64
        let title: String
        let url: String
        let body: String
        let language: String?
        let audioUrl: String?
        var needScore = false
        var needTranslate = false
        var needSummary = false
        var needTranscribe = false
    }

    /// 扫描内容，对每条算有效开关(源 OR 文件夹)，挑出需要处理但还没结果的
    private func collectPendingTasks() -> [PendingTask] {
        // 1. 源 stype/enabled/config/folder config 快照：source 名 → (stype, enabled, 有效开关)
        let srcPolicies = fetchEffectivePolicies()
        // 2. 遍历内容，只取"有全文或有音频"且该源启用、有任一管线待跑的
        guard db.open() else { return [] }
        var stmt: OpaquePointer?
        var out: [PendingTask] = []
        // 媒体项(podcast/video)不看 fetch_status——音频在 enclosure 里, 无正文可抓, fetch_status 恒为 0;
        // 文章类要求 fetch_status IN (2成功, 4直入) 才有正文可打分/翻译。
        // 只扫水位线之后的新内容(id > watermark), 存量不动。
        let sql = """
        SELECT id, source, ctype, title, url, language, content_md, excerpt,
               llm_score, llm_summary, llm_translated_md, meta
        FROM content
        WHERE id > \(watermark)
          AND ((ctype IN ('podcast','video') OR meta LIKE '%audio_url%')
               OR fetch_status IN (2, 4))
        ORDER BY published_at DESC
        LIMIT 2000;
        """
        guard db.prepare(sql, &stmt) else { return [] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let source = colText(stmt, 1) ?? ""
            let ctype = colText(stmt, 2) ?? "article"
            let title = colText(stmt, 3) ?? ""
            let url = colText(stmt, 4) ?? ""
            let language = colText(stmt, 5)
            let md = colText(stmt, 6)
            let excerpt = colText(stmt, 7)
            let hasScore = sqlite3_column_type(stmt, 8) != SQLITE_NULL
            let hasSummary = sqlite3_column_type(stmt, 9) != SQLITE_NULL
            let hasTranslated = sqlite3_column_type(stmt, 10) != SQLITE_NULL
            let metaStr = colText(stmt, 11) ?? "{}"

            guard let pol = srcPolicies[source], pol.enabled else { continue }
            let body = (md?.isEmpty == false ? md! : (excerpt ?? ""))
            let audioUrl = Self.parseAudioUrl(metaStr)
            let isMedia = ctype == "podcast" || ctype == "video" || audioUrl != nil

            var t = PendingTask(id: id, title: title, url: url, body: body,
                                language: language, audioUrl: audioUrl)
            // 打分：开关开 且 未打分 且 有正文
            if pol.policy.autoScore, !hasScore, !body.isEmpty { t.needScore = true }
            // 摘要：开关开 且 未摘要 且 (有正文 或 转录后会有)；媒体等转录补摘要，跳过
            if pol.policy.autoSummarize, !hasSummary, !body.isEmpty, !isMedia { t.needSummary = true }
            // 翻译：开关开 且 未翻译 且 文章有正文（媒体走转录）
            if pol.policy.autoTranslate, !hasTranslated, !isMedia, !body.isEmpty { t.needTranslate = true }
            // 转录：开关开 且 未转写 且 有媒体地址
            if pol.policy.autoTranscribe, !hasTranslated, isMedia, (audioUrl != nil || !url.isEmpty) {
                t.needTranscribe = true
            }

            if t.needScore || t.needTranslate || t.needSummary || t.needTranscribe {
                out.append(t)
            }
        }
        return out
    }

    /// source 名 → (stype, enabled, 有效开关=源 OR 文件夹)
    private struct SrcPolicy {
        let enabled: Bool
        let policy: PipelinePolicy
    }

    private func fetchEffectivePolicies() -> [String: SrcPolicy] {
        guard db.open() else { return [:] }
        var stmt: OpaquePointer?
        var map: [String: SrcPolicy] = [:]
        let sql = """
        SELECT s.stype, s.enabled, s.config, f.config
        FROM content_source s
        LEFT JOIN folder f ON s.folder_id = f.id;
        """
        guard db.prepare(sql, &stmt) else { return [:] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let stype = colText(stmt, 0) ?? "rss"
            let enabled = sqlite3_column_int64(stmt, 1) == 1
            let srcCfg = colText(stmt, 2) ?? "{}"
            let folderCfg = colText(stmt, 3) ?? "{}"
            let sp = PipelinePolicy.from(configJson: srcCfg)
            let fpp = PipelinePolicy.from(configJson: folderCfg)
            // 有效 = 源 OR 文件夹
            let eff = PipelinePolicy(
                autoScore: sp.autoScore || fpp.autoScore,
                autoTranslate: sp.autoTranslate || fpp.autoTranslate,
                autoTranscribe: sp.autoTranscribe || fpp.autoTranscribe,
                autoSummarize: sp.autoSummarize || fpp.autoSummarize
            )
            // content.source 与 content_source.stype 对应（按 stype 归组）
            map[stype] = SrcPolicy(enabled: enabled, policy: eff)
        }
        return map
    }

    // MARK: 辅助

    private static func parseAudioUrl(_ metaStr: String) -> String? {
        guard let data = metaStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["audio_url"] as? String) ?? (obj["video_url"] as? String)
    }

    private func markJob(contentId: Int64, jtype: String, ok: Bool) {
        db.execute(
            "INSERT INTO content_job (content_id, jtype, status, finished_at, error) VALUES (?,?,?,datetime('now'),?)",
            params: [contentId, jtype, ok ? 2 : 3, ok ? nil : "failed"])
    }

    private func colText(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: p)
    }

    private static func nowString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
