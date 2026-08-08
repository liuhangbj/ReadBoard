import Foundation
import ReadBoardContract

enum ManualReprocessStep: Equatable {
    case translateFull
    case scoreWithSummary
    case summarize
    case transcribe
}

enum ManualReprocessPlanner {
    nonisolated static func steps(
        policy: PipelinePolicy,
        isMedia: Bool,
        isChineseMedia: Bool
    ) -> [ManualReprocessStep] {
        var result: [ManualReprocessStep] = []
        if policy.autoTranslate && !isChineseMedia {
            result.append(.translateFull)
        } else if policy.autoScore {
            result.append(.scoreWithSummary)
        } else if policy.autoSummarize && !(isMedia && policy.autoTranscribe) {
            result.append(.summarize)
        }
        if policy.autoTranscribe && isMedia { result.append(.transcribe) }
        return result
    }
}

private actor LocalProcessingCommandStore {
    struct Reservation {
        let snapshot: ProcessingCommandSnapshot
        let isNew: Bool
    }

    private var snapshots: [String: ProcessingCommandSnapshot] = [:]
    private var insertionOrder: [String] = []

    func reserve(_ command: ProcessingCommand) throws -> Reservation {
        if let existing = snapshots[command.requestID] {
            guard existing.contentID == command.contentID,
                  existing.operation == command.operation else {
                throw ProcessingGatewayError.invalidRequest
            }
            return Reservation(snapshot: existing, isNew: false)
        }
        let snapshot = ProcessingCommandSnapshot(
            requestID: command.requestID,
            contentID: command.contentID,
            operation: command.operation,
            state: .queued,
            message: "排队中…",
            contentChanged: false,
            updatedAt: Self.now
        )
        snapshots[command.requestID] = snapshot
        insertionOrder.append(command.requestID)
        prune()
        return Reservation(snapshot: snapshot, isNew: true)
    }

    func update(
        command: ProcessingCommand,
        state: ProcessingCommandState,
        message: String,
        contentChanged: Bool = false
    ) -> ProcessingCommandSnapshot {
        let snapshot = ProcessingCommandSnapshot(
            requestID: command.requestID,
            contentID: command.contentID,
            operation: command.operation,
            state: state,
            message: message,
            contentChanged: contentChanged,
            updatedAt: Self.now
        )
        snapshots[command.requestID] = snapshot
        return snapshot
    }

    func snapshot(requestID: String) throws -> ProcessingCommandSnapshot {
        guard let snapshot = snapshots[requestID] else {
            throw ProcessingGatewayError.commandNotFound(requestID)
        }
        return snapshot
    }

    private func prune() {
        guard insertionOrder.count > 256 else { return }
        let removable = insertionOrder.filter { snapshots[$0]?.state.isTerminal == true }
        for requestID in removable.prefix(insertionOrder.count - 192) {
            snapshots.removeValue(forKey: requestID)
            insertionOrder.removeAll { $0 == requestID }
        }
    }

    private static var now: Int64 { Int64(Date().timeIntervalSince1970) }
}

/// 处理命令的本地应用服务。SwiftUI 不再加载正文、解析源配置或直接调用 LLM/Whisper。
public final class LocalProcessingGateway: ProcessingGateway, @unchecked Sendable {
    private struct Input: Sendable {
        let contentID: Int64
        let title: String
        let url: String
        let language: String?
        let contentType: String
        let excerpt: String?
        let contentMarkdown: String?
        let contentHTML: String?
        let transcriptMarkdown: String?
        let audioURL: String?
        let policy: PipelinePolicy
        let fetchMode: FetchMode

        var body: String {
            PipelineWorker.resolveBody(
                md: contentMarkdown, html: contentHTML, excerpt: excerpt)
        }

        var isMedia: Bool {
            contentType == "podcast" || contentType == "video"
                || contentType == "youtube" || audioURL != nil
        }
    }

    private struct Outcome {
        let state: ProcessingCommandState
        let message: String
        let contentChanged: Bool
        let shouldExport: Bool
    }

