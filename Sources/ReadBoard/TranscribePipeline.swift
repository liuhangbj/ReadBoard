import Foundation

// MARK: - 播客/视频转录管线
// 流程: 下载音频(yt-dlp/直链) → ffmpeg 转 16k wav → whisper-cli(medium) 转写 →
//       非中文用 LLM 生成双语稿 → 写 llm_transcript_md + 记 content_job

public enum TranscribeError: Error, LocalizedError {
    case noAudioUrl
    case downloadFailed(String)
    case whisperFailed(String)
    case emptyTranscript
    case timedOut(String)   // 进程超时被强杀——单独一类，区别于崩溃/参数错

    public var errorDescription: String? {
        switch self {
        case .noAudioUrl: return "无音频地址"
        case .downloadFailed(let m): return "下载失败: \(m)"
        case .whisperFailed(let m): return "转写失败: \(m)"
        case .emptyTranscript: return "转写结果为空"
        case .timedOut(let m): return "处理超时: \(m)"
        }
    }
}

public final class TranscribePipeline: @unchecked Sendable {
    typealias JobRecorder = @Sendable (_ contentId: Int64, _ ok: Bool, _ error: String?) async -> Void

    enum LLMPostProcessMode: Equatable {
        case polishOnly
        case bilingualTranslation
    }

    // 延迟获取，取消策略的纯回归测试不会初始化或触碰用户数据库。
    private var db: Database { Database.shared }
    private let llm = LLMPipeline()
    private let jobRecorder: JobRecorder?

    init(jobRecorder: JobRecorder? = nil) {
        self.jobRecorder = jobRecorder
    }

    // 依赖路径走 DependencyPaths 解析（用户配置 > PATH 探测 > 常见位置），不再硬编码
    private var whisperBin: String { DependencyPaths.resolve(.whisperCLI) ?? "whisper-cli" }
    private var ffmpegBin: String { DependencyPaths.resolve(.ffmpeg) ?? "ffmpeg" }
    private var ytdlpBin: String { DependencyPaths.resolve(.ytdlp) ?? "yt-dlp" }
    private var modelPath: String { DependencyPaths.resolve(.whisperModel) ?? "" }

