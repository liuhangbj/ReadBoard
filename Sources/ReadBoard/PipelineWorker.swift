import Foundation
import SQLite3

// MARK: - 后台内容处理引擎
// 周期查询条目级 auto 标记，对缺少结果的内容补跑 AI 评分/翻译/摘要/转录。
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

    enum EnginePhase: Equatable {
        case idle, scanning, working
    }

    struct PendingBreakdown: Equatable, Sendable {
        var score = 0
        var translate = 0
        var summarize = 0
        var transcribe = 0
        var items = 0
        var unread = 0
    }

    /// 当前真正占用 LLM / Whisper 通道的任务。不能只保存一个标题：LLM 默认可并发 2 篇。
    struct ActiveTask: Identifiable, Equatable, Sendable {
        let id: Int64
        let title: String
        let stage: String
    }

    @Published private(set) var phase: EnginePhase = .idle
    var isRunning: Bool { phase != .idle }
    @Published var lastSummary = ""
    @Published private(set) var currentItems: [ActiveTask] = []
    /// 兼容只需要一个标题的旧调用；新看板直接展示 currentItems。
    var currentItem: String? { currentItems.first?.title }
    @Published var pendingCount = 0              // DB 实时待处理数
    @Published private(set) var pendingBreakdown = PendingBreakdown()
    @Published private(set) var pendingContentIds: Set<Int64> = []
    @Published var processedCount = 0            // DB 实时已处理数
    @Published var deadLetterCount = 0

    nonisolated private let db = Database.shared
    private static let workScheduler = PipelineWorkScheduler()

    /// 手动任务只复用资源并发通道，不经过 Worker 的候选扫描、自动开关、
    /// 水位线或结果缺失判定。用户点了哪个工序，就直接执行哪个工序。
    nonisolated static func scheduleManualLLM<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await workScheduler.run(in: .llm, operation: operation)
    }

    nonisolated static func scheduleManualTranscription<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await workScheduler.run(in: .transcription, operation: operation)
    }
    /// 真正驱动轮询的任务。必须保存句柄，stop() 才能取消它，并阻止重复启动。
    private var workerTask: Task<Void, Never>?
    /// 全文失败补抓属于抓取模块，独立执行，不能挡在 AI 任务前面。
    private var fullTextRecoveryTask: Task<Void, Never>?
    /// 精确计数在后台计算；连续刷新只保留最后一项，避免大队列时主线程遍历数千条。
    private var countRefreshTask: Task<Void, Never>?

    /// 扫描间隔（秒）
    var interval: TimeInterval = 120
    /// 每轮最多处理条数。资源通道默认 LLM=2、Whisper=1；保持小批次可减少
    /// 排队 Task 和取消延迟。成功批次会立即进入下一轮，不会额外等待 120 秒。
    var batchLimit = 10

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
    private let flagsMaterializedKey = "pipelineWorker.itemFlagsMaterializedV26"

    /// 存量水位线：小于等于此 id 的内容不处理
    private(set) var watermark: Int64 = 0
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
            fputs("[watermark] 检测到重装/换机（DB 有 \(maxId) 条但无水位线），历史不自动处理，需要请手动回填\n", stderr)
        }
    }

    private init() {
        initWatermark()
    }

    /// v25 之前的条目可能仍是 NULL。只固化“水位线之后且源当时仍开启”的1，
    /// 其余 NULL 在普通扫描中等同0；历史扫描仍可显式回退源设置。
    private func materializeLegacyAutoFlags() {
        guard !UserDefaults.standard.bool(forKey: flagsMaterializedKey) else { return }
        let policies = fetchEffectivePolicies()
        let definitions: [(column: String, enabled: (PipelinePolicy) -> Bool)] = [
            ("auto_score", { $0.autoScore }),
            ("auto_translate", { $0.autoTranslate }),
            ("auto_summarize", { $0.autoSummarize }),
            ("auto_transcribe", { $0.autoTranscribe })
        ]
        let ok = db.transaction {
            for definition in definitions {
                let sourceIds = policies.compactMap { id, value in
                    definition.enabled(value.policy) ? String(id) : nil
                }
                guard !sourceIds.isEmpty else { continue }
                guard db.execute("""
                    UPDATE content SET \(definition.column)=1
                    WHERE \(definition.column) IS NULL AND id>\(watermark)
                      AND source_id IN (\(sourceIds.joined(separator: ",")))
                      AND deleted_at IS NULL AND is_duplicate=0;
                    """) else { return false }
            }
            return true
        }
        if ok { UserDefaults.standard.set(true, forKey: flagsMaterializedKey) }
    }

    // MARK: Worker 生命周期

    func start() {
        guard workerTask == nil else { return }
        // 先在后台生成精确待处理快照，左栏“待处理”和四项计数无需等首轮 Worker。
        refreshCounts()
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
                    do {
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    } catch {
                        break
                    }
                }
            }
        }
    }

    func stop() {
        workerTask?.cancel()
        workerTask = nil
        fullTextRecoveryTask?.cancel()
        fullTextRecoveryTask = nil
        countRefreshTask?.cancel()
        countRefreshTask = nil
        phase = .idle
        currentItems.removeAll()
    }

    // MARK: 单轮执行

    /// 扫描一轮：找出所有需要处理的内容并执行。返回本轮处理条数。
    @discardableResult
    func runOnce() async -> Int {
        guard !Task.isCancelled else { return 0 }
        guard !isRunning else { return 0 }
        phase = .scanning
        // 先让 SwiftUI 提交“扫描中”，再进入同步数据库查询。
        await Task.yield()
        materializeLegacyAutoFlags()
        defer {
            currentItems.removeAll()
            refreshCounts()
            phase = .idle
        }

        let taskLimit = batchLimit
        let tasks = await Task.detached(priority: .utility) { [self] in
            collectPendingTasks(maxTasks: taskLimit)
        }.value
        fputs("[worker] runOnce: \(tasks.count) pending tasks\n", stderr)
        scheduleFullTextRecovery()
        guard !Task.isCancelled else { return 0 }
        guard !tasks.isEmpty else { return 0 }

        // 转录依赖一次性检查：缺依赖则本轮所有转录任务跳过（不逐条死信浪费重试），
        // 并在 summary 里提示。用户装好依赖后下轮自动恢复。
        let transcribeReady = DependencyChecker.shared.transcribeReady
        let anyTranscribePending = tasks.contains { $0.needTranscribe }
        if anyTranscribePending && !transcribeReady {
            lastSummary = "⚠️ 转录依赖缺失（whisper/ffmpeg/模型），已跳过 \(tasks.filter { $0.needTranscribe }.count) 条转录任务。请去 设置→依赖 安装。"
        }

        phase = .working
        let result = await processBatch(tasks, transcribeReady: transcribeReady)

        if result.processed > 0 {
            lastSummary = "本轮 \(result.processed) 条：评分\(result.scored) 翻译\(result.translated) 摘要\(result.summarized) 转录\(result.transcribed)"
            NotificationCenter.default.post(name: .contentUpdated, object: nil)
            // WAL 已配置自动 checkpoint；不要在 MainActor 同步等待维护操作。
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
                // 单篇产生有效结果后立即唤醒共享资料库与待处理视图。
                // 0.75 秒防抖，会把并发完成的通知合并，避免逐条重绘风暴。
                if result.succeededContents > 0 {
                    NotificationCenter.default.post(name: .contentUpdated, object: nil)
                }
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
        defer { unlockContent(task.id) }
        guard let initial = revalidatedPendingTask(
            contentId: task.id, allowLegacyFallback: task.allowLegacyFallback) else {
            return BatchResult()
        }
        var result = BatchResult()
        var attempted = false

        // 一篇内容的评分/翻译/摘要共用一个 LLM 通道名额，内部仍按顺序执行。
        if initial.needScore || initial.needTranslate || initial.needSummary {
            do {
                let llmResult = try await Self.workScheduler.run(in: .llm) { [weak self] in
                    guard let self, !Task.isCancelled else { return BatchResult() }
                    // 排队快照可能已过期：真正拿到名额时重读条目、结果、软删除和 auto 标记。
                    guard let live = await self.revalidatedPendingTask(
                        contentId: task.id, allowLegacyFallback: task.allowLegacyFallback),
                          live.needScore || live.needTranslate || live.needSummary else {
                        return BatchResult()
                    }
                    await self.beginActiveTask(live, stage: "LLM")
                    let result = await self.runLLMStages(live, policy: live.policy)
                    await self.endActiveTask(contentId: live.id)
                    return result
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
        if initial.needTranscribe, transcribeReady, !Task.isCancelled {
            do {
                let transcribeResult = try await Self.workScheduler.run(in: .transcription) { [weak self] in
                    guard let self, !Task.isCancelled else { return BatchResult() }
                    guard let live = await self.revalidatedPendingTask(
                        contentId: task.id, allowLegacyFallback: task.allowLegacyFallback),
                          live.needTranscribe,
                          AIPipeline.transcribe.effective else { return BatchResult() }
                    await self.beginActiveTask(live, stage: "转录")
                    let result = await self.runTranscription(live)
                    await self.endActiveTask(contentId: live.id)
                    return result
                }
                result.merge(transcribeResult)
                attempted = attempted || transcribeResult.processed > 0
            } catch is CancellationError {
                // 取消不写 content_job，TranscribePipeline 内部也保持同一语义。
            } catch {
                fputs("[worker] 转录调度失败 id=\(task.id): \(error.localizedDescription)\n", stderr)
            }
        }

        result.processed = attempted ? 1 : 0
        result.succeededContents = (result.scored + result.translated + result.summarized + result.transcribed) > 0 ? 1 : 0

        // 一篇只触发一次 ready，避免评分/翻译/转录分别导出同一份内容。
        if result.succeededContents == 1, !Task.isCancelled {
            await ExportService.shared.runPending(trigger: "ready", contentId: task.id)
        }
        return result
    }

    private func beginActiveTask(_ task: PendingTask, stage: String) {
        let item = ActiveTask(id: task.id, title: task.title, stage: stage)
        if let index = currentItems.firstIndex(where: { $0.id == task.id }) {
            currentItems[index] = item
        } else {
            currentItems.append(item)
        }
    }

    private func endActiveTask(contentId: Int64) {
        refreshCounts()
        currentItems.removeAll { $0.id == contentId }
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
            let ok = await Self.withTimeout(seconds: 360) {
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
            let ok = await Self.withTimeout(seconds: 360) {
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
            let ok = await Self.withTimeout(seconds: 360) {
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
        while !Task.isCancelled {
            round += 1
            let taskLimit = batchLimit
            let tasks = await Task.detached(priority: .utility) { [self] in
                collectPendingTasks(ignoreWatermark: true,
                                    onlySourceId: onlySourceId,
                                    maxTasks: taskLimit)
            }.value
            guard !tasks.isEmpty else { break }
            let result = await processBatch(
                tasks,
                transcribeReady: DependencyChecker.shared.transcribeReady)
            processed += result.succeededContents
            backfillProgress = "已处理 \(processed) 条（第 \(round) 轮）…"
            // 本轮没有任何实际调用，说明剩余项均被锁定、依赖缺失或已在退避，避免空转。
            if result.processed == 0 { break }
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
        let policy: PipelinePolicy   // 条目级有效输出开关，translateFull 按它回写
        let allowLegacyFallback: Bool
        var needScore = false
        var needTranslate = false
        var needSummary = false
        var needTranscribe = false
    }

    private enum CandidateOrder { case newest, oldest }

    private struct PendingRow {
        let id: Int64, sourceId: Int64
        let ctype: String, title: String, url: String, language: String?
        let md: String?, html: String?, excerpt: String?
        let hasScore: Bool, hasSummary: Bool, hasTranslated: Bool, hasTranscript: Bool
        let autoScore: Int64?, autoTranslate: Int64?, autoSummarize: Int64?, autoTranscribe: Int64?
        let audioUrl: String?
        let isUnread: Bool
        var isMedia: Bool {
            ctype == "podcast" || ctype == "video" || ctype == "youtube" || audioUrl != nil
        }
    }

    /// 条目字段与结果字段共同构成持久化派生队列。普通扫描不再遍历水位线后的全部内容：
    /// - 显式 auto=1 的条目不论新旧都会进入；
    /// - NULL 仅作迁移兼容，普通扫描只允许水位线后的条目回退源设置；
    /// - 历史回填允许全部 NULL 条目回退源设置。
    nonisolated private func collectPendingTasks(ignoreWatermark: Bool = false,
                                                 onlySourceId: Int64? = nil,
                                                 afterId: Int64? = nil,
                                                 maxTasks: Int) -> [PendingTask] {
        guard db.open() else { return [] }
        let policies = fetchEffectivePolicies()
        var tasks: [PendingTask] = []
        var seen: Set<Int64> = []

        func append(order: CandidateOrder, until target: Int) {
            guard tasks.count < target else { return }
            var boundary: Int64?
            let pageSize = max(100, maxTasks * 5)
            while tasks.count < target, !Task.isCancelled {
                let rows = fetchPendingRows(
                    policies: policies, ignoreWatermark: ignoreWatermark,
                    onlySourceId: onlySourceId, onlyContentId: nil, afterId: afterId,
                    order: order, boundary: boundary, limit: pageSize, lightweight: false)
                guard !rows.isEmpty else { break }
                let skipMap = failureSkipMap(contentIds: rows.map(\.id))
                for row in rows where !seen.contains(row.id) {
                    seen.insert(row.id)
                    if let task = makePendingTask(
                        row: row, policies: policies, ignoreWatermark: ignoreWatermark,
                        skip: skipMap[row.id] ?? [:], writeBackExtractedBody: true) {
                        tasks.append(task)
                        if tasks.count >= target { break }
                    }
                }
                boundary = rows.last?.id
                if rows.count < pageSize { break }
            }
        }

        // 最新内容优先，但为最旧任务保留 20% 名额，避免持续入库时旧任务永久饥饿。
        let newestTarget = max(1, maxTasks * 4 / 5)
        append(order: .newest, until: newestTarget)
        append(order: .oldest, until: maxTasks)
        return tasks
    }

    nonisolated private func fetchPendingRows(
        policies: [Int64: SrcPolicy], ignoreWatermark: Bool,
        onlySourceId: Int64?, onlyContentId: Int64?, afterId: Int64?,
        order: CandidateOrder, boundary: Int64?, limit: Int?, lightweight: Bool
    ) -> [PendingRow] {
        func sourceIds(_ enabled: (PipelinePolicy) -> Bool) -> String {
            policies.compactMap { id, value in enabled(value.policy) ? String(id) : nil }
                .joined(separator: ",")
        }
        let media = "(c.ctype IN ('podcast','video','youtube') OR c.meta LIKE '%audio_url%' OR c.meta LIKE '%video_url%')"
        let body = "(LENGTH(TRIM(COALESCE(c.content_md,'')))>0 OR LENGTH(TRIM(COALESCE(c.content_html,'')))>0 OR LENGTH(TRIM(COALESCE(c.excerpt,'')))>0)"
        let articleOrMedia = "(\(media) OR c.fetch_status IN (2,4))"
        var branchBaseParts = ["c.deleted_at IS NULL", "c.is_duplicate=0"]
        if let sid = onlySourceId { branchBaseParts.append("c.source_id=\(sid)") }
        if let cid = onlyContentId { branchBaseParts.append("c.id=\(cid)") }
        if let afterId, afterId > 0 { branchBaseParts.append("c.id>\(afterId)") }
        if let boundary {
            branchBaseParts.append(order == .newest ? "c.id<\(boundary)" : "c.id>\(boundary)")
        }
        let base = branchBaseParts.joined(separator: " AND ")
        func branches(column: String, jtype: String, resultMissing: String, extra: String,
                      fallbackIds: String) -> [String] {
            let notIgnored = "NOT EXISTS (SELECT 1 FROM content_processing_ignore i WHERE i.content_id=c.id AND i.jtype='\(jtype)')"
            var result = ["SELECT c.id FROM content c WHERE \(base) AND c.\(column)=1 AND \(resultMissing) AND \(extra) AND \(notIgnored)"]
            if ignoreWatermark, !fallbackIds.isEmpty {
                result.append("SELECT c.id FROM content c WHERE \(base) AND c.\(column) IS NULL AND c.source_id IN (\(fallbackIds)) AND \(resultMissing) AND \(extra) AND \(notIgnored)")
            }
            return result
        }
        var candidateBranches: [String] = []
        candidateBranches += branches(
            column: "auto_score", jtype: "score", resultMissing: "c.llm_score IS NULL",
            extra: "\(articleOrMedia) AND \(body)", fallbackIds: sourceIds { $0.autoScore })
        candidateBranches += branches(
            column: "auto_translate", jtype: "translate",
            resultMissing: "LENGTH(TRIM(COALESCE(c.llm_translated_md,'')))=0",
            extra: "\(articleOrMedia) AND \(body)", fallbackIds: sourceIds { $0.autoTranslate })
        // 摘要候选分支允许媒体：媒体入库时已抓字幕稿(content_md)，与文章共用合并调用体系，
        // 失败可经 content_job 退避/死信自愈，不再依赖转录链尾那次无重试的内嵌调用。
        candidateBranches += branches(
            column: "auto_summarize", jtype: "summarize",
            resultMissing: "LENGTH(TRIM(COALESCE(c.llm_summary,'')))=0",
            extra: "\(body)",
            fallbackIds: sourceIds { $0.autoSummarize })
        candidateBranches += branches(
            column: "auto_transcribe", jtype: "transcribe",
            resultMissing: "LENGTH(TRIM(COALESCE(c.llm_transcript_md,'')))=0",
            extra: "\(media) AND (LENGTH(TRIM(c.url))>0 OR c.meta LIKE '%audio_url%' OR c.meta LIKE '%video_url%')",
            fallbackIds: sourceIds { $0.autoTranscribe })

        let whereParts = ["s.enabled=1"]
        let bodyColumns = lightweight
            ? "SUBSTR(COALESCE(NULLIF(TRIM(c.content_md),''),NULLIF(TRIM(c.content_html),''),c.excerpt,''),1,1200) AS content_md, NULL AS content_html"
            : "c.content_md, c.content_html"
        let orderSQL = order == .newest ? "DESC" : "ASC"
        let limitSQL = limit.map { "LIMIT \($0)" } ?? ""
        let sql = """
        WITH pending_ids(id) AS (
            \(candidateBranches.joined(separator: "\nUNION\n"))
        )
        SELECT c.id,c.source_id,c.ctype,c.title,c.url,c.language,
               \(bodyColumns),c.excerpt,c.llm_score,c.llm_summary,c.llm_translated_md,
               c.llm_transcript_md,c.auto_score,c.auto_translate,c.auto_summarize,
               c.auto_transcribe,c.meta,c.read_at
        FROM pending_ids p
        JOIN content c ON c.id=p.id
        JOIN content_source s ON s.id=c.source_id
        WHERE \(whereParts.joined(separator: " AND "))
        ORDER BY c.id \(orderSQL)
        \(limitSQL);
        """
        return db.queryRows(sql).compactMap { row in
            guard let id = Int64(row["id"] ?? ""), let sourceId = Int64(row["source_id"] ?? "") else {
                return nil
            }
            let meta = row["meta"] ?? "{}"
            return PendingRow(
                id: id, sourceId: sourceId, ctype: row["ctype"] ?? "article",
                title: row["title"] ?? "", url: row["url"] ?? "", language: row["language"],
                md: row["content_md"], html: row["content_html"], excerpt: row["excerpt"],
                hasScore: row["llm_score"] != nil,
                hasSummary: row["llm_summary"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                hasTranslated: row["llm_translated_md"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                hasTranscript: row["llm_transcript_md"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                autoScore: row["auto_score"].flatMap(Int64.init),
                autoTranslate: row["auto_translate"].flatMap(Int64.init),
                autoSummarize: row["auto_summarize"].flatMap(Int64.init),
                autoTranscribe: row["auto_transcribe"].flatMap(Int64.init),
                audioUrl: Self.parseAudioUrl(meta),
                isUnread: row["read_at"] == nil)
        }
    }

    nonisolated private func makePendingTask(
        row: PendingRow, policies: [Int64: SrcPolicy], ignoreWatermark: Bool,
        skip: [String: Bool], writeBackExtractedBody: Bool
    ) -> PendingTask? {
        guard let source = policies[row.sourceId], source.enabled else { return nil }
        let body = Self.resolveBody(md: row.md, html: row.html, excerpt: row.excerpt)
        if writeBackExtractedBody,
           (row.md == nil || row.md?.isEmpty == true), let html = row.html, !html.isEmpty {
            let extracted = Self.resolveBody(md: nil, html: html, excerpt: nil)
            if !extracted.isEmpty {
                db.execute("UPDATE content SET content_md=? WHERE id=?", params: [extracted, row.id])
            }
        }
        func enabled(_ itemValue: Int64?, fallback: Bool) -> Bool {
            if itemValue == 1 { return true }
            if itemValue == 0 { return false }
            return ignoreWatermark ? fallback : false
        }
        let isChineseMedia = row.isMedia && ContentLanguage.isChinese(
            declared: row.language, fallbackText: row.title + "\n" + body)
        let needsTranslate = enabled(row.autoTranslate, fallback: source.policy.autoTranslate)
            && !isChineseMedia && !row.hasTranslated && !body.isEmpty
        let needsScore = enabled(row.autoScore, fallback: source.policy.autoScore)
            && !row.hasScore && !body.isEmpty
        // 文章/播客/视频/YouTube 统一以 content_md 为正文源（入库时由 fetch_mode 收编，
        // 含播客 show notes 与视频字幕稿），因此摘要可与文章一样走合并调用：
        // 只要 body(content_md) 非空即可，不再按类型/isMedia 排除。
        let needsSummary = enabled(row.autoSummarize, fallback: source.policy.autoSummarize)
            && !row.hasSummary && !body.isEmpty
        let needsTranscribe = enabled(row.autoTranscribe, fallback: source.policy.autoTranscribe)
            && !row.hasTranscript && row.isMedia && (row.audioUrl != nil || !row.url.isEmpty)

        // 先确定调用归属，再应用退避：翻译退避时不能退化成单独评分，评分退避时
        // 也不能退化成单独摘要，否则同一正文仍会产生重复调用。
        let ownsTranslate = needsTranslate
        let ownsScore = needsScore && !ownsTranslate
        let ownsSummary = needsSummary && !ownsTranslate && !ownsScore
        let doTranslate = ownsTranslate && skip["translate"] != true
        let doScore = ownsScore && skip["score"] != true
        let doSummary = ownsSummary && skip["summarize"] != true
        let doTranscribe = needsTranscribe && skip["transcribe"] != true
        guard doTranslate || doScore || doSummary || doTranscribe else { return nil }
        let outputPolicy = PipelinePolicy(
            autoScore: needsScore, autoTranslate: needsTranslate,
            autoTranscribe: needsTranscribe, autoSummarize: needsSummary)
        return PendingTask(
            id: row.id, sourceId: row.sourceId, title: row.title, url: row.url,
            body: body, language: row.language, audioUrl: row.audioUrl, policy: outputPolicy,
            allowLegacyFallback: ignoreWatermark,
            needScore: doScore, needTranslate: doTranslate,
            needSummary: doSummary, needTranscribe: doTranscribe)
    }

    /// 获得执行名额后重新读取整条内容，字段变化会让任务自动消失或使用最新正文。
    private func revalidatedPendingTask(contentId: Int64,
                                        allowLegacyFallback: Bool = false) -> PendingTask? {
        let policies = fetchEffectivePolicies()
        guard let row = fetchPendingRows(
            policies: policies, ignoreWatermark: allowLegacyFallback, onlySourceId: nil,
            onlyContentId: contentId, afterId: nil, order: .newest,
            boundary: nil, limit: 1, lightweight: false).first else { return nil }
        let skip = failureSkipMap(contentIds: [contentId])[contentId] ?? [:]
        return makePendingTask(row: row, policies: policies, ignoreWatermark: allowLegacyFallback,
                               skip: skip, writeBackExtractedBody: true)
    }

#if DEBUG
    /// 隔离数据库回归测试入口：只暴露待处理 id，不执行任何 AI/外部进程。
    func pendingTaskIdsForTesting(ignoreWatermark: Bool,
                                  onlySourceId: Int64?,
                                  afterId: Int64 = 0) -> [Int64] {
        collectPendingTasks(ignoreWatermark: ignoreWatermark,
                            onlySourceId: onlySourceId,
                            afterId: afterId,
                            maxTasks: batchLimit).map(\.id)
    }

    func pendingTaskKindsForTesting(ignoreWatermark: Bool,
                                    onlySourceId: Int64?,
                                    afterId: Int64 = 0) -> [Int64: Set<String>] {
        let tasks = collectPendingTasks(ignoreWatermark: ignoreWatermark,
                                        onlySourceId: onlySourceId,
                                        afterId: afterId,
                                        maxTasks: batchLimit)
        return Dictionary(uniqueKeysWithValues: tasks.map { task in
            var kinds: Set<String> = []
            if task.needScore { kinds.insert("score") }
            if task.needTranslate { kinds.insert("translate") }
            if task.needSummary { kinds.insert("summarize") }
            if task.needTranscribe { kinds.insert("transcribe") }
            return (task.id, kinds)
        })
    }

    func revalidatedTaskKindsForTesting(contentId: Int64) -> Set<String> {
        guard let task = revalidatedPendingTask(contentId: contentId) else { return [] }
        var kinds: Set<String> = []
        if task.needScore { kinds.insert("score") }
        if task.needTranslate { kinds.insert("translate") }
        if task.needSummary { kinds.insert("summarize") }
        if task.needTranscribe { kinds.insert("transcribe") }
        return kinds
    }

    func refreshCountsForTesting() -> PendingBreakdown {
        applyPendingSnapshot(calculatePendingSnapshot())
        return pendingBreakdown
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
          AND deleted_at IS NULL
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

    /// 全文失败补抓独立调度：AI 引擎不等待网络抓取，且同一时间最多一个恢复任务。
    private func scheduleFullTextRecovery() {
        guard FeatureBoard.fulltext.enabled, fullTextRecoveryTask == nil else { return }
        fullTextRecoveryTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.backfillFullText()
            self.fullTextRecoveryTask = nil
        }
    }

    /// 全文回填：水位线后抓取失败/未抓的文章(fetch_status 0/3, 非媒体)，按源 fetch_mode 重试。
    /// 返回本轮成功补到全文的条数。每轮限 10 条防一轮跑太久。
    private func backfillFullText() async -> Int {
        let policies = fetchEffectivePolicies()
        guard db.open() else { return 0 }
        var stmt: OpaquePointer?
        // (id, source_id, url, content_html, source_type)
        // fetch_status IN (0,1,3)：0=未抓 3=失败 1=抓取中卡死（修 P1-9——
        // 历史 PG 数据或异常中断可能带 1，卡中间态两边都不管，一并捞出来重试）
        let sql = """
        SELECT c.id, c.source_id, c.url, c.content_html, s.stype
        FROM content c
        JOIN content_source s ON s.id=c.source_id
        WHERE c.id > \(watermark)
          AND c.is_duplicate = 0
          AND c.deleted_at IS NULL
          AND c.fetch_status IN (0, 1, 3)
          AND (c.fetch_status != 3 OR c.updated_at <= datetime('now', '-15 minutes'))
          AND c.ctype IN ('article', 'podcast', 'video')
        ORDER BY c.id DESC LIMIT 10;
        """
        guard db.prepare(sql, &stmt) else { return 0 }
        var rows: [(Int64, Int64, String, String?, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let sid = sqlite3_column_int64(stmt, 1)
            let url = colText(stmt, 2) ?? ""
            let html = colText(stmt, 3)
            let sourceType = colText(stmt, 4) ?? "rss"
            rows.append((id, sid, url, html, sourceType))
        }
        sqlite3_finalize(stmt)

        var ok = 0
        for (id, sid, url, html, sourceType) in rows {
            guard !Task.isCancelled else { break }
            guard let pol = policies[sid], pol.enabled else { continue }
            // summary 模式不需要抓(本来就没全文), 跳过避免来回置状态
            if pol.fetchMode == .summary { continue }
            let success: Bool
            if ReadBoardSourceConnectorRegistry.shared.connector(for: sourceType) != nil {
                success = await SourceStore.shared.retryExternalFulltext(contentId: id)
            } else {
                success = await FullTextFetcher.shared.fetchAndStore(
                    contentId: id, url: url, feedHtml: html, mode: pol.fetchMode)
            }
            if success { ok += 1 }
        }
        return ok
    }

    /// 从 DB 刷新待处理/已处理/死信计数，更新 @Published 属性以反映实时状态
    private struct PendingSnapshot: Sendable {
        let breakdown: PendingBreakdown
        let contentIds: Set<Int64>
        let processed: Int
        let deadLetters: Int
    }

    nonisolated private func calculatePendingSnapshot() -> PendingSnapshot {
        guard db.open() else {
            return PendingSnapshot(breakdown: PendingBreakdown(), contentIds: [],
                                   processed: 0, deadLetters: 0)
        }
        // 结果可能由手动处理补齐；刷新看板时先清掉已经达标或不再启用的旧失败。
        FailedJobService.shared.clearResolvedAutomaticFailures()
        let policies = fetchEffectivePolicies()
        let rows = fetchPendingRows(
            policies: policies, ignoreWatermark: false, onlySourceId: nil,
            onlyContentId: nil, afterId: nil, order: .newest,
            boundary: nil, limit: nil, lightweight: true)
        let skipMap = failureSkipMap(contentIds: rows.map(\.id))
        var breakdown = PendingBreakdown()
        var contentIds: Set<Int64> = []
        for row in rows {
            guard let task = makePendingTask(
                row: row, policies: policies, ignoreWatermark: false,
                skip: skipMap[row.id] ?? [:], writeBackExtractedBody: false) else { continue }
            breakdown.items += 1
            if row.isUnread { breakdown.unread += 1 }
            contentIds.insert(row.id)
            if task.needScore { breakdown.score += 1 }
            if task.needTranslate { breakdown.translate += 1 }
            if task.needSummary { breakdown.summarize += 1 }
            if task.needTranscribe { breakdown.transcribe += 1 }
        }
        return PendingSnapshot(
            breakdown: breakdown, contentIds: contentIds,
            processed: db.scalarInt("SELECT COUNT(*) FROM content WHERE llm_score IS NOT NULL") ?? 0,
            deadLetters: countDeadLetters())
    }

    private func refreshCounts() {
        countRefreshTask?.cancel()
        countRefreshTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let snapshot = self.calculatePendingSnapshot()
            guard !Task.isCancelled else { return }
            await MainActor.run { self.applyPendingSnapshot(snapshot) }
        }
    }

    /// 源删除/策略批量变化后，立即在后台重算左栏待处理集合。
    func requestPendingRefresh() {
        refreshCounts()
    }

    private func applyPendingSnapshot(_ snapshot: PendingSnapshot) {
        pendingBreakdown = snapshot.breakdown
        pendingCount = snapshot.breakdown.items
        pendingContentIds = snapshot.contentIds
        processedCount = snapshot.processed
        deadLetterCount = snapshot.deadLetters
        NotificationCenter.default.post(name: .pipelinePendingUpdated, object: nil)
    }

    nonisolated private func fetchEffectivePolicies() -> [Int64: SrcPolicy] {
        guard db.open() else { return [:] }
        var stmt: OpaquePointer?
        var map: [Int64: SrcPolicy] = [:]
        // 内容处理纯按源处理——folder 不再存覆盖值，无需 JOIN folder
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

    // MARK: 辅助

    nonisolated private static func parseAudioUrl(_ metaStr: String) -> String? {
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
    nonisolated private func failureSkipMap(contentIds: [Int64]) -> [Int64: [String: Bool]] {
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
    nonisolated private static func utcDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }

    // MARK: 死信管理（设置页可查看/重置）

    /// 死信任务数（连续失败 >=3，与 failureSkipMap 口径一致）。
    /// 用窗口函数算每组最近一次状态后的连续失败数，纯 SQL 一趟完成。
    nonisolated func countDeadLetters() -> Int {
        deadLetterPairs().count
    }

    /// 死信任务明细（设置页列表）：连续失败 >= 3
    func deadLetters() -> [(contentId: Int64, jtype: String, fails: Int)] {
        deadLetterPairs()
    }

    /// 死信对（content_id, jtype, 连续失败次数）。窗口函数：
    /// 按 (content_id,jtype) 分组、id 倒序编号，rn 递增即时间倒序；
    /// 连续失败 = 从头开始 status=3 直到遇到第一个非 3。
    nonisolated private func deadLetterPairs() -> [(contentId: Int64, jtype: String, fails: Int)] {
        // SQLite 窗口函数需要 3.25+，macOS 系统库满足。
        // 思路：每组按 id DESC 编号，取"前缀里全是 3"的最大前缀长度作为连续失败数。
        db.queryRows("""
            WITH ranked AS (
              SELECT content_id, jtype, status,
                     ROW_NUMBER() OVER (PARTITION BY content_id, jtype ORDER BY id DESC) AS rn
              FROM content_job
              WHERE NOT EXISTS (
                SELECT 1 FROM content_processing_ignore i
                WHERE i.content_id=content_job.content_id AND i.jtype=content_job.jtype
              )
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

extension Notification.Name {
    static let pipelinePendingUpdated = Notification.Name("pipelinePendingUpdated")
}
