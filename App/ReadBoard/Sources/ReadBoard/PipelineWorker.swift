import Foundation
import SQLite3

// MARK: - 后台管线 worker
// 周期扫描内容, 按源的"有效开关"(源 OR 文件夹)对未处理内容补跑 AI 评分/翻译/摘要/转录。
// 内容级并发，但按资源分通道：LLM 默认最多 2 篇，Whisper 全局串行。
// App 内常驻 Task 驱动, 自包含, 无 launchd/CLI。

/// Worker 内部共用的资源通道。常规扫描和历史回填必须共用同一实例，
/// 否则两边同时跑时会各自认为没有超限。
actor PipelineWorkScheduler {
    enum Lane: Sendable { case llm, transcription }

    private let fixedLLMLimit: Int?
    private var activeLLM = 0
    private var activeTranscriptions = 0

    init(llmLimit: Int? = nil) {
        fixedLLMLimit = llmLimit.map { min(max($0, 1), 4) }
    }

    static var configuredLLMConcurrency: Int {
        let value = UserDefaults.standard.integer(forKey: "pipelineWorker.llmConcurrency")
        return value == 0 ? 2 : min(max(value, 1), 4)
    }

    private var llmLimit: Int { fixedLLMLimit ?? Self.configuredLLMConcurrency }

    /// 排队等待采用可取消的短休眠。用户停止 worker 时，尚未开始的任务
    /// 会立即退出，不会被当成内容失败。
    private func acquire(_ lane: Lane) async throws {
        while true {
            try Task.checkCancellation()
            switch lane {
            case .llm where activeLLM < llmLimit:
                activeLLM += 1
                return
            case .transcription where activeTranscriptions < 1:
                activeTranscriptions += 1
                return
            default:
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    private func release(_ lane: Lane) {
        switch lane {
        case .llm: activeLLM = max(0, activeLLM - 1)
        case .transcription: activeTranscriptions = max(0, activeTranscriptions - 1)
        }
    }

    func run<T: Sendable>(
        in lane: Lane,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(lane)
        do {
            let result = try await operation()
            release(lane)
            return result
        } catch {
            release(lane)
            throw error
        }
    }
}

@MainActor
public final class PipelineWorker: ObservableObject {
    static let shared = PipelineWorker()

    @Published var isRunning = false
    @Published var lastSummary = ""
    @Published var currentItem: String? = nil   // 当前正在处理的条目标题
    @Published var pendingCount = 0              // DB 实时待处理数
    @Published var processedCount = 0            // DB 实时已处理数
    @Published var deadLetterCount = 0

    private let db = Database.shared
    private static let workScheduler = PipelineWorkScheduler()
    /// 真正驱动轮询的任务。必须保存句柄，stop() 才能取消它，并阻止重复启动。
    private var workerTask: Task<Void, Never>?

    /// 扫描间隔（秒）
    var interval: TimeInterval = 120
    /// 每轮最多处理条数（防一次跑太久）
    var batchLimit = 100

    /// contentId 级互斥锁（修 P1-10）：正在处理的内容 id 集合。
    /// 手动触发（阅读区按钮）和 worker 都先 tryLock——防止手动+worker 对同一篇
    /// 双重调用 LLM（双倍计费）。不同内容的并发度由资源通道单独管理。
    private var processingIds: Set<Int64> = []
    private let processingLock = NSLock()
    /// 尝试占用某内容的处理权（已占用返回 false）
    func tryLockContent(_ id: Int64) -> Bool {
        processingLock.lock(); defer { processingLock.unlock() }
        if processingIds.contains(id) { return false }
        processingIds.insert(id)
        return true
    }
    /// 释放某内容的处理权
    func unlockContent(_ id: Int64) {
        processingLock.lock(); processingIds.remove(id); processingLock.unlock()
    }

    // MARK: 存量保护
    // worker 只处理"水位线之后"的新内容, 存量一律不碰(避免全量跑历史又贵又慢)。
    // 水位线 = 首次启动时的最大内容 id, 持久化到 UserDefaults, 重启不累加旧的。

    private let watermarkKey = "pipelineWorker.watermarkId"

    /// 存量水位线：小于等于此 id 的内容不处理
    private(set) var watermark: Int64 = 0
    /// 扫描光标：上次扫描到的最大 id（避免每轮都从 0 开始扫全表）
    private var scanCursor: Int64 = 0

    /// 初始化水位线：已存则读，否则取当前最大 id 并持久化。
    /// 修 P1-7：重装/换机时 UserDefaults 没了但 DB 还在——水位线若重置为 MAX(id)，
    /// 之前所有未处理内容被一次性当新内容涌入 AI 评分区（LLM 成本爆炸）。
    /// 检测：DB 已有内容但无水位线 = 重装 → 保守把水位线设为 MAX（历史不自动跑，
    /// 用户要补跑用手动回填），避免误触发全量。
    private func initWatermark() {
        let saved = UserDefaults.standard.integer(forKey: watermarkKey)
        if saved > 0 {
            watermark = Int64(saved)
            return
        }
        let maxId = db.scalarInt("SELECT COALESCE(MAX(id),0) FROM content;") ?? 0
        watermark = Int64(maxId)
        UserDefaults.standard.set(maxId, forKey: watermarkKey)
        // 重装检测：DB 已有大量内容但无水位线，记日志提示历史需手动回填
        if maxId > 100 {
            fputs("[watermark] 检测到重装/换机（DB 有 \(maxId) 条但无水位线），历史不自动跑管线，需要请手动回填\n", stderr)
        }
    }

    private init() {
        initWatermark()
        scanCursor = watermark
    }

    // MARK: Worker 生命周期

    func start() {
        guard workerTask == nil else { return }
        // 延迟 5 秒再首次执行——避免与 app 启动阶段 List 首次渲染竞争
        workerTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            while !Task.isCancelled {
                let done = await self.runOnce()
                guard !Task.isCancelled else { break }
                await Task.yield()  // 让 SwiftUI 有机会渲染 @Published 更新
                if done == 0 {
                    // 无事可做 → 已到 DB 尾部？则等 interval 秒再看；否则继续推进光标
                    let maxId = db.scalarInt("SELECT MAX(id) FROM content") ?? 0
                    if scanCursor >= Int64(maxId) {
                        scanCursor = watermark  // 回卷从头
                        do {
                            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                        } catch {
                            break
                        }
                    }
                    // 光标未到尾：间隙，不停立刻下一轮推进
                }
            }
        }
    }

    func stop() {
        workerTask?.cancel()
        workerTask = nil
    }

    // MARK: 单轮执行

    /// 扫描一轮：找出所有需要处理的内容并执行。返回本轮处理条数。
    @discardableResult
    func runOnce() async -> Int {
        guard !Task.isCancelled else { return 0 }
        guard !isRunning else { return 0 }
        isRunning = true
        defer {
            isRunning = false
            currentItem = nil
            refreshCounts()
        }

        let scan = collectPendingTasks()
        let tasks = scan.tasks
        // 常规 worker 使用全局扫描光标；历史回填使用自己的局部光标，二者互不污染。
        if scan.lastScannedId > scanCursor {
            scanCursor = scan.lastScannedId
        } else if tasks.isEmpty {
            scanCursor += Int64(batchLimit * 5)
        }
        fputs("[worker] runOnce: \(tasks.count) pending tasks\n", stderr)
        var refetched = 0

        // 第 0 步: 全文回填——水位线后抓取失败(fetch_status=0/3)的文章按源 fetch_mode 重试,
        // 成功(fetch_status→2/4)后下一轮就能进管线。每轮限 10 条防抖。
        // fulltext 板块关则跳过回填。
        if FeatureBoard.fulltext.enabled, !Task.isCancelled {
            refetched = await backfillFullText()
        }
        guard !Task.isCancelled else { return 0 }

        // 转录依赖一次性检查：缺依赖则本轮所有转录任务跳过（不逐条死信浪费重试），
        // 并在 summary 里提示。用户装好依赖后下轮自动恢复。
        let transcribeReady = DependencyChecker.shared.transcribeReady
        let anyTranscribePending = tasks.contains { $0.needTranscribe }
        if anyTranscribePending && !transcribeReady {
            lastSummary = "⚠️ 转录依赖缺失（whisper/ffmpeg/模型），已跳过 \(tasks.filter { $0.needTranscribe }.count) 条转录任务。请去 设置→依赖 安装。"
        }

        let result = await processBatch(Array(tasks.prefix(batchLimit)),
                                        transcribeReady: transcribeReady)

        if result.processed > 0 {
            lastSummary = "本轮 \(result.processed) 条：评分\(result.scored) 翻译\(result.translated) 摘要\(result.summarized) 转录\(result.transcribed) 全文补\(refetched)"
            NotificationCenter.default.post(name: .contentUpdated, object: nil)
            db.execute("PRAGMA wal_checkpoint(PASSIVE);")
        }
        return result.processed
    }

    /// 一篇内容的局部结果。子任务只返回值，不共享可变计数器；
    /// 所有统计都在 task group 汇总阶段合并，避免数据竞争。
    private struct BatchResult: Sendable {
        var processed = 0
        var succeededContents = 0
        var scored = 0
        var translated = 0
        var summarized = 0
        var transcribed = 0

        mutating func merge(_ other: BatchResult) {
            processed += other.processed
            succeededContents += other.succeededContents
            scored += other.scored
            translated += other.translated
            summarized += other.summarized
            transcribed += other.transcribed
        }
    }

    /// 常规 worker 和历史回填共用的并发处理入口。子任务本身可并发，
    /// 真正的稀缺资源由 workScheduler 分通道限流。
    private func processBatch(_ tasks: [PendingTask], transcribeReady: Bool) async -> BatchResult {
        await withTaskGroup(of: BatchResult.self, returning: BatchResult.self) { group in
            for task in tasks {
                group.addTask { [weak self] in
                    guard let self else { return BatchResult() }
                    return await self.processPendingTask(task, transcribeReady: transcribeReady)
                }
            }

            var total = BatchResult()
            for await result in group {
                total.merge(result)
                if Task.isCancelled { group.cancelAll() }
            }
            return total
        }
    }

    /// 处理单篇内容。每篇创建自己的 LLMPipeline/TranscribePipeline，
    /// 避免并发时 lastError 及转录中间状态串扰。
    private func processPendingTask(_ task: PendingTask, transcribeReady: Bool) async -> BatchResult {
        guard !Task.isCancelled else { return BatchResult() }
        // 与常规 worker、历史回填、阅读器手动处理共用 contentId 锁。
        guard tryLockContent(task.id) else { return BatchResult() }
        currentItem = task.title

        var result = BatchResult()
        var attempted = false

        // 一篇内容的评分/翻译/摘要共用一个 LLM 通道名额，内部仍按顺序执行。
        if task.needScore || task.needTranslate || task.needSummary {
            do {
                let llmResult = try await Self.workScheduler.run(in: .llm) { [weak self] in
                    guard let self, !Task.isCancelled else { return BatchResult() }
                    // 排队快照可能已过期：真正拿到执行名额时再读一次源和全局开关。
                    guard let live = await self.fetchCurrentPolicy(sourceId: task.sourceId) else {
                        return BatchResult()
                    }
                    return await self.runLLMStages(task, policy: live.policy)
                }
                result.merge(llmResult)
                attempted = attempted || llmResult.processed > 0
            } catch is CancellationError {
                // worker 停止是生命周期事件，不记失败。
            } catch {
                fputs("[worker] LLM 调度失败 id=\(task.id): \(error.localizedDescription)\n", stderr)
            }
        }

        // Whisper 独立通道全局只允许 1 篇，不占用 LLM 名额。
        if task.needTranscribe, transcribeReady, !Task.isCancelled {
            do {
                let transcribeResult = try await Self.workScheduler.run(in: .transcription) { [weak self] in
                    guard let self, !Task.isCancelled else { return BatchResult() }
                    guard let live = await self.fetchCurrentPolicy(sourceId: task.sourceId),
                          live.policy.autoTranscribe,
                          AIPipeline.transcribe.effective else { return BatchResult() }
                    return await self.runTranscription(task)
                }
                result.merge(transcribeResult)
                attempted = attempted || transcribeResult.processed > 0
            } catch is CancellationError {
                // 取消不写 content_job，TranscribePipeline 内部也保持同一语义。
            } catch {
                fputs("[worker] 转录调度失败 id=\(task.id): \(error.localizedDescription)\n", stderr)
            }
        }

        unlockContent(task.id)
        result.processed = attempted ? 1 : 0
        result.succeededContents = (result.scored + result.translated + result.summarized + result.transcribed) > 0 ? 1 : 0

        // 一篇只触发一次 ready，避免评分/翻译/转录分别导出同一份内容。
        if result.succeededContents == 1, !Task.isCancelled {
            await ExportService.shared.runPending(trigger: "ready", contentId: task.id)
        }
        return result
    }

    private func runLLMStages(_ task: PendingTask, policy: PipelinePolicy) async -> BatchResult {
        guard !Task.isCancelled else { return BatchResult() }
        let runScore = task.needScore && policy.autoScore && AIPipeline.score.effective
        let runTranslate = task.needTranslate && policy.autoTranslate && AIPipeline.translate.effective
        let runSummary = task.needSummary && policy.autoSummarize && AIPipeline.summarize.effective
        guard runScore || runTranslate || runSummary else { return BatchResult() }

        let llm = LLMPipeline()
        var result = BatchResult(processed: 1)

        if runScore {
            let ok = await Self.withTimeout(seconds: 180) {
                await llm.score(contentId: task.id, title: task.title, body: task.body)
            } ?? false
            if ok {
                markJob(contentId: task.id, jtype: "score", ok: true)
                result.scored = 1
            } else if !Task.isCancelled {
                markJob(contentId: task.id, jtype: "score", ok: false, error: llm.lastError)
            }
            guard !Task.isCancelled else { return result }
        }
        if runTranslate, !Task.isCancelled {
            let ok = await Self.withTimeout(seconds: 180) {
                await llm.translateFull(
                    contentId: task.id, title: task.title, body: task.body, policy: policy)
            } ?? false
            if ok {
                markJob(contentId: task.id, jtype: "translate", ok: true)
                result.translated = 1
            } else if !Task.isCancelled {
                markJob(contentId: task.id, jtype: "translate", ok: false, error: llm.lastError)
            }
            guard !Task.isCancelled else { return result }
        }
        if runSummary, !Task.isCancelled {
            let ok = await Self.withTimeout(seconds: 180) {
                await llm.summarize(contentId: task.id, title: task.title, body: task.body)
            } ?? false
            if ok {
                markJob(contentId: task.id, jtype: "summarize", ok: true)
                result.summarized = 1
            } else if !Task.isCancelled {
                markJob(contentId: task.id, jtype: "summarize", ok: false, error: llm.lastError)
            }
            guard !Task.isCancelled else { return result }
        }
        return result
    }

    private func runTranscription(_ task: PendingTask) async -> BatchResult {
        guard !Task.isCancelled else { return BatchResult() }
        let transcriber = TranscribePipeline()
        let ok = await Self.withTimeout(seconds: 600) {
            await transcriber.transcribe(
                contentId: task.id, title: task.title, audioUrl: task.audioUrl,
                pageUrl: task.url, language: task.language)
        } ?? false
        if ok { return BatchResult(processed: 1, transcribed: 1) }
        guard !Task.isCancelled else { return BatchResult() }
        return BatchResult(processed: 1)
    }

    // MARK: 历史回填（开启管线后处理历史内容）

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
    /// 按当前有效开关跑管线。
    /// onlySourceId: 限定单源；nil = 所有源（慎用，67k 存量全跑很贵）。
    func backfillHistory(onlySourceId: Int64?) async {
        guard !backfillRunning else { return }
        backfillRunning = true
        defer {
            backfillRunning = false
            deadLetterCount = countDeadLetters()
        }
        var processed = 0, round = 0
        var historyCursor: Int64 = 0
        while !Task.isCancelled {
            round += 1
            let scan = collectPendingTasks(ignoreWatermark: true,
                                           onlySourceId: onlySourceId,
                                           afterId: historyCursor)
            let tasks = Array(scan.tasks.prefix(batchLimit))
            // 当前窗口没有待处理项时也要推进到窗口末尾，继续检查更老/更后的历史；
            // 不能因为前 500 条已经处理完，就误判整个源回填完成。
            if tasks.isEmpty {
                guard scan.lastScannedId > historyCursor else { break }
                historyCursor = scan.lastScannedId
                if scan.reachedEnd { break }
                continue
            }
            let result = await processBatch(
                tasks,
                transcribeReady: DependencyChecker.shared.transcribeReady)
            processed += result.succeededContents
            if let lastId = tasks.last?.id { historyCursor = max(historyCursor, lastId) }
            backfillProgress = "已处理 \(processed) 条（第 \(round) 轮）…"
            // tasks 被 prefix 截断时从最后处理 id 继续；否则可直接越过扫描窗口尾部。
            if scan.tasks.count <= batchLimit {
                historyCursor = max(historyCursor, scan.lastScannedId)
                if scan.reachedEnd { break }
            }
        }
        backfillProgress = Task.isCancelled
            ? "已取消历史回填：处理 \(processed) 条"
            : "✅ 历史回填完成：处理 \(processed) 条"
        NotificationCenter.default.post(name: .contentUpdated, object: nil)
    }

    // MARK: 待处理任务收集

    private struct PendingTask: Sendable {
        let id: Int64
        let sourceId: Int64
        let title: String
        let url: String
        let body: String
        let language: String?
        let audioUrl: String?
        let policy: PipelinePolicy   // 源级/文件夹级开关快照，translateFull 用
        var needScore = false
        var needTranslate = false
        var needSummary = false
        var needTranscribe = false
    }

    private struct PendingScan {
        let tasks: [PendingTask]
        let lastScannedId: Int64
        let reachedEnd: Bool
    }

    /// 扫描内容，对每条算有效开关(源 OR 文件夹)，挑出需要处理但还没结果的
    /// - Parameters:
    ///   - ignoreWatermark: true 时扫全部历史（开管线后"处理所有历史数据"回填用）；
    ///     false 只扫水位线之后的新内容（常规轮询，存量不动）
    ///   - onlySourceId: 限定单源回填（nil = 全部）
    private func collectPendingTasks(ignoreWatermark: Bool = false,
                                     onlySourceId: Int64? = nil,
                                     afterId: Int64? = nil) -> PendingScan {
        // 1. 源 stype/enabled/config/folder config 快照：source 名 → (stype, enabled, 有效开关)
        let srcPolicies = fetchEffectivePolicies()
        // 2. 遍历内容，只取"有全文或有音频"且该源启用、有任一管线待跑的
        guard db.open() else { return PendingScan(tasks: [], lastScannedId: afterId ?? scanCursor, reachedEnd: true) }
        var stmt: OpaquePointer?
        var out: [PendingTask] = []
        // 媒体项(podcast/video)不看 fetch_status——音频在 enclosure 里, 无正文可抓, fetch_status 恒为 0;
        // 文章类要求 fetch_status IN (2成功, 4直入) 才有正文可做 AI 评分/翻译。
        // 只扫水位线之后的新内容(id > watermark), 存量不动（除非 ignoreWatermark 回填）。
        var conds = ["is_duplicate = 0",
                     "((ctype IN ('podcast','video','youtube') OR meta LIKE '%audio_url%') OR fetch_status IN (2, 4))"]
        if !ignoreWatermark { conds.append("id > \(watermark)") }
        if let sid = onlySourceId { conds.append("source_id = \(sid)") }
        // 扫描光标：从上次扫描到的最大 id 继续，避免每轮重扫全表。
        // 第 0 轮从 watermark 开始；每轮过完更新 scanCursor 到本轮看到的最大 id。
        // 下一轮 SQL 加 id > scanCursor → 已处理完的不会重扫 → 自然推进。
        // 历史回填必须从 0（或它自己的分页光标）开始；沿用 watermark 会把所有历史排除。
        let startId = ignoreWatermark ? (afterId ?? 0) : scanCursor
        conds.append("id > \(startId)")
        let sql = """
        SELECT id, source, source_id, ctype, title, url, language, content_md, excerpt,
               llm_score, llm_summary, llm_translated_md, meta, content_html, llm_transcript_md,
               auto_score, auto_translate, auto_summarize, auto_transcribe
        FROM content
        WHERE \(conds.joined(separator: " AND "))
        ORDER BY id ASC
        LIMIT \(batchLimit * 5);
        """
        guard db.prepare(sql, &stmt) else {
            return PendingScan(tasks: [], lastScannedId: startId, reachedEnd: true)
        }

        // 先收全行，再一次性算死信/退避——原实现在行循环里每行 4 次 SQL（2000 行最坏 8000 次/轮）
        struct Row {
            let id: Int64, sourceId: Int64?
            let title: String, url: String, language: String?, md: String?, excerpt: String?
            let html: String?   // content_html：feed 自带全文（md 还没转出来时的正文兜底）
           let hasScore: Bool, hasSummary: Bool, hasTranslated: Bool, hasTranscript: Bool, isMedia: Bool
            let autoScore: Int64?, autoTranslate: Int64?, autoSummarize: Int64?, autoTranscribe: Int64?
            let audioUrl: String?
        }
        var rawRows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let sourceId = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2)
            let ctype = colText(stmt, 3) ?? "article"
            let metaStr = colText(stmt, 12) ?? "{}"
            let audioUrl = Self.parseAudioUrl(metaStr)
            let isMedia = ctype == "podcast" || ctype == "video" || ctype == "youtube" || audioUrl != nil
            let summary = colText(stmt, 10)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = colText(stmt, 11)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let transcript = colText(stmt, 14)?.trimmingCharacters(in: .whitespacesAndNewlines)
            rawRows.append(Row(
                id: id, sourceId: sourceId,
                title: colText(stmt, 4) ?? "", url: colText(stmt, 5) ?? "",
                language: colText(stmt, 6), md: colText(stmt, 7), excerpt: colText(stmt, 8),
                html: colText(stmt, 13),
                hasScore: sqlite3_column_type(stmt, 9) != SQLITE_NULL,
                hasSummary: summary?.isEmpty == false,
                hasTranslated: translation?.isEmpty == false,
                hasTranscript: transcript?.isEmpty == false,
                isMedia: isMedia,
                autoScore: sqlite3_column_type(stmt, 15) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 15),
                autoTranslate: sqlite3_column_type(stmt, 16) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 16),
                autoSummarize: sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 17),
                autoTranscribe: sqlite3_column_type(stmt, 18) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 18),
                audioUrl: audioUrl))
        }
        sqlite3_finalize(stmt)

        // 一次聚合查询算全量 content 的死信+退避状态（jtype → skip）
        let skipMap = failureSkipMap(contentIds: rawRows.map { $0.id })
        fputs("[worker] rawRows=\(rawRows.count) skipMapSize=\(skipMap.count)\n", stderr)

        for r in rawRows {
            let id = r.id

            // 按具体源查开关; source_id 为 NULL(存量/异常)则无开关, 跳过
            guard let sid = r.sourceId, let pol = srcPolicies[sid], pol.enabled else { continue }
            // body 三级兜底：content_md（全文）→ content_html 剥标签（feed 自带全文，
            // md 还没转出来——你 1119 篇翻译源文章就是这样，正文在 content_html 但 md/excerpt
            // 都空，worker 此前只认 md/excerpt 拿不到正文跳过翻译）→ excerpt（摘要）
            let body = Self.resolveBody(md: r.md, html: r.html, excerpt: r.excerpt)
            // 修：content_html 有全文但 content_md 空时，剥标签写回 content_md——
            // 否则翻译用了 content_html 全文，但阅读区 content_md 还是空（显示摘要不是全文）
            if (r.md == nil || r.md!.isEmpty), let html = r.html, !html.isEmpty {
                let mdText = Self.resolveBody(md: nil, html: html, excerpt: nil)
                if !mdText.isEmpty {
                    db.execute("UPDATE content SET content_md = ? WHERE id = ?", params: [mdText, id])
                }
            }
            let audioUrl = r.audioUrl
            let isMedia = r.isMedia
            let isChineseMedia = isMedia && ContentLanguage.isChinese(
                declared: r.language, fallbackText: r.title + "\n" + body)
            let skip = skipMap[id] ?? [:]

            var t = PendingTask(id: id, sourceId: sid, title: r.title, url: r.url, body: body,
                                language: r.language, audioUrl: audioUrl, policy: pol.policy)
            // per-item 字段优先：0=跳过 1=处理 NULL=回退读源配置（存量兼容）
            // 中文播客/视频不进入翻译管线；translateFull 合并评分+摘要
            let doTranslate = (r.autoTranslate == 0 ? false : r.autoTranslate == 1 ? true : pol.policy.autoTranslate)
                && !isChineseMedia && !r.hasTranslated && !body.isEmpty && skip["translate"] != true
            let doScore = (r.autoScore == 0 ? false : r.autoScore == 1 ? true : pol.policy.autoScore)
                && !r.hasScore && !body.isEmpty && !doTranslate && skip["score"] != true
            let doSummary = (r.autoSummarize == 0 ? false : r.autoSummarize == 1 ? true : pol.policy.autoSummarize)
                && !r.hasSummary && !body.isEmpty && !isMedia && !doTranslate && skip["summarize"] != true
            let doTranscribe = (r.autoTranscribe == 0 ? false : r.autoTranscribe == 1 ? true : pol.policy.autoTranscribe)
                && !r.hasTranscript && isMedia && (audioUrl != nil || !r.url.isEmpty) && skip["transcribe"] != true

            if doTranslate { t.needTranslate = true }
            if doScore { t.needScore = true }
            if doSummary { t.needSummary = true }
            if doTranscribe { t.needTranscribe = true }

            if t.needScore || t.needTranslate || t.needSummary || t.needTranscribe {
                out.append(t)
            }
        }
        return PendingScan(tasks: out,
                           lastScannedId: rawRows.last?.id ?? startId,
                           reachedEnd: rawRows.count < batchLimit * 5)
    }