    private let db: Database
    private let commands = LocalProcessingCommandStore()

    init(database: Database = .shared) {
        db = database
    }

    public func capabilities() async -> ProcessingCapabilities {
        let llmAvailable = await MainActor.run { LLMPipeline().isAvailable }
        return ProcessingCapabilities(
            llmAvailable: llmAvailable,
            transcriptionAvailable: true,
            fulltextAvailable: true
        )
    }

    public func submit(_ command: ProcessingCommand) async throws -> ProcessingCommandSnapshot {
        guard !command.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.contentID > 0 else {
            throw ProcessingGatewayError.invalidRequest
        }
        let reservation = try await commands.reserve(command)
        guard reservation.isNew else { return reservation.snapshot }

        let locked = await MainActor.run {
            PipelineWorker.shared.tryLockContent(command.contentID)
        }
        guard locked else {
            return await commands.update(
                command: command,
                state: .busy,
                message: "该篇正在处理中，请稍候"
            )
        }

        Task { [self] in await runLocked(command) }
        return reservation.snapshot
    }

    public func status(requestID: String) async throws -> ProcessingCommandSnapshot {
        try await commands.snapshot(requestID: requestID)
    }

    private func runLocked(_ command: ProcessingCommand) async {
        let outcome: Outcome
        do {
            let input = try await Task.detached(priority: .userInitiated) { [self] in
                try loadInput(contentID: command.contentID)
            }.value
            _ = await commands.update(
                command: command, state: .running,
                message: runningMessage(for: command.operation))
            outcome = await perform(command, input: input)
        } catch {
            outcome = Outcome(
                state: .failed,
                message: error.localizedDescription,
                contentChanged: false,
                shouldExport: false
            )
        }

        await MainActor.run { PipelineWorker.shared.unlockContent(command.contentID) }
        if outcome.shouldExport {
            await ExportService.shared.runPending(
                trigger: "ready", contentId: command.contentID)
        }
        _ = await commands.update(
            command: command,
            state: outcome.state,
            message: outcome.message,
            contentChanged: outcome.contentChanged
        )
    }

    private func loadInput(contentID: Int64) throws -> Input {
        guard db.open() else { throw ProcessingGatewayError.storageUnavailable }
        guard let row = db.queryRows("""
            SELECT c.title, c.url, c.language, c.ctype, c.excerpt, s.config
            FROM content c
            LEFT JOIN content_source s ON s.id = c.source_id
            WHERE c.id = ? AND c.deleted_at IS NULL;
            """, params: [contentID]).first,
              let loaded = db.fetchContentBody(id: contentID) else {
            throw ProcessingGatewayError.contentNotFound(contentID)
        }
        let config = row["config"] ?? "{}"
        return Input(
            contentID: contentID,
            title: row["title"] ?? "内容 #\(contentID)",
            url: row["url"] ?? "",
            language: row["language"],
            contentType: row["ctype"] ?? "article",
            excerpt: row["excerpt"],
            contentMarkdown: loaded.contentMd,
            contentHTML: loaded.contentHtml,
            transcriptMarkdown: loaded.llmTranscriptMd,
            audioURL: loaded.audioUrl,
            policy: PipelinePolicy.from(configJson: config),
            fetchMode: Self.fetchMode(config: config)
        )
    }

    private func perform(_ command: ProcessingCommand, input: Input) async -> Outcome {
        switch command.operation {
        case .allEnabled: return await runAllEnabled(command, input: input)
        case .fulltext: return await runFulltext(input)
        case .score: return await runScore(input)
        case .summarize: return await runSummarize(input)
        case .translate: return await runTranslate(input)
        case .transcribe: return await runTranscribe(input)
        case .deleteTranscript: return deleteTranscript(input)
        }
    }

