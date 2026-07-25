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
                else { markJob(contentId: t.id, jtype: "score", ok: false, error: llm.lastError) }
                if ok { await ExportService.shared.runPending(trigger: "score", contentId: t.id) }
            }
            // 翻译（仅文章；媒体走转录）
            if t.needTranslate, AIPipeline.translate.effective {
                let ok = await Self.withTimeout(seconds: 180) {
                    await self.llm.translate(contentId: t.id, title: t.title, body: t.body)
                } ?? false
                if ok { translated += 1; markJob(contentId: t.id, jtype: "translate", ok: true) }
                else { markJob(contentId: t.id, jtype: "translate", ok: false, error: llm.lastError) }
                if ok { await ExportService.shared.runPending(trigger: "translate", contentId: t.id) }
            }
            // 摘要（独立管线；若打分已带摘要则跳过）
            if t.needSummary, AIPipeline.summarize.effective {
                let ok = await Self.withTimeout(seconds: 180) {
                    await self.llm.summarize(contentId: t.id, title: t.title, body: t.body)
                } ?? false
                if ok { summarized += 1; markJob(contentId: t.id, jtype: "summarize", ok: true) }
                else { markJob(contentId: t.id, jtype: "summarize", ok: false, error: llm.lastError) }
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
            // 归档钩子：任何管线完成后检查"该源开启的管线是否全跑完"，
            // 齐了就把这篇落成最终双语 md 长期保存（幂等，未齐跳过）。
            ArchiveService.shared.archiveIfComplete(contentId: t.id)
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

    // MARK: 历史回填（开管线后"处理所有历史数据并重新归档"）

    @Published var backfillRunning = false
    @Published var backfillProgress = ""

    /// 按文件夹回填历史：文件夹内所有源逐个 backfillHistory。
    func backfillHistoryForFolder(folderId: Int64) async {
        let sourceIds = db.queryRows(
            "SELECT id FROM content_source WHERE folder_id = ? AND enabled = 1",
            params: [folderId]).compactMap { Int64($0["id"] ?? "") }
        for sid in sourceIds {
            await backfillHistory(onlySourceId: sid)
        }
    }

    /// 处理某源（或全部）的历史存量：突破水位线扫该源全部内容，
    /// 按当前有效开关跑管线；完成的内容 rearchive 刷新归档文件
    ///（入库即归档的纯原文 → 管线处理后的双语版）。
    /// onlySourceId: 限定单源；nil = 所有源（慎用，67k 存量全跑很贵）。
    func backfillHistory(onlySourceId: Int64?) async {
        guard !backfillRunning else { return }
        backfillRunning = true
        defer {
            backfillRunning = false
            deadLetterCount = countDeadLetters()
        }
        var processed = 0, round = 0
        while round < 100 {   // 轮数保险丝：每轮 batchLimit 条
            round += 1
            let tasks = collectPendingTasks(ignoreWatermark: true, onlySourceId: onlySourceId)
            // 过滤掉死信/退避后还有活的才算有进展
            guard !tasks.isEmpty else { break }
            var anyDone = false
            for t in tasks.prefix(batchLimit) {
                var didSomething = false
                if t.needScore, AIPipeline.score.effective {
                    let ok = await Self.withTimeout(seconds: 180) {
                        await self.llm.score(contentId: t.id, title: t.title, body: t.body)
                    } ?? false
                    markJob(contentId: t.id, jtype: "score", ok: ok)
                    if ok { didSomething = true }
                }
                if t.needTranslate, AIPipeline.translate.effective {
                    let ok = await Self.withTimeout(seconds: 180) {
                        await self.llm.translate(contentId: t.id, title: t.title, body: t.body)
                    } ?? false
                    markJob(contentId: t.id, jtype: "translate", ok: ok)
                    if ok { didSomething = true }
                }
                if t.needSummary, AIPipeline.summarize.effective {
                    let ok = await Self.withTimeout(seconds: 180) {
                        await self.llm.summarize(contentId: t.id, title: t.title, body: t.body)
                    } ?? false
                    markJob(contentId: t.id, jtype: "summarize", ok: ok)
                    if ok { didSomething = true }
                }
                if t.needTranscribe, AIPipeline.transcribe.effective,
                   DependencyChecker.shared.transcribeReady {
                    let ok = await Self.withTimeout(seconds: 600) {
                        await self.transcriber.transcribe(
                            contentId: t.id, title: t.title, audioUrl: t.audioUrl,
                            pageUrl: t.url, language: t.language)
                    } ?? false
                    if ok { didSomething = true }
                }
                if didSomething {
                    // 管线有新产出 → 刷新归档文件（纯原文 → 双语版）
                    ArchiveService.shared.rearchive(contentId: t.id)
                    processed += 1
                    anyDone = true
                }
                backfillProgress = "已处理 \(processed) 条（第 \(round) 轮）…"
            }
            if !anyDone { break }   // 本轮全死信/退避/失败，不空转
        }
        backfillProgress = "✅ 历史回填完成：处理 \(processed) 条"
        NotificationCenter.default.post(name: .contentUpdated, object: nil)
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
    /// - Parameters:
    ///   - ignoreWatermark: true 时扫全部历史（开管线后"处理所有历史数据"回填用）；
    ///     false 只扫水位线之后的新内容（常规轮询，存量不动）
    ///   - onlySourceId: 限定单源回填（nil = 全部）
    private func collectPendingTasks(ignoreWatermark: Bool = false,
                                     onlySourceId: Int64? = nil) -> [PendingTask] {
        // 1. 源 stype/enabled/config/folder config 快照：source 名 → (stype, enabled, 有效开关)
        let srcPolicies = fetchEffectivePolicies()
        // 2. 遍历内容，只取"有全文或有音频"且该源启用、有任一管线待跑的
        guard db.open() else { return [] }
        var stmt: OpaquePointer?
        var out: [PendingTask] = []
        // 媒体项(podcast/video)不看 fetch_status——音频在 enclosure 里, 无正文可抓, fetch_status 恒为 0;
        // 文章类要求 fetch_status IN (2成功, 4直入) 才有正文可打分/翻译。
        // 只扫水位线之后的新内容(id > watermark), 存量不动（除非 ignoreWatermark 回填）。
        var conds = ["((ctype IN ('podcast','video') OR meta LIKE '%audio_url%') OR fetch_status IN (2, 4))"]
        if !ignoreWatermark { conds.append("id > \(watermark)") }
        if let sid = onlySourceId { conds.append("source_id = \(sid)") }
        let sql = """
        SELECT id, source, source_id, ctype, title, url, language, content_md, excerpt,
               llm_score, llm_summary, llm_translated_md, meta, content_html
        FROM content
        WHERE \(conds.joined(separator: " AND "))
        ORDER BY published_at DESC
        LIMIT 2000;
        """
        guard db.prepare(sql, &stmt) else { return [] }

        // 先收全行，再一次性算死信/退避——原实现在行循环里每行 4 次 SQL（2000 行最坏 8000 次/轮）
        struct Row {
            let id: Int64, sourceId: Int64?
            let title: String, url: String, language: String?, md: String?, excerpt: String?
            let html: String?   // content_html：feed 自带全文（md 还没转出来时的正文兜底）
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
                html: colText(stmt, 13),
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
            // body 三级兜底：content_md（全文）→ content_html 剥标签（feed 自带全文，
            // md 还没转出来——你 1119 篇翻译源文章就是这样，正文在 content_html 但 md/excerpt
            // 都空，worker 此前只认 md/excerpt 拿不到正文跳过翻译）→ excerpt（摘要）
            let body = Self.resolveBody(md: r.md, html: r.html, excerpt: r.excerpt)
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
    private struct SrcPolicy: Sendable {
        let enabled: Bool
        let policy: PipelinePolicy
        let fetchMode: FetchMode
    }

    /// 切换全文抓取模式后，强制按当前模式重抓该源所有历史文章的全文。
    /// 与 backfillFullText（只补抓取失败的）不同——这是用户主动切模式，
    /// 连已抓过的也要按新模式重抓（比如从 summary 切到 defuddle 要补全文）。
    /// 异步逐篇抓，返回成功条数。summary 模式不需要抓全文，直接返回 0。
    /// nonisolated：查库 + spawn 进程 + 写库都不需 MainActor（db 有 writeQueue 保护），
    /// 在后台跑不冻结 UI（WeChat 文件夹 MainActor 跑崩过）。
    @discardableResult
    nonisolated func refetchFullTextForSource(onlySourceId: Int64) async -> Int {
        let policies = await fetchPoliciesSnapshot()
        guard let pol = policies[onlySourceId], pol.enabled else { return 0 }
        // summary 模式本来就没全文，不需要抓
        if pol.fetchMode == .summary { return 0 }
        guard db.open() else { return 0 }
        var stmt: OpaquePointer?
        // 该源历史文章，不论 fetch_status——切模式后按新模式重抓。
        // 关键安全限制：单源最多 50 篇/次（WeChat 文件夹 145 源 × 大 history，
        // 不限量串行 spawn node 进程会资源耗尽崩溃/卡死——实测崩过）。
        // 大 history 分批：worker 下轮继续，不一次跑完。
        let sql = """
        SELECT id, url, content_html FROM content
        WHERE source_id = ? AND ctype = 'article' AND is_duplicate = 0
        ORDER BY id DESC LIMIT 50;
        """
        guard db.prepare(sql, &stmt) else { return 0 }
        sqlite3_bind_int64(stmt, 1, onlySourceId)
        var rows: [(Int64, String, String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((sqlite3_column_int64(stmt, 0), colText(stmt, 1) ?? "", colText(stmt, 2)))
        }
        sqlite3_finalize(stmt)

        var ok = 0
        for (id, url, html) in rows {
            // 中途检查取消——用户可能在跑的过程中关 App 或切换，及时停
            if Task.isCancelled { break }
            let success = await FullTextFetcher.shared.fetchAndStore(
                contentId: id, url: url, feedHtml: html, mode: pol.fetchMode)
            if success { ok += 1 }
            // 节流：每篇之间小睡，避免连续 spawn node 进程打满系统
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
        }
        return ok
    }

    /// 切换全文抓取模式后，强制按当前模式重抓文件夹内所有源的历史文章全文。
    /// 逐源串行 + 每源限量 + 节流（WeChat 这种 145 源大文件夹一次跑会崩溃）。
    nonisolated func refetchFullTextForFolder(folderId: Int64) async -> Int {
        let db = Database.shared
        let ids = db.queryRows("SELECT id FROM content_source WHERE folder_id = ? AND enabled = 1",
                               params: [folderId]).compactMap { Int64($0["id"] ?? "") }
        var total = 0
        for sid in ids {
            if Task.isCancelled { break }
            total += await refetchFullTextForSource(onlySourceId: sid)
        }
        return total
    }

    /// 在 MainActor 上取 policies 快照（fetchEffectivePolicies 是 MainActor 方法，
    /// nonisolated 的 refetch 通过它安全拿到配置）
    private func fetchPoliciesSnapshot() -> [Int64: SrcPolicy] {
        fetchEffectivePolicies()
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

    /// body 三级兜底：content_md → content_html 剥标签 → excerpt。
    /// feed 自带全文（content_html）但 md 还没转出来的文章，正文在 html 里，
    /// 剥标签压空白后作为正文给打分/翻译/摘要管线。
    /// nonisolated：纯函数无 MainActor 状态，供非隔离上下文（测试/worker 后台）直接调。
    nonisolated static func resolveBody(md: String?, html: String?, excerpt: String?) -> String {
        if let md, !md.isEmpty { return md }
        if let html, !html.isEmpty {
            var text = html.replacingOccurrences(of: "<[^>]+>", with: " ",
                                                 options: .regularExpression)
            text = text.replacingOccurrences(of: "\\s+", with: " ",
                                             options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return excerpt ?? ""
    }

    private func markJob(contentId: Int64, jtype: String, ok: Bool, error: String? = nil) {
        db.execute(
            "INSERT INTO content_job (content_id, jtype, status, finished_at, error) VALUES (?,?,?,datetime('now'),?)",
            // 失败时记具体错误（LLM 鉴权/限流/超时/解析），不再只记"failed"——可区分
            // "key 失效该停"和"超时该重试"（修 P1-8）
            params: [contentId, jtype, ok ? 2 : 3, ok ? nil : (error ?? "failed")])
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
            // 连续失败次数（遇到成功即清零）——比"累计失败"更合理：
            // 历史上零星失败叠加不该判死信；真死信是"一直在失败"。
            var consecFail: [String: Int] = [:]
            for r in rows {
                guard let cidStr = r["content_id"], let cid = Int64(cidStr),
                      let jt = r["jtype"], let st = r["status"] else { continue }
                let key = "\(cid)|\(jt)"
                if lastStatus[key] == nil {
                    lastStatus[key] = (st, r["finished_at"])
                }
                // 只统计"最近一次之后"的连续失败——碰到成功就停（该 key 已有 consecFail 即已遇到更早的失败）
                if consecFail[key] == nil {
                    if st == "3" { consecFail[key] = 1 }
                } else if consecFail[key]! > 0 {
                    if st == "3" { consecFail[key]! += 1 }
                    else { consecFail[key] = -(consecFail[key]!) }  // 遇到成功：封存（负号标记不再累加）
                }
            }
            for (key, last) in lastStatus {
                let parts = key.split(separator: "|", maxSplits: 1)
                guard let cid = Int64(parts[0]) else { continue }
                let jt = String(parts[1])
                var skip = false
                let consec = abs(consecFail[key] ?? 0)
                if consec >= 3 {
                    skip = true   // 死信（连续 3 次失败）
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

    /// 死信任务数（连续失败 >=3，与 failureSkipMap 口径一致）。
    /// 用窗口函数算每组最近一次状态后的连续失败数，纯 SQL 一趟完成。
    func countDeadLetters() -> Int {
        deadLetterPairs().count
    }

    /// 死信任务明细（设置页列表）：连续失败 >= 3
    func deadLetters() -> [(contentId: Int64, jtype: String, fails: Int)] {
        deadLetterPairs()
    }

    /// 死信对（content_id, jtype, 连续失败次数）。窗口函数：
    /// 按 (content_id,jtype) 分组、id 倒序编号，rn 递增即时间倒序；
    /// 连续失败 = 从头开始 status=3 直到遇到第一个非 3。
    private func deadLetterPairs() -> [(contentId: Int64, jtype: String, fails: Int)] {
        // SQLite 窗口函数需要 3.25+，macOS 系统库满足。
        // 思路：每组按 id DESC 编号，取"前缀里全是 3"的最大前缀长度作为连续失败数。
        db.queryRows("""
            WITH ranked AS (
              SELECT content_id, jtype, status,
                     ROW_NUMBER() OVER (PARTITION BY content_id, jtype ORDER BY id DESC) AS rn
              FROM content_job
            ),
            consec AS (
              SELECT content_id, jtype, COUNT(*) AS fails
              FROM ranked
              WHERE rn <= (
                SELECT COALESCE(MIN(rn) - 1, 999999) FROM ranked r2
                WHERE r2.content_id = ranked.content_id AND r2.jtype = ranked.jtype
                  AND r2.status != 3
              ) AND status = 3
              GROUP BY content_id, jtype
            )
            SELECT content_id, jtype, fails FROM consec WHERE fails >= 3
            ORDER BY fails DESC LIMIT 200;
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

    /// 全部重试：重置全部死信标记 + 立即触发 worker 跑一轮
    /// （「全部重置」只删失败标记等下轮调度，这个立即重跑不等）
    func retryAllDeadLetters() {
        resetAllDeadLetters()
        Task { await runOnce() }
    }

    private nonisolated func colText(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
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