#if DEBUG
    /// 隔离数据库回归测试入口：只暴露待处理 id，不执行任何 AI/外部进程。
    func pendingTaskIdsForTesting(ignoreWatermark: Bool,
                                  onlySourceId: Int64?,
                                  afterId: Int64 = 0) -> [Int64] {
        collectPendingTasks(ignoreWatermark: ignoreWatermark,
                            onlySourceId: onlySourceId,
                            afterId: afterId).tasks.map(\.id)
    }

    func pendingTaskKindsForTesting(ignoreWatermark: Bool,
                                    onlySourceId: Int64?,
                                    afterId: Int64 = 0) -> [Int64: Set<String>] {
        let tasks = collectPendingTasks(ignoreWatermark: ignoreWatermark,
                                        onlySourceId: onlySourceId,
                                        afterId: afterId).tasks
        return Dictionary(uniqueKeysWithValues: tasks.map { task in
            var kinds: Set<String> = []
            if task.needScore { kinds.insert("score") }
            if task.needTranslate { kinds.insert("translate") }
            if task.needSummary { kinds.insert("summarize") }
            if task.needTranscribe { kinds.insert("transcribe") }
            return (task.id, kinds)
        })
    }
#endif

    /// source_id → (enabled, 有效开关=源 OR 文件夹, fetch_mode)。按具体源 id 索引, 同 stype 源互不干扰。
    private struct SrcPolicy: Sendable {
        let enabled: Bool
        let policy: PipelinePolicy
        let fetchMode: FetchMode
    }

    /// 切换全文提取模式后，强制按当前模式重提该源所有历史文章的全文。
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

    /// 切换全文提取模式后，强制按当前模式重提文件夹内所有源的历史文章全文。
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
        // fetch_status IN (0,1,3)：0=未抓 3=失败 1=抓取中卡死（修 P1-9——
        // 历史 PG 数据或异常中断可能带 1，卡中间态两边都不管，一并捞出来重试）
        let sql = """
        SELECT id, source_id, url, content_html FROM content
        WHERE id > \(watermark)
          AND is_duplicate = 0
          AND fetch_status IN (0, 1, 3)
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
            guard !Task.isCancelled else { break }
            guard let pol = policies[sid], pol.enabled else { continue }
            // summary 模式不需要抓(本来就没全文), 跳过避免来回置状态
            if pol.fetchMode == .summary { continue }
            let success = await FullTextFetcher.shared.fetchAndStore(
                contentId: id, url: url, feedHtml: html, mode: pol.fetchMode)
            if success { ok += 1 }
        }
        return ok
    }

    /// 从 DB 刷新待处理/已处理/死信计数，更新 @Published 属性以反映实时状态
    private func refreshCounts() {
        guard db.open() else { return }
        // per-item 标记三态：0=跳过 1=处理 NULL=回退读源配置
        let policies = fetchEffectivePolicies()
        var pending = 0
        let rows = db.queryRows("""
            SELECT id, source_id, ctype,
                   auto_score, auto_translate, auto_summarize, auto_transcribe,
                   llm_score, llm_translated_md, llm_summary, llm_transcript_md, meta
            FROM content
            WHERE id > \(watermark) AND is_duplicate=0 AND deleted_at IS NULL
              AND fetch_status IN (2,4) AND LENGTH(content_md)>100
            """)
        for r in rows {
            guard let sidStr = r["source_id"],
                  let sid = Int64(sidStr),
                  let pol = policies[sid] else { continue }

            func eff(_ key: String) -> Bool {
                let val = r[key].flatMap { Int64($0) }
                if val == 1 { return true }
                if val == 0 { return false }
                // NULL → fallback to source config
                switch key {
                case "auto_score": return pol.policy.autoScore
                case "auto_translate": return pol.policy.autoTranslate
                case "auto_summarize": return pol.policy.autoSummarize
                case "auto_transcribe": return pol.policy.autoTranscribe
                default: return false
                }
            }

            let needScore = eff("auto_score") && (Int64(r["llm_score"] ?? "x") == nil)
            let needTranslate = eff("auto_translate") && (r["llm_translated_md"]?.isEmpty ?? true)
            let needSummary = eff("auto_summarize") && (r["llm_summary"]?.isEmpty ?? true)
            let isMedia = (r["ctype"] == "podcast" || r["ctype"] == "video" || r["ctype"] == "youtube"
                           || (r["meta"]?.contains("audio_url") ?? false))
            let needTranscribe = eff("auto_transcribe") && (r["llm_transcript_md"]?.isEmpty ?? true) && isMedia

            if needScore || needTranslate || needSummary || needTranscribe { pending += 1 }
        }
        pendingCount = pending
        processedCount = db.scalarInt("SELECT COUNT(*) FROM content WHERE llm_score IS NOT NULL") ?? 0
        deadLetterCount = countDeadLetters()
    }

    private func fetchEffectivePolicies() -> [Int64: SrcPolicy] {
        guard db.open() else { return [:] }
        var stmt: OpaquePointer?
        var map: [Int64: SrcPolicy] = [:]
        // 管线纯按源处理——folder 不再存管线覆盖值，无需 JOIN folder
        let sql = "SELECT id, enabled, config FROM content_source;"
        guard db.prepare(sql, &stmt) else { return [:] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sid = sqlite3_column_int64(stmt, 0)
            let enabled = sqlite3_column_int64(stmt, 1) == 1
            let srcCfg = colText(stmt, 2) ?? "{}"
            // 生效策略 = 源自己的设置（文件夹仅作批量设置入口，不影响生效）
            let eff = PipelinePolicy.from(configJson: srcCfg)
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

    /// 单篇执行前重读源设置，避免长批次继续使用已失效的开关快照。
    private func fetchCurrentPolicy(sourceId: Int64) -> SrcPolicy? {
        guard let row = db.queryRows(
            "SELECT enabled, config FROM content_source WHERE id = ?;",
            params: [sourceId]).first,
              row["enabled"] == "1" else { return nil }
        let config = row["config"] ?? "{}"
        let policy = PipelinePolicy.from(configJson: config)
        var mode: FetchMode = .summary
        if let data = config.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = obj["fetch_mode"] as? String,
           let parsed = FetchMode(rawValue: raw) {
            mode = parsed
        }
        return SrcPolicy(enabled: true, policy: policy, fetchMode: mode)
    }

    // MARK: 辅助

    private static func parseAudioUrl(_ metaStr: String) -> String? {
        guard let data = metaStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["audio_url"] as? String) ?? (obj["video_url"] as? String)
    }

    /// body 三级兜底：有效 content_md → content_html 剥标签 → excerpt。
    /// feed 自带全文（content_html）但 md 还没转出来的文章，正文在 html 里，
    /// 剥标签压空白后作为正文给 AI 评分/翻译/摘要管线。
    /// nonisolated：纯函数无 MainActor 状态，供非隔离上下文（测试/worker 后台）直接调。
    nonisolated static func resolveBody(md: String?, html: String?, excerpt: String?) -> String {
        if let md, !md.isEmpty, !isEmptyExtractionPlaceholder(md) { return md }
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

    /// 抓取代理可能返回带元数据的 CAPTCHA 空壳；它不是正文，
    /// 若送给 LLM 会得到“请提供原文”之类的占位答复并被误记为成功。
    nonisolated private static func isEmptyExtractionPlaceholder(_ markdown: String) -> Bool {
        let lower = markdown.lowercased()
        guard lower.contains("requiring captcha") || lower.contains("captcha required") else {
            return false
        }
        guard let marker = lower.range(of: "markdown content:") else { return true }
        return lower[marker.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    /// R2 单任务超时包装：operation 超时未返回则取消并返回 nil（调用方据此记失败放行）。
    /// TaskGroup 离开作用域前会等待子任务退出，因此被调操作必须响应取消：
    /// LLMClient 会终止 fallback/429 退避，TranscribePipeline 会终止外部进程。
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
