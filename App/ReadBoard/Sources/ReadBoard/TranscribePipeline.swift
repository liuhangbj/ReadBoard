import Foundation

// MARK: - 播客/视频转录管线
// 流程: 下载音频(yt-dlp/直链) → ffmpeg 转 16k wav → whisper-cli(medium) 转写 →
//       非中文用 LLM 全文翻译成中文 → 写 llm_translated_md + 记 content_job

enum TranscribeError: Error, LocalizedError {
    case noAudioUrl
    case downloadFailed(String)
    case whisperFailed(String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .noAudioUrl: return "无音频地址"
        case .downloadFailed(let m): return "下载失败: \(m)"
        case .whisperFailed(let m): return "转写失败: \(m)"
        case .emptyTranscript: return "转写结果为空"
        }
    }
}

final class TranscribePipeline: @unchecked Sendable {
    private let db = Database.shared
    private let llm = LLMPipeline()

    // 依赖路径走 DependencyPaths 解析（用户配置 > PATH 探测 > 常见位置），不再硬编码
    private var whisperBin: String { DependencyPaths.resolve(.whisperCLI) ?? "whisper-cli" }
    private var ffmpegBin: String { DependencyPaths.resolve(.ffmpeg) ?? "ffmpeg" }
    private var ytdlpBin: String { DependencyPaths.resolve(.ytdlp) ?? "yt-dlp" }
    private var modelPath: String { DependencyPaths.resolve(.whisperModel) ?? "" }

    /// 转录单条内容（播客/视频）。audioUrl 为音频流或视频页地址。
    /// 结果写入 llm_translated_md（中文），并同步生成摘要。返回是否成功。
    @discardableResult
    func transcribe(contentId: Int64, title: String = "", audioUrl: String?, pageUrl: String, language: String?) async -> Bool {
        let target = audioUrl ?? pageUrl
        guard !target.isEmpty else { await markJob(contentId: contentId, ok: false, err: "无地址"); return false }

        let workDir = NSTemporaryDirectory() + "readboard-tr-\(contentId)"
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: workDir) }

        do {
            // 1. 取音频：直链音频直接下载；否则走 yt-dlp 抽音频
            let audioPath = try await fetchAudio(target: target, workDir: workDir, direct: audioUrl != nil)
            // 2. 转 16k 单声道 wav（whisper.cpp 最稳的输入）
            let wavPath = workDir + "/audio.wav"
            try await run(ffmpegBin, ["-y", "-i", audioPath, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wavPath])
            // 3. whisper 转写
            let lang = whisperLang(language)
            let outBase = workDir + "/transcript"
            try await run(whisperBin, ["-m", modelPath, "-f", wavPath, "-l", lang, "--output-txt", "--output-file", outBase])
            var text = (try? String(contentsOfFile: outBase + ".txt", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { throw TranscribeError.emptyTranscript }

            // 4. 非中文 → LLM 全文翻译成中文（收编 Follo 能力）；中文直接用
            if lang != "zh", llm.isAvailable, let translated = await llm.translateRaw(text, targetLang: "中文") {
                text = translated
            }

            // 5. 写库：译文进 llm_translated_md
            let ok = db.execute(
                "UPDATE content SET llm_translated_md = ?, llm_processed_at = datetime('now') WHERE id = ?",
                params: [text, contentId])
            // 6. 转录稿自动补一段摘要（媒体内容没有正文，评分/摘要以转录稿为准）
            if ok, llm.isAvailable,
               let sum = await llm.summarizeRaw(title: title, body: text) {
                db.execute("UPDATE content SET llm_summary = ? WHERE id = ?", params: [sum, contentId])
            }
            await markJob(contentId: contentId, ok: ok, err: ok ? nil : "写库失败")
            return ok
        } catch {
            await markJob(contentId: contentId, ok: false, err: error.localizedDescription)
            return false
        }
    }

    // MARK: - 私有

    private func whisperLang(_ language: String?) -> String {
        guard let l = language?.lowercased() else { return "auto" }
        if l.hasPrefix("zh") || l == "cn" { return "zh" }
        if l.hasPrefix("en") { return "en" }
        return "auto"
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
            try await run(ytdlpBin, ["-x", "--audio-format", "mp3", "-o", tmpl, target])
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
    private func run(_ bin: String, _ args: [String], timeout: TimeInterval = 600) async throws {
        // 可变状态封装进 @unchecked Sendable 盒子，满足 @Sendable 闭包捕获要求
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var errData = Data()
            var resumed = false
            var watchdog: DispatchWorkItem?
            var resume: ((Result<Void, Error>) -> Void)?
        }
        let box = Box()
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

            box.resume = { result in
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
                    box.resume?(.success(()))
                } else {
                    box.lock.lock(); let errStr = String(data: box.errData, encoding: .utf8) ?? ""; box.lock.unlock()
                    let reason = proc.terminationReason == .uncaughtSignal ? "（超时/被终止）" : ""
                    box.resume?(.failure(TranscribeError.whisperFailed(
                        "\(URL(fileURLWithPath: bin).lastPathComponent) exit \(status)\(reason): \(errStr.suffix(200))")))
                }
            }
            do { try p.run() } catch { box.watchdog?.cancel(); box.resume?(.failure(error)) }
        }
    }

    /// 记 content_job（jtype=transcribe）
    private func markJob(contentId: Int64, ok: Bool, err: String?) async {
        db.execute(
            """
            INSERT INTO content_job (content_id, jtype, status, finished_at, error)
            VALUES (?, 'transcribe', ?, datetime('now'), ?)
            """,
            params: [contentId, ok ? 2 : 3, err])
    }
}
