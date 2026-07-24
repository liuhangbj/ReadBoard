import Foundation
import SQLite3

// MARK: - 后台管线 worker
// 周期扫描内容, 按源的"有效开关"(源 OR 文件夹)对未处理内容补跑打分/翻译/摘要/转录。
// 直接串行执行(whisper 吃 GPU、LLM 串行防限流), 同时记 content_job 追踪。
// App 内常驻 Timer 驱动, 自包含, 无 launchd/CLI。

@MainActor
public final class PipelineWorker: ObservableObject {
    static let shared = PipelineWorker()

    @Published var isRunning = false
    @Published var lastRunAt: String? = nil
    @Published var lastSummary = ""
    @Published var processedTotal = 0
    /// 死信任务数（失败 >=3 被永久跳过的）——设置页可查看并重置
    @Published var deadLetterCount = 0

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
        var scored = 0, translated = 0, summarized = 0, transcribed = 0, refetched = 0

        // 第 0 步: 全文回填——水位线后抓取失败(fetch_status=0/3)的文章按源 fetch_mode 重试,
        // 成功(fetch_status→2/4)后下一轮就能进管线。每轮限 10 条防抖。
        // fulltext 板块关则跳过回填。
        if FeatureBoard.fulltext.enabled {
            refetched = await backfillFullText()
        }

        // 转录依赖一次性检查：缺依赖则本轮所有转录任务跳过（不逐条死信浪费重试），
        // 并在 summary 里提示。用户装好依赖后下轮自动恢复。
        let transcribeReady = DependencyChecker.shared.transcribeReady
        let anyTranscribePending = tasks.contains { $0.needTranscribe }
        if anyTranscribePending && !transcribeReady {
            lastSummary = "⚠️ 转录依赖缺失（whisper/ffmpeg/模型），已跳过 \(tasks.filter { $0.needTranscribe }.count) 条转录任务。请去 设置→依赖 安装。"
        }

        for t in tasks.prefix(batchLimit) {
            // 打分（AI 板块总开关 && 打分子开关 && 源级开关，源级已在收集时判过）
            // R2: 每个管线调用包单任务超时——一条挂死不再拖垮整轮 worker
            if t.needScore, AIPipeline.score.effective {
                let ok = await Self.withTimeout(seconds: 180) {
                    await self.llm.score(contentId: t.id, title: t.title, body: t.body)
                } ?? false
                if ok { scored += 1; markJob(contentId: t.id, jtype: "score", ok: true) }
                else { markJob(contentId: t.id, jtype: "score", ok: false) }
                if ok { await ExportService.shared.runPending(trigger: "score", contentId: t.id) }
            }
            // 翻译（仅文章；媒体走转录）
            if t.needTranslate, AIPipeline.translate.effective {
                let ok = await Self.withTimeout(seconds: 180) {
                    await self.llm.translate(contentId: t.id, title: t.title, body: t.body)
                } ?? false
                if ok { translated += 1; markJob(contentId: t.id, jtype: "translate", ok: true) }
                else { markJob(contentId: t.id, jtype: "translate", ok: false) }
                if ok { await ExportService.shared.runPending(trigger: "translate", contentId: t.id) }
            }
            // 摘要（独立管线；若打分已带摘要则跳过）
            if t.needSummary, AIPipeline.summarize.effective {
                let ok = await Self.withTimeout(seconds: 180) {
                    await self.llm.summarize(contentId: t.id, title: t.title, body: t.body)
                } ?? false
                if ok { summarized += 1; markJob(contentId: t.id, jtype: "summarize", ok: true) }
                else { markJob(contentId: t.id, jtype: "summarize", ok: false) }
            }
            // 转录（媒体）——依赖缺失时跳过（上面已统一提示），不逐条记失败
            if t.needTranscribe, AIPipeline.transcribe.effective, transcribeReady {
                let ok = await Self.withTimeout(seconds: 600) {
                    await self.transcriber.transcribe(
                        contentId: t.id, title: t.title, audioUrl: t.audioUrl, pageUrl: t.url, language: t.language)
                } ?? false
                if ok { transcribed += 1 }  // transcribe 内部已记 job
                if ok { await ExportService.shared.runPending(trigger: "transcribe", contentId: t.id) }
            }
            done += 1
        }

