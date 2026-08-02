import Foundation

enum YouTubeStreamMetadata {
    nonisolated static func normalizedDuration(_ seconds: Double) -> Double {
        seconds.isFinite && seconds > 0 ? seconds : 0
    }

    nonisolated static func durationHint(from url: URL) -> Double {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawValue = components.queryItems?.first(where: { $0.name == "dur" })?.value,
              let seconds = Double(rawValue) else { return 0 }
        return normalizedDuration(seconds)
    }
}

/// 已完成的 YouTube 直链只做短期内存缓存；签名 URL 会过期，不落盘。
actor YouTubeStreamURLCache {
    struct Entry: Sendable {
        let url: URL
        let expiresAt: Date
    }

    static let shared = YouTubeStreamURLCache(ttl: 10 * 60)

    private let ttl: TimeInterval
    private var entries: [String: Entry] = [:]

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func value(for videoId: String, now: Date = Date()) -> URL? {
        guard let entry = entries[videoId] else { return nil }
        guard entry.expiresAt > now else {
            entries.removeValue(forKey: videoId)
            return nil
        }
        return entry.url
    }

    func store(_ url: URL, for videoId: String, now: Date = Date()) {
        entries[videoId] = Entry(url: url, expiresAt: now.addingTimeInterval(ttl))
    }

    func remove(_ videoId: String) {
        entries.removeValue(forKey: videoId)
    }
}

/// YouTube 播放直链解析。进程跟随调用 Task 生命周期，取消时真正终止 yt-dlp。
enum YouTubeStreamResolver {
    enum ResolveError: LocalizedError {
        case dependencyMissing
        case failed(String)
        case timedOut
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .dependencyMissing: return "未找到 yt-dlp"
            case .failed(let message): return message.isEmpty ? "yt-dlp 解析失败" : message
            case .timedOut: return "YouTube 地址解析超时"
            case .invalidOutput: return "YouTube 未返回可播放地址"
            }
        }
    }

    static func resolve(videoId: String) async throws -> URL {
        if let cached = await YouTubeStreamURLCache.shared.value(for: videoId) {
            return cached
        }
        guard let ytdlp = DependencyPaths.resolve(.ytdlp) else {
            throw ResolveError.dependencyMissing
        }
        let watchURL = "https://www.youtube.com/watch?v=\(videoId)"
        var args = [
            "--no-playlist", "--no-warnings", "-g", "-f",
            "best[ext=mp4][vcodec^=avc1][acodec!=none][height<=720]/best[ext=mp4][acodec!=none][height<=720]/best[acodec!=none][height<=720]",
            watchURL
        ]
        if let node = DependencyPaths.resolve(.node) {
            args.insert(contentsOf: ["--js-runtimes", "node:\(node)"], at: 0)
        }
        let output = try await run(ytdlp, args: args, timeout: 30)
        let candidates = String(data: output, encoding: .utf8)?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        guard let url = candidates.compactMap(URL.init(string:)).first(where: {
            $0.scheme == "https" || $0.scheme == "http"
        }) else {
            throw ResolveError.invalidOutput
        }
        await YouTubeStreamURLCache.shared.store(url, for: videoId)
        return url
    }

#if DEBUG
    static func runProcessForTesting(_ executable: String, args: [String], timeout: TimeInterval) async throws -> Data {
        try await run(executable, args: args, timeout: timeout)
    }
#endif

    private static func run(_ executable: String, args: [String], timeout: TimeInterval) async throws -> Data {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var process: Process?
            var stdout = Data()
            var stderr = Data()
            var continuation: CheckedContinuation<Data, Error>?
            var finished = false
            var didTimeout = false
            var cancelled = false

            func append(_ data: Data, stdout: Bool) {
                guard !data.isEmpty else { return }
                lock.lock()
                if stdout { self.stdout.append(data) } else { stderr.append(data) }
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
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.standardOutput = outPipe
                process.standardError = errPipe
                let drainGroup = DispatchGroup()

                state.lock.lock()
                state.process = process
                let alreadyFinished = state.finished
                if !alreadyFinished { state.continuation = continuation }
                state.lock.unlock()
                if alreadyFinished {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                // 每个 Pipe 只保留一个消费者。readabilityHandler 与终止回调同时读取
                // 同一 FileHandle 会产生竞态，快速取消/退出时可能触发 Foundation 异常。
                drainGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    state.append(outPipe.fileHandleForReading.readDataToEndOfFile(), stdout: true)
                    drainGroup.leave()
                }
                drainGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    state.append(errPipe.fileHandleForReading.readDataToEndOfFile(), stdout: false)
                    drainGroup.leave()
                }
                process.terminationHandler = { process in
                    drainGroup.notify(queue: .global(qos: .utility)) {
                        state.lock.lock()
                        let stdout = state.stdout
                        let stderr = String(data: state.stderr, encoding: .utf8) ?? ""
                        let timedOut = state.didTimeout
                        state.lock.unlock()
                        if timedOut {
                            state.finish(.failure(ResolveError.timedOut))
                        } else if process.terminationStatus == 0, !stdout.isEmpty {
                            state.finish(.success(stdout))
                        } else {
                            state.finish(.failure(ResolveError.failed(String(stderr.prefix(500)))))
                        }
                    }
                }

                do {
                    try process.run()
                    state.lock.lock()
                    let cancelled = state.cancelled
                    state.lock.unlock()
                    if cancelled, process.isRunning { process.terminate() }
                } catch {
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    state.finish(.failure(error))
                    return
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    state.lock.lock()
                    state.didTimeout = true
                    state.lock.unlock()
                    process.terminate()
                }
            }
        } onCancel: {
            state.lock.lock()
            state.cancelled = true
            let process = state.process
            state.lock.unlock()
            if let process, process.isRunning { process.terminate() }
            state.finish(.failure(CancellationError()))
        }
    }
}
