import Foundation

/// YouTube 字幕全文提取。
/// yt-dlp 只负责解析字幕轨 URL，不下载视频/音频；优先人工字幕，其次原语言自动字幕。
enum YouTubeSubtitleFetcher {
    enum SubtitleError: LocalizedError {
        case dependencyMissing
        case processFailed(String)
        case malformedMetadata

        var errorDescription: String? {
            switch self {
            case .dependencyMissing: return "未找到 yt-dlp"
            case .processFailed(let message): return "YouTube 字幕解析失败：\(message)"
            case .malformedMetadata: return "YouTube 字幕信息格式异常"
            }
        }
    }

    static func fetchMarkdown(videoURL: String) async throws -> String? {
        guard !videoURL.isEmpty else { return nil }
        guard let ytdlp = DependencyPaths.resolve(.ytdlp) else {
            throw SubtitleError.dependencyMissing
        }
        var args = ["--skip-download", "--no-playlist", "--no-warnings", "--dump-single-json", videoURL]
        if let node = DependencyPaths.resolve(.node) {
            args.insert(contentsOf: ["--js-runtimes", "node:\(node)"], at: 0)
        }
        let metadata = try await run(ytdlp, args: args, timeout: 90)
        guard let root = try JSONSerialization.jsonObject(with: metadata) as? [String: Any] else {
            throw SubtitleError.malformedMetadata
        }
        guard let trackURL = selectedTrackURL(from: root) else { return nil }

        var request = URLRequest(url: trackURL, timeoutInterval: 45)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return parseSubtitleMarkdown(data)
    }

    /// 先选人工字幕；没有时选 `*-orig` 原语言自动字幕，避免把机器翻译字幕当原文。
    static func selectedTrackURL(from root: [String: Any]) -> URL? {
        if let manual = root["subtitles"] as? [String: Any],
           let url = selectedURL(in: manual, preferOriginalMarker: false) {
            return url
        }
        if let automatic = root["automatic_captions"] as? [String: Any] {
            return selectedURL(in: automatic, preferOriginalMarker: true)
        }
        return nil
    }

    private static func selectedURL(in tracks: [String: Any], preferOriginalMarker: Bool) -> URL? {
        let keys = tracks.keys.filter { $0 != "live_chat" }
        guard !keys.isEmpty else { return nil }
        let preferred: [String]
        if preferOriginalMarker, let original = keys.sorted().first(where: { $0.hasSuffix("-orig") }) {
            preferred = [original] + keys.sorted().filter { $0 != original }
        } else {
            let languageOrder = ["zh-Hans", "zh-CN", "zh-Hant", "zh-TW", "en", "en-US"]
            preferred = languageOrder.filter(keys.contains) + keys.sorted().filter { !languageOrder.contains($0) }
        }
        for key in preferred {
            guard let formats = tracks[key] as? [[String: Any]] else { continue }
            let ordered = formats.sorted { formatRank($0) < formatRank($1) }
            for format in ordered {
                if let raw = format["url"] as? String, let url = URL(string: raw) { return url }
            }
        }
        return nil
    }

    private static func formatRank(_ format: [String: Any]) -> Int {
        switch (format["ext"] as? String)?.lowercased() {
        case "json3": return 0
        case "srv3", "srv2", "srv1": return 1
        case "vtt": return 2
        default: return 3
        }
    }

    static func parseSubtitleMarkdown(_ data: Data) -> String? {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let events = root["events"] as? [[String: Any]] {
            let lines = events.compactMap { event -> String? in
                guard let segments = event["segs"] as? [[String: Any]] else { return nil }
                let line = segments.compactMap { $0["utf8"] as? String }.joined()
                return line.isEmpty ? nil : line
            }
            return SubtitleTextFormatter.markdown(from: lines)
        }
        // 个别轨道只提供 WebVTT。
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed != "WEBVTT" &&
                !trimmed.contains("-->") && Int(trimmed) == nil &&
                !trimmed.hasPrefix("Kind:") && !trimmed.hasPrefix("Language:")
        }
        return SubtitleTextFormatter.markdown(from: lines)
    }

    private static func run(_ executable: String, args: [String], timeout: TimeInterval) async throws -> Data {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var process: Process?
            var stdout = Data()
            var stderr = Data()
            var finished = false
            var continuation: CheckedContinuation<Data, Error>?

            func append(_ data: Data, toStdout: Bool) {
                guard !data.isEmpty else { return }
                lock.lock()
                if toStdout { stdout.append(data) } else { stderr.append(data) }
                lock.unlock()
            }

            func finish(_ result: Result<Data, Error>) {
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                let continuation = continuation
                self.continuation = nil
                lock.unlock()
                continuation?.resume(with: result)
            }
        }

        let state = State()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.standardOutput = outPipe
                process.standardError = errPipe
                state.lock.lock()
                state.process = process
                state.continuation = continuation
                state.lock.unlock()

                outPipe.fileHandleForReading.readabilityHandler = { state.append($0.availableData, toStdout: true) }
                errPipe.fileHandleForReading.readabilityHandler = { state.append($0.availableData, toStdout: false) }
                process.terminationHandler = { process in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    state.append(outPipe.fileHandleForReading.readDataToEndOfFile(), toStdout: true)
                    state.append(errPipe.fileHandleForReading.readDataToEndOfFile(), toStdout: false)
                    state.lock.lock()
                    let output = state.stdout
                    let errorText = String(data: state.stderr, encoding: .utf8) ?? ""
                    state.lock.unlock()
                    if process.terminationStatus == 0, !output.isEmpty {
                        state.finish(.success(output))
                    } else {
                        state.finish(.failure(SubtitleError.processFailed(String(errorText.prefix(500)))))
                    }
                }
                do {
                    try process.run()
                } catch {
                    state.finish(.failure(error))
                    return
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
            }
        } onCancel: {
            state.lock.lock()
            let process = state.process
            state.lock.unlock()
            if let process, process.isRunning { process.terminate() }
            state.finish(.failure(CancellationError()))
        }
    }
}

enum SubtitleTextFormatter {
    static func markdown(from rawLines: [String]) -> String? {
        var lines: [String] = []
        for raw in rawLines {
            let cleaned = raw
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned != lines.last else { continue }
            lines.append(cleaned)
        }
        guard !lines.isEmpty else { return nil }

        var paragraphs: [String] = []
        var current = ""
        for line in lines {
            if !current.isEmpty, needsSpace(between: current, and: line) { current += " " }
            current += line
            if current.count >= 320 || (current.count >= 160 && endsSentence(line)) {
                paragraphs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。！？.!?".contains(last)
    }

    private static func needsSpace(between left: String, and right: String) -> Bool {
        guard let a = left.last, let b = right.first else { return false }
        let leftCanJoin = a.isLetter || a.isNumber || ".,!?;:".contains(a)
        return a.isASCII && b.isASCII && leftCanJoin && (b.isLetter || b.isNumber)
    }
}