        processedTotal += done
        deadLetterCount = countDeadLetters()
        // 依赖缺失提示优先保留；否则正常汇总
        if !(anyTranscribePending && !transcribeReady) {
            lastSummary = "本轮 \(done) 条：评分\(scored) 翻译\(translated) 摘要\(summarized) 转录\(transcribed) 全文补\(refetched)"
        }
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
        SELECT id, source, source_id, ctype, title, url, language, content_md, excerpt,
               llm_score, llm_summary, llm_translated_md, meta
        FROM content
        WHERE id > \(watermark)
          AND ((ctype IN ('podcast','video') OR meta LIKE '%audio_url%')
               OR fetch_status IN (2, 4))
        ORDER BY published_at DESC
        LIMIT 2000;
        """
        guard db.prepare(sql, &stmt) else { return [] }

        // 先收全行，再一次性算死信/退避——原实现在行循环里每行 4 次 SQL（2000 行最坏 8000 次/轮）
        struct Row {
            let id: Int64, sourceId: Int64?
            let title: String, url: String, language: String?, md: String?, excerpt: String?
            let hasScore: Bool, hasSummary: Bool, hasTranslated: Bool, isMedia: Bool
            let audioUrl: String?
        }
        var rawRows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let sourceId = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2)
            let ctype = colText(stmt, 3) ?? "article"
            let metaStr = colText(stmt, 12) ?? "{}"
            let audioUrl = Self.parseAudioUrl(metaStr)
            let isMedia = ctype == "podcast" || ctype == "video" || audioUrl != nil
            rawRows.append(Row(
                id: id, sourceId: sourceId,
                title: colText(stmt, 4) ?? "", url: colText(stmt, 5) ?? "",
                language: colText(stmt, 6), md: colText(stmt, 7), excerpt: colText(stmt, 8),
                hasScore: sqlite3_column_type(stmt, 9) != SQLITE_NULL,
                hasSummary: sqlite3_column_type(stmt, 10) != SQLITE_NULL,
                hasTranslated: sqlite3_column_type(stmt, 11) != SQLITE_NULL,
                isMedia: isMedia, audioUrl: audioUrl))
        }
        sqlite3_finalize(stmt)

        // 一次聚合查询算全量 content 的死信+退避状态（jtype → skip）
        let skipMap = failureSkipMap(contentIds: rawRows.map { $0.id })

        for r in rawRows {
            let id = r.id

            // 按具体源查开关; source_id 为 NULL(存量/异常)则无开关, 跳过
            guard let sid = r.sourceId, let pol = srcPolicies[sid], pol.enabled else { continue }
            let body = (r.md?.isEmpty == false ? r.md! : (r.excerpt ?? ""))
            let audioUrl = r.audioUrl
            let isMedia = r.isMedia
            let skip = skipMap[id] ?? [:]

            var t = PendingTask(id: id, title: r.title, url: r.url, body: body,
                                language: r.language, audioUrl: audioUrl)
            // R1: 各管线判定前先做失败退避/死信过滤——失败过多的不再反复调 LLM（治费用失控）
            // 打分：开关开 且 未打分 且 有正文 且 未死信
            if pol.policy.autoScore, !r.hasScore, !body.isEmpty,
               skip["score"] != true { t.needScore = true }
            // 摘要：开关开 且 未摘要 且 (有正文 或 转录后会有)；媒体等转录补摘要，跳过
            if pol.policy.autoSummarize, !r.hasSummary, !body.isEmpty, !isMedia,
               skip["summarize"] != true { t.needSummary = true }
            // 翻译：开关开 且 未翻译 且 文章有正文（媒体走转录）
            if pol.policy.autoTranslate, !r.hasTranslated, !isMedia, !body.isEmpty,
               skip["translate"] != true { t.needTranslate = true }
            // 转录：开关开 且 未转写 且 有媒体地址
            if pol.policy.autoTranscribe, !r.hasTranslated, isMedia, (audioUrl != nil || !r.url.isEmpty),
               skip["transcribe"] != true {
                t.needTranscribe = true
            }

            if t.needScore || t.needTranslate || t.needSummary || t.needTranscribe {
                out.append(t)
            }
        }
        return out
    }

    /// source_id → (enabled, 有效开关=源 OR 文件夹, fetch_mode)。按具体源 id 索引, 同 stype 源互不干扰。
    private struct SrcPolicy {
        let enabled: Bool
        let policy: PipelinePolicy
        let fetchMode: FetchMode
    }

    /// 全文回填：水位线后抓取失败/未抓的文章(fetch_status 0/3, 非媒体)，按源 fetch_mode 重试。
    /// 返回本轮成功补到全文的条数。每轮限 10 条防一轮跑太久。
    private func backfillFullText() async -> Int {
        let policies = fetchEffectivePolicies()
        guard db.open() else { return 0 }
        var stmt: OpaquePointer?
        // (id, source_id, url, content_html)
        let sql = """
        SELECT id, source_id, url, content_html FROM content
        WHERE id > \(watermark)
          AND fetch_status IN (0, 3)
          AND ctype = 'article'
          AND source_id IS NOT NULL
        ORDER BY id DESC LIMIT 10;
        """
        guard db.prepare(sql, &stmt) else { return 0 }
        var rows: [(Int64, Int64, String, String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let sid = sqlite3_column_int64(stmt, 1)
            let url = colText(stmt, 2) ?? ""
            let html = colText(stmt, 3)
            rows.append((id, sid, url, html))
        }
        sqlite3_finalize(stmt)

        var ok = 0
        for (id, sid, url, html) in rows {
            guard let pol = policies[sid], pol.enabled else { continue }
            // summary 模式不需要抓(本来就没全文), 跳过避免来回置状态
            if pol.fetchMode == .summary { continue }
            let success = await FullTextFetcher.shared.fetchAndStore(
                contentId: id, url: url, feedHtml: html, mode: pol.fetchMode)
            if success { ok += 1 }
        }
        return ok
    }

    private func fetchEffectivePolicies() -> [Int64: SrcPolicy] {
        guard db.open() else { return [:] }
        var stmt: OpaquePointer?
        var map: [Int64: SrcPolicy] = [:]
        let sql = """
        SELECT s.id, s.enabled, s.config, f.config
        FROM content_source s
        LEFT JOIN folder f ON s.folder_id = f.id;
        """
        guard db.prepare(sql, &stmt) else { return [:] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sid = sqlite3_column_int64(stmt, 0)
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
            // 从源 config 解析 fetch_mode
            var mode: FetchMode = .summary
            if let data = srcCfg.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = obj["fetch_mode"] as? String,
               let m = FetchMode(rawValue: raw) { mode = m }
            map[sid] = SrcPolicy(enabled: enabled, policy: eff, fetchMode: mode)
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

    // MARK: R1 失败退避 / 死信（治 LLM 费用失控：失败任务不再每 120s 无限重试）

    /// 该 content+jtype 是否应跳过（单条版，保留给单篇重试场景）
    private func shouldSkipForFailures(contentId: Int64, jtype: String) -> Bool {
        failureSkipMap(contentIds: [contentId])[contentId]?[jtype] == true
    }

    /// 批量算死信/退避：对一批 content 一次 SQL 取全量失败记录，内存聚合。
    /// 返回 content_id → (jtype → 是否跳过)。规则：
    /// - 某 jtype 累计失败 >= 3 → 死信，永久跳过（除非手动重置）
    /// - 最近一次失败在 1h 内 → 退避，本轮跳过
    /// 原实现逐行 4 次 SQL，2000 行最坏 8000 次/120s 轮询，DB 往返开销失控。
    private func failureSkipMap(contentIds: [Int64]) -> [Int64: [String: Bool]] {
        guard !contentIds.isEmpty else { return [:] }
        // content_id 去重（同 id 不会重复，但保险）
        let uniqueIds = Array(Set(contentIds))
        var result: [Int64: [String: Bool]] = [:]
        // SQLite 单查询变量上限 999，分批 IN 查询（每批 500 留余量）
        for batch in uniqueIds.chunked(into: 500) {
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            let rows = db.queryRows("""
                SELECT content_id, jtype, status, finished_at FROM content_job
                WHERE content_id IN (\(placeholders))
                  AND status IN (2, 3)
                ORDER BY content_id, jtype, id DESC;
                """, params: batch)
            // 内存聚合：每 (content_id, jtype) 第一行是最近一次（ORDER BY id DESC）
            var lastStatus: [String: (status: String, finishedAt: String?)] = [:]
            var failCount: [String: Int] = [:]
            for r in rows {
                guard let cidStr = r["content_id"], let cid = Int64(cidStr),
                      let jt = r["jtype"], let st = r["status"] else { continue }
                let key = "\(cid)|\(jt)"
                if lastStatus[key] == nil {
                    lastStatus[key] = (st, r["finished_at"])
                }
                if st == "3" { failCount[key, default: 0] += 1 }
            }
            for (key, last) in lastStatus {
                let parts = key.split(separator: "|", maxSplits: 1)
                guard let cid = Int64(parts[0]) else { continue }
                let jt = String(parts[1])
                var skip = false
                if (failCount[key] ?? 0) >= 3 {
                    skip = true   // 死信
                } else if last.status == "3", let ts = last.finishedAt,
                          let lastDate = Self.utcDate(ts),
                          Date().timeIntervalSince(lastDate) < 3600 {
                    skip = true   // 退避
                }
                if skip { result[cid, default: [:]][jt] = true }
            }
        }
        return result
    }

    /// 解析 SQLite datetime('now') 的 UTC 字符串
    private static func utcDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }

    // MARK: 死信管理（设置页可查看/重置）

    /// 死信任务数（某 content+jtype 累计失败 >=3）
    func countDeadLetters() -> Int {
        let rows = db.queryRows("""
            SELECT content_id, jtype, COUNT(*) AS fails FROM content_job
            WHERE status = 3 GROUP BY content_id, jtype HAVING fails >= 3;
            """)
        return rows.count
    }

    /// 死信任务明细（设置页列表）
    func deadLetters() -> [(contentId: Int64, jtype: String, fails: Int)] {
        db.queryRows("""
            SELECT content_id, jtype, COUNT(*) AS fails FROM content_job
            WHERE status = 3 GROUP BY content_id, jtype HAVING fails >= 3
            ORDER BY fails DESC LIMIT 100;
            """).compactMap { r in
            guard let cid = Int64(r["content_id"] ?? ""), let jt = r["jtype"] else { return nil }
            return (cid, jt, Int(r["fails"] ?? "0") ?? 0)
        }
    }

    /// 重置死信：删掉该 content+jtype 的失败记录，下轮 worker 会重新尝试
    func resetDeadLetter(contentId: Int64, jtype: String) {
        db.execute("DELETE FROM content_job WHERE content_id = ? AND jtype = ? AND status = 3",
                   params: [contentId, jtype])
        deadLetterCount = countDeadLetters()
    }

    /// 一键重置全部死信
    func resetAllDeadLetters() {
        db.execute("DELETE FROM content_job WHERE status = 3")
        deadLetterCount = 0
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

    /// R2 单任务超时包装：operation 超时未返回则返回 nil（调用方据此记失败放行）。
    /// 用竞速 TaskGroup：先到先用，超时分支返回 nil。operation 在后台继续跑也无妨（其结果被丢弃）。
    static func withTimeout<T: Sendable>(seconds: TimeInterval,
                                         operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// 数组分批（SQLite IN 查询变量上限 999，大批量 ID 需分片）
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var out: [[Element]] = []
        var i = 0
        while i < count {
            out.append(Array(self[i..<Swift.min(i + size, count)]))
            i += size
        }
        return out
    }
}