    private func runAllEnabled(_ command: ProcessingCommand, input: Input) async -> Outcome {
        let pipeline = LLMPipeline()
        let isChineseMedia = input.isMedia && ContentLanguage.isChinese(
            declared: input.language,
            fallbackText: input.title + "\n" + input.body
        )
        let steps = ManualReprocessPlanner.steps(
            policy: input.policy,
            isMedia: input.isMedia,
            isChineseMedia: isChineseMedia
        )
        guard !steps.isEmpty else {
            return Outcome(
                state: .noWork, message: "无已开启的内容处理项",
                contentChanged: false, shouldExport: false)
        }

        var messages: [String] = []
        var changed = false
        for step in steps where !Task.isCancelled {
            let ok: Bool
            switch step {
            case .translateFull:
                ok = (try? await PipelineWorker.scheduleManualLLM {
                    await self.updateRunning(command, message: "翻译中…")
                    return await pipeline.translateFull(
                        contentId: input.contentID,
                        title: input.title,
                        body: input.body,
                        policy: input.policy)
                }) ?? false
                messages.append(ok ? "翻译✅" : "翻译❌ \(pipeline.lastError ?? "未知错误")")
            case .scoreWithSummary:
                ok = (try? await PipelineWorker.scheduleManualLLM {
                    await self.updateRunning(command, message: "评分与摘要中…")
                    return await pipeline.score(
                        contentId: input.contentID, title: input.title, body: input.body)
                }) ?? false
                messages.append(ok ? "评分✅" : "评分❌ \(pipeline.lastError ?? "未知错误")")
            case .summarize:
                ok = (try? await PipelineWorker.scheduleManualLLM {
                    await self.updateRunning(command, message: "摘要中…")
                    return await pipeline.summarize(
                        contentId: input.contentID, title: input.title, body: input.body)
                }) ?? false
                messages.append(ok ? "摘要✅" : "摘要❌ \(pipeline.lastError ?? "未知错误")")
            case .transcribe:
                let transcriber = TranscribePipeline()
                ok = (try? await PipelineWorker.scheduleManualTranscription {
                    await self.updateRunning(command, message: "转录中（下载+识别，较长）…")
                    return await transcriber.transcribe(
                        contentId: input.contentID,
                        title: input.title,
                        audioUrl: input.audioURL,
                        pageUrl: input.url,
                        language: input.language)
                }) ?? false
                messages.append(ok ? "转录✅" : "转录❌")
            }
            changed = changed || ok
        }
        return Outcome(
            state: changed ? .succeeded : .failed,
            message: messages.joined(separator: " "),
            contentChanged: changed,
            shouldExport: changed)
    }

    private func runFulltext(_ input: Input) async -> Outcome {
        let ok = await FullTextFetcher.shared.fetchAndStore(
            contentId: input.contentID,
            url: input.url,
            feedHtml: input.contentHTML,
            mode: input.fetchMode)
        return Outcome(
            state: ok ? .succeeded : .failed,
            message: ok ? "✅ 全文提取完成" : "❌ 全文提取失败",
            contentChanged: ok,
            shouldExport: false)
    }

    private func runScore(_ input: Input) async -> Outcome {
        let pipeline = LLMPipeline()
        let ok = (try? await PipelineWorker.scheduleManualLLM {
            await self.updateRunning(input.contentID, message: "AI 评分中…")
            return await pipeline.score(
                contentId: input.contentID, title: input.title, body: input.body)
        }) ?? false
        return aiOutcome(ok: ok, success: "✅ AI 评分完成", pipeline: pipeline)
    }

    private func runSummarize(_ input: Input) async -> Outcome {
        let pipeline = LLMPipeline()
        let ok = (try? await PipelineWorker.scheduleManualLLM {
            await self.updateRunning(input.contentID, message: "摘要中…")
            return await pipeline.summarize(
                contentId: input.contentID, title: input.title, body: input.body)
        }) ?? false
        return aiOutcome(ok: ok, success: "✅ 摘要完成", pipeline: pipeline)
    }