    /// 转录单条内容（播客/视频）。audioUrl 为音频流或视频页地址。
    /// 结果写入 llm_transcript_md（中文或双语），并同步生成摘要。返回是否成功。
    @discardableResult
    func transcribe(contentId: Int64, title: String = "", audioUrl: String?, pageUrl: String, language: String?) async -> Bool {
        guard !Task.isCancelled else { return false }
        let target = audioUrl ?? pageUrl
        guard !target.isEmpty else { await markJob(contentId: contentId, ok: false, err: "无地址"); return false }

        // workDir 加唯一后缀——仅按 contentId 命名时，手动重试与 worker 并发跑同一内容
        // 会互相删/改文件产生半损坏 wav（修 P2-13）
        let workDir = NSTemporaryDirectory() + "readboard-tr-\(contentId)-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: workDir) }

        do {
            // B站付费/充电视频：接口会明确标记试看权限。转录仍保留，但必须在
            // 稿首说明不完整，并把访问状态写入 meta 供列表显示。
            let bilibiliAccess = try? await BilibiliFetcher.fetchVideoAccess(
                videoURL: pageUrl.isEmpty ? target : pageUrl)

            // 1. 取音频：直链音频直接下载；否则走 yt-dlp 抽音频。
            //    直链若 ffmpeg 认不出格式（伪装扩展名/异常封装），回退 yt-dlp 重抽。
            var audioPath = try await fetchAudio(target: target, workDir: workDir, direct: audioUrl != nil)
            // 2. 转 16k 单声道 wav（whisper.cpp 最稳的输入）
            let wavPath = workDir + "/audio.wav"
            do {
                try await run(ffmpegBin, ["-y", "-i", audioPath, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wavPath])
            } catch {
                // 直链音频 ffmpeg 转码失败 → 回退 yt-dlp 重抽（有些源直链是伪装格式）
                if audioUrl != nil {
                    audioPath = try await fetchAudio(target: pageUrl.isEmpty ? target : pageUrl, workDir: workDir, direct: false)
                    try await run(ffmpegBin, ["-y", "-i", audioPath, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wavPath])
                } else {
                    throw error
                }
            }
            // 3. whisper 转写
            let lang = ContentLanguage.whisperCode(language)
            let outBase = workDir + "/transcript"
            try await run(whisperBin, ["-m", modelPath, "-f", wavPath, "-l", lang, "--output-txt", "--output-file", outBase])
            var text = (try? String(contentsOfFile: outBase + ".txt", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { throw TranscribeError.emptyTranscript }

            // 4. 所有转录稿都交给 LLM 梳理；语言只决定处理模式。
            //    中文：整理断句/标点/段落，不翻译。非中文：整理原文并生成中文对照。
            let resolvedLanguage = ContentLanguage.resolvedAfterTranscription(
                declared: language, transcript: text)
            var postProcessError: String?
            if llm.isAvailable {
                switch Self.llmPostProcessMode(
                    declaredLanguage: language,
                    transcript: text,
                    translateEnabled: AIPromptSettings.transcriptTranslationEnabled) {
                case .polishOnly:
                    if let polished = await llm.polishTranscript(text) {
                        text = polished
                        fputs("[transcribe] 转录稿已由 LLM 用原语言整理 id=\(contentId)\n", stderr)
                    } else {
                        postProcessError = llm.lastError ?? "LLM 整理失败"
                        fputs("[transcribe] LLM 整理失败，保留 Whisper 原稿 id=\(contentId) err=\(postProcessError ?? "?")\n", stderr)
                    }
                case .bilingualTranslation:
                    if let bilingual = await llm.translateBilingual(text) {
                        text = bilingual
                    } else {
                        postProcessError = llm.lastError ?? "LLM 双语后处理失败"
                        fputs("[transcribe] LLM 双语后处理失败，保留 Whisper 原稿 id=\(contentId) err=\(postProcessError ?? "?")\n", stderr)
                    }
                }
            }
            guard !Task.isCancelled else { throw CancellationError() }

            if let bilibiliAccess, bilibiliAccess.isPartial,
               !text.hasPrefix(bilibiliAccess.transcriptNotice) {
                text = bilibiliAccess.transcriptNotice + "\n\n" + text
            }

            // 5. 写库：中英文对照稿进 llm_transcript_md（独立转录字段）
            let ok = db.execute("""
                UPDATE content
                SET llm_transcript_md = ?,
                    language = COALESCE(NULLIF(language, ''), ?),
                    llm_processed_at = datetime('now')
                WHERE id = ?
                """, params: [text, resolvedLanguage, contentId])
            if ok, let bilibiliAccess {
                updateBilibiliAccessMeta(contentId: contentId, access: bilibiliAccess)
            }
            // 注意：媒体摘要已由合并调用体系负责（以 content_md 字幕稿为源，
            // 走 needsSummary + runLLMStages，带 content_job 退避/死信自愈）。
            // 此处不再用转录稿生成 llm_summary，避免覆盖前者。
            // 后处理失败不算整条转录白跑：原稿已落库，但必须记失败让用户可见、可手动重试。
            await markJob(
                contentId: contentId,
                ok: ok && postProcessError == nil,
                err: ok ? postProcessError.map { "转录完成，LLM 后处理失败（已保留原稿）：\($0)" } : "写库失败")
            return ok
        } catch {
            return await finishAfterFailure(contentId: contentId, error: error)
        }
    }

    // MARK: - 私有

    private func updateBilibiliAccessMeta(contentId: Int64, access: BilibiliVideoAccess) {
        BilibiliAccessMetaStore.apply(contentId: contentId, access: access)
    }

    static func llmPostProcessMode(
        declaredLanguage: String?, transcript: String, translateEnabled: Bool = true
    ) -> LLMPostProcessMode {
        guard translateEnabled else { return .polishOnly }
        return ContentLanguage.shouldTranslateTranscript(declared: declaredLanguage, transcript: transcript)
            ? .bilingualTranslation
            : .polishOnly
    }

    /// 取消是 worker 生命周期事件，不是内容处理失败，不能累计死信次数。
    /// internal 便于用注入的 recorder 验证取消路径不会触碰真实数据库。
    func finishAfterFailure(contentId: Int64, error: Error) async -> Bool {
        guard !Task.isCancelled, !LLMClient.isCancellation(error) else { return false }
        await markJob(contentId: contentId, ok: false, err: error.localizedDescription)
        return false
    }

    /// 取音频文件路径。direct=true 表示 audioUrl 是直链音频，curl 下载；否则 yt-dlp 抽音频。
    private func fetchAudio(target: String, workDir: String, direct: Bool) async throws -> String {
        let outPath = workDir + "/source_audio"
        if direct {
            // 直链音频：URLSession 下载
            guard let url = URL(string: target) else { throw TranscribeError.downloadFailed("bad url") }
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code < 400 else { throw TranscribeError.downloadFailed("HTTP \(code)") }
            try FileManager.default.moveItem(at: tmp, to: URL(fileURLWithPath: outPath))
            return outPath
        } else {
            // 视频页 / 非直链：yt-dlp 抽最佳音频
            let tmpl = workDir + "/ydl.%(ext)s"
            var args = ["-x", "--audio-format", "mp3", "-o", tmpl, target]
            // Finder 启动的 GUI App 通常只有 /usr/bin:/bin 等系统 PATH。
            // yt-dlp 虽由绝对路径启动，但其后处理仍会从 PATH 查找 ffmpeg/ffprobe；
            // 显式传入二者所在目录，避免 Homebrew 安装正常却被误报为缺失。
            if let ffmpeg = DependencyPaths.resolve(.ffmpeg) {
                let directory = (ffmpeg as NSString).deletingLastPathComponent
                args.insert(contentsOf: ["--ffmpeg-location", directory], at: 0)
            }
            // 新版 yt-dlp 解析 YouTube 的签名需要 JavaScript runtime。
            // GUI App 同样不能依赖 PATH，显式交付已经解析到的 Node 绝对路径。
            if let node = DependencyPaths.resolve(.node) {
                args.insert(contentsOf: ["--js-runtimes", "node:\(node)"], at: 0)
            }
            try await run(ytdlpBin, args)
            // 找产出文件
            let files = try FileManager.default.contentsOfDirectory(atPath: workDir)
            guard let f = files.first(where: { $0.hasPrefix("ydl.") }) else {
                throw TranscribeError.downloadFailed("yt-dlp 无产出")
            }
            return workDir + "/" + f
        }
    }

    /// 跑外部进程，非 0 退出抛错。带超时 terminate + stdout/stderr 持续 drain。
    /// 不修这两个会出大事：whisper/ffmpeg 挂死则 continuation 永不 resume（任务永久卡死）；
    /// stdout 大量输出无人读会写满 pipe 缓冲区(64KB)导致子进程阻塞。
    /// internal 便于用短生命周期子进程做取消回归测试。
    func run(_ bin: String, _ args: [String], timeout: TimeInterval = 1800) async throws {
        // 可变状态封装进 @unchecked Sendable 盒子，满足 @Sendable 闭包捕获要求
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var errData = Data()
            var resumed = false
            var cancelled = false
            var watchdog: DispatchWorkItem?
            var process: Process?
            var resume: (@Sendable (Result<Void, Error>) -> Void)?

            func cancel() {
                lock.lock()
                cancelled = true
                let process = process
                let resume = resume
                lock.unlock()
                if let process, process.isRunning { process.terminate() }
                resume?(.failure(CancellationError()))
            }
        }
        let box = Box()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = args
                let errPipe = Pipe()
                let outPipe = Pipe()
                p.standardError = errPipe
                p.standardOutput = outPipe

                // 持续 drain 两个 pipe，防缓冲区写满阻塞子进程；stderr 攒着报错用
                errPipe.fileHandleForReading.readabilityHandler = { fh in
                    let chunk = fh.availableData
                    if !chunk.isEmpty { box.lock.lock(); box.errData.append(chunk); box.lock.unlock() }
                }
                outPipe.fileHandleForReading.readabilityHandler = { fh in
                    _ = fh.availableData   // stdout 丢弃，只 drain
                }

                let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                    box.lock.lock()
                    if box.resumed { box.lock.unlock(); return }
                    box.resumed = true
                    box.lock.unlock()
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    switch result {
                    case .success: cont.resume()
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
                box.lock.lock()
                box.process = p
                box.resume = finish
                let alreadyCancelled = box.cancelled
                box.lock.unlock()
                if alreadyCancelled { box.cancel(); return }

                // 超时看门狗：到点强杀进程
                box.watchdog = DispatchWorkItem {
                    if p.isRunning { p.terminate() }
                }
                if let wd = box.watchdog {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: wd)
                }

                p.terminationHandler = { proc in
                    box.watchdog?.cancel()
                    let status = proc.terminationStatus
                    if status == 0 {
                        finish(.success(()))
                    } else {
                        box.lock.lock()
                        let wasCancelled = box.cancelled
                        let errStr = String(data: box.errData, encoding: .utf8) ?? ""
                        box.lock.unlock()
                        if wasCancelled {
                            finish(.failure(CancellationError()))
                        } else {
                            let name = URL(fileURLWithPath: bin).lastPathComponent
                            // 被看门狗强杀（超时）单独归类：uncaughtSignal(SIGTERM) = 超时，区别于进程自己崩
                            if proc.terminationReason == .uncaughtSignal {
                                finish(.failure(TranscribeError.timedOut(
                                    "\(name) 超过 \(Int(timeout))s 未完成被终止（长音频属正常，可重试或加大超时）")))
                            } else {
                                finish(.failure(TranscribeError.whisperFailed(
                                    "\(name) exit \(status): \(errStr.suffix(200))")))
                            }
                        }
                    }
                }
                do {
                    try p.run()
                    // 处理 cancel 恰好发生在 isRunning=false、p.run() 之前的竞态。
                    box.lock.lock(); let cancelAfterLaunch = box.cancelled; box.lock.unlock()
                    if cancelAfterLaunch, p.isRunning { p.terminate() }
                } catch {
                    box.watchdog?.cancel()
                    finish(.failure(error))
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// 记 content_job（jtype=transcribe）
    private func markJob(contentId: Int64, ok: Bool, err: String?) async {
        // 防止任务在错误分类后、实际写库前被取消的竞态。
        guard ok || !Task.isCancelled else { return }
        if let jobRecorder {
            await jobRecorder(contentId, ok, err)
            return
        }
        db.execute(
            """
            INSERT INTO content_job (content_id, jtype, status, finished_at, error)
            VALUES (?, 'transcribe', ?, datetime('now'), ?)
            """,
            params: [contentId, ok ? 2 : 3, err])
    }
}