    private func runTranslate(_ input: Input) async -> Outcome {
        let pipeline = LLMPipeline()
        let ok: Bool
        if input.isMedia, let markdown = input.contentMarkdown, !markdown.isEmpty {
            ok = (try? await PipelineWorker.scheduleManualLLM {
                await self.updateRunning(input.contentID, message: "翻译中…")
                return await pipeline.translate(
                    contentId: input.contentID, title: input.title, body: markdown)
            }) ?? false
        } else if input.isMedia {
            let excerpt = input.contentHTML ?? input.excerpt ?? input.body
            ok = (try? await PipelineWorker.scheduleManualLLM {
                await self.updateRunning(input.contentID, message: "翻译中…")
                return await pipeline.translateExcerpt(
                    contentId: input.contentID, title: input.title, contentHtml: excerpt)
            }) ?? false
        } else {
            ok = (try? await PipelineWorker.scheduleManualLLM {
                await self.updateRunning(input.contentID, message: "翻译中…")
                return await pipeline.translate(
                    contentId: input.contentID, title: input.title, body: input.body)
            }) ?? false
        }
        return aiOutcome(ok: ok, success: "✅ 翻译完成", pipeline: pipeline)
    }

    private func runTranscribe(_ input: Input) async -> Outcome {
        let transcriber = TranscribePipeline()
        let ok = (try? await PipelineWorker.scheduleManualTranscription {
            await self.updateRunning(input.contentID, message: "转录中（下载+识别，较长）…")
            return await transcriber.transcribe(
                contentId: input.contentID,
                title: input.title,
                audioUrl: input.audioURL,
                pageUrl: input.url,
                language: input.language)
        }) ?? false
        return Outcome(
            state: ok ? .succeeded : .failed,
            message: ok ? "✅ 转录完成" : "❌ 转录失败",
            contentChanged: ok,
            shouldExport: ok)
    }

    private func deleteTranscript(_ input: Input) -> Outcome {
        guard let transcript = input.transcriptMarkdown, !transcript.isEmpty else {
            return Outcome(
                state: .noWork, message: "没有可删除的转录稿",
                contentChanged: false, shouldExport: false)
        }
        let ok = db.transaction {
            db.execute(
                "DELETE FROM content_job WHERE content_id = ? AND jtype = 'transcribe'",
                params: [input.contentID])
            && db.execute(
                "UPDATE content SET llm_transcript_md = NULL WHERE id = ?",
                params: [input.contentID])
        }
        return Outcome(
            state: ok ? .succeeded : .failed,
            message: ok ? "已删除转录稿" : "删除转录稿失败",
            contentChanged: ok,
            shouldExport: false)
    }

    private func aiOutcome(ok: Bool, success: String, pipeline: LLMPipeline) -> Outcome {
        Outcome(
            state: ok ? .succeeded : .failed,
            message: ok ? success : "❌ 处理失败：\(pipeline.lastError ?? "未知错误")",
            contentChanged: ok,
            shouldExport: ok)
    }

    private func updateRunning(_ contentID: Int64, message: String) async {
        // 找到该内容当前唯一的非终态命令；content 锁保证同一时间至多一个。
        // 具体 requestID 由 runLocked 的阶段更新负责，步骤消息只写 Trace，
        // 下一次状态模型扩展为事件流时可直接替换这里。
        Trace.i("处理进度 id=\(contentID)：\(message)", category: "processing")
    }

    private func updateRunning(_ command: ProcessingCommand, message: String) async {
        _ = await commands.update(
            command: command,
            state: .running,
            message: message)
    }

    private func runningMessage(for operation: ProcessingOperation) -> String {
        switch operation {
        case .allEnabled: "内容处理中…"
        case .fulltext: "全文提取中…"
        case .score: "AI 评分中…"
        case .summarize: "摘要中…"
        case .translate: "翻译中…"
        case .transcribe: "转录中（下载+识别，较长）…"
        case .deleteTranscript: "正在删除转录稿…"
        }
    }

    private static func fetchMode(config: String) -> FetchMode {
        guard let data = config.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["fetch_mode"] as? String,
              let mode = FetchMode(rawValue: raw) else { return .summary }
        return mode
    }
}
