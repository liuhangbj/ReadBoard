import Foundation

// MARK: - 自适应全文引擎
// 探测每个源最适合的全文获取方式, 缓存进 content_source.config.fetch_mode:
//   feed_full  — feed 自带 content_html ≥800 字符, 直接用 defuddle 转 md
//   defuddle   — defuddle 直连原页抓得动
//   cdp        — 需要浏览器渲染(Chrome CDP/微信绕过)。暂未收编——engine 返回 NEEDS_CDP 退出码 3，降级 summary
//   summary    — 抓不到全文, 只留摘要
// 执行时按 mode 走对应路径, 结果写 content_md + fetch_status + fetch_engine。
// 抓取引擎：Resources/engine/fetch_engine.js（defuddle + node_modules 随 App 打包）

public enum FetchMode: String, CaseIterable, Sendable {
    case feedFull = "feed_full"
    case defuddle = "defuddle"
    case summary = "summary"

    var displayName: String {
        switch self {
        case .feedFull: return "feed 自带全文"
        case .defuddle: return "defuddle 本地"
        case .summary: return "仅摘要"
        }
    }
}

extension FullTextFetcher {
    /// 引擎 tag（fetch_engine.js 输出）→ fetch_engine 记录值。tag 与 FetchMode rawValue 一致，直接用。
    static func mapEngineTag(_ tag: String?) -> String? {
        guard let tag, !tag.isEmpty, tag.hasPrefix("defuddle") || tag == "feed_full" || tag == "summary" else { return nil }
        return tag
    }
    /// 引擎 tag → FetchMode
    static func fetchMode(forEngineTag tag: String) -> FetchMode? {
        FetchMode(rawValue: tag)
    }
}

public final class FullTextFetcher: @unchecked Sendable {
    static let shared = FullTextFetcher()

    /// node / CLI 脚本路径（node 走 DependencyPaths 解析，脚本在 App 资源内）
    private var nodeBin: String { DependencyPaths.resolve(.node) ?? "node" }
    // 引擎路径：Bundle 优先（App 打包在 Contents/Resources/engine），其次用户自定义 / ~/readboard 兜底。
    // 注意：之前硬编码 ~/readboard/App/ReadBoard/...，在 .app 部署形态下永远命中不到，导致全文抓取引擎缺失。
    private lazy var cliPath: String = {
        DependencyPaths.resolve(.defuddleEngine)
            ?? (NSHomeDirectory() + "/readboard/App/ReadBoard/Resources/engine/fetch_engine.js")
    }()

    /// 正文达到该长度视为"全文"（阈值, 与探测一致）
    private let fullTextMinChars = 800

    private let db = Database.shared

    private init() {}

    // MARK: 探测

    /// 探测一个 feed 源最合适抓取方式。取前 2 篇文章试验。
    /// 返回探测到的 mode（不持久化，由调用方写入 config）。
    ///
    /// 逻辑（与你的理解一致）：
    ///   1. feed 自带全文（content_html 够长）→ feedFull，直接 html 转 md
    ///   2. 否则调 engine 抓原页——defuddle 本地提取，
    ///      需 CDP 的源（微信/cubox/jiqizhixin）返回 NEEDS_CDP 退出码 3 → 降级 summary
    ///   3. 都抓不到 → summary 兜底（留 feed 摘要）
    /// 自动检测该源最高优先级的全文获取模式——确定后记录，后续固定用该模式
    /// 优先级：feed 自带全文 → defuddle → feed 摘要
    func probeMode(feedUrl: String) async -> FetchMode {
        guard let feed = try? await FeedFetcher.fetch(urlString: feedUrl) else {
            return .summary
        }
        return probeMode(forFeed: feed)
    }

    /// 对已抓取的 feed 做全文模式探测（供批量预检复用，避免重复网络请求）。
    func probeMode(forFeed feed: ParsedFeed) -> FetchMode {
        let samples = Array(feed.entries.prefix(2))
        guard !samples.isEmpty else { return .summary }

        // 播客：feed 不提供可读文本，只有音频，不应误判为全文。
        // 直接显示"摘要"（= 留 feed 自带的 show notes / 简介），不跑 defuddle 探测。
        if feed.kind == .podcast {
            return .summary
        }

        // YouTube（video）：feed 同样不提供可读文本，但「可获取全文」靠视频页抓字幕 +
        // 转录管线，而非 feed 自带。旧逻辑 `kind != .article` 一刀切把 YouTube 也判成
        // summary，导致自动检测永远"仅摘要"退化、没法用 defuddle。这里明确改成返回
        // .defuddle——标记该源走 defuddle 抓取（对视频页抓标题/简介，再交转录管线出稿），
        // 而不是"仅摘要"终态。（不进下面的实时 defuddle 网络探测：视频页正文价值低，
        // 且重新检测时对每篇跑 defuddle 既慢又多半空手而归）
        if feed.kind == .video {
            return .defuddle
        }

        // 第 1 级：feed 自带全文?
        let feedLongEnough = samples.contains { $0.html.count >= fullTextMinChars }
        if feedLongEnough { return .feedFull }

        // 第 2 级：defuddle 本地提取
        for entry in samples where !entry.url.isEmpty {
            let (md, _) = runCLI(mode: "url", input: entry.url)
            if let md, md.count >= fullTextMinChars { return .defuddle }
        }

        // 兜底：feed 摘要
        return .summary
    }

    // MARK: 执行

    /// 按 mode 抓全文并写入 content_md / fetch_status / fetch_engine。
    /// 失败时自动降级到下一级模式（defuddle→summary）。
    /// 降级成功后更新源的 fetch_mode——下次直接用降级后的模式，不再重复失败。
    /// 返回是否成功拿到全文。
    @discardableResult
    func fetchAndStore(contentId: Int64, url: String, feedHtml: String?, mode: FetchMode) async -> Bool {
        // 从给定模式开始，逐级降级尝试
        var currentMode = mode
        while true {
            let success = tryFetch(contentId: contentId, url: url, feedHtml: feedHtml, mode: currentMode)
            if success {
                // 降级成功了——更新源的 fetch_mode 为降级后的模式
                if currentMode != mode {
                    updateSourceFetchMode(contentId: contentId, newMode: currentMode)
                }
                return true
            }
            // 降级到下一级
            guard let next = nextFallbackMode(after: currentMode) else {
                // 已到最底层（summary）——summary 的 tryFetch 一定返回 false，但已标记 fetched
                return false
            }
            print("FullTextFetcher: \(currentMode.displayName) failed, falling back to \(next.displayName)")
            currentMode = next
        }
    }

    /// 降级成功后更新源的 fetch_mode——下次直接用降级后的模式
    private func updateSourceFetchMode(contentId: Int64, newMode: FetchMode) {
        guard let sourceId = db.scalarInt("SELECT source_id FROM content WHERE id = ?", params: [contentId]) else { return }
        let sid = Int64(sourceId)
        let current = db.scalarString("SELECT config FROM content_source WHERE id = ?", params: [sid]) ?? "{}"
        var obj = (try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any]) ?? [:]
        obj["fetch_mode"] = newMode.rawValue
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let str = String(data: data, encoding: .utf8) {
            db.execute("UPDATE content_source SET config = ? WHERE id = ?", params: [str, sid])
        }
    }

    /// 按模式实际抓一次——成功写库返回 true，失败标记 fetch_status=3 返回 false
    private func tryFetch(contentId: Int64, url: String, feedHtml: String?, mode: FetchMode) -> Bool {
        switch mode {
        case .feedFull:
            guard let html = feedHtml, html.count >= fullTextMinChars,
                  let md = runCLI(stdinHTML: html), md.count >= 40 else {
                markFetched(contentId: contentId, ok: false, engine: mode.rawValue)
                return false
            }
            storeMd(contentId: contentId, md: md, engine: mode.rawValue)
            return true

        case .defuddle:
            let (md, realEngine) = runCLI(mode: "url", input: url)
            guard !url.isEmpty, let md, md.count >= 40 else {
                markFetched(contentId: contentId, ok: false, engine: mode.rawValue)
                return false
            }
            // 用引擎回传的真实抓取引擎记录
            let actualEngine = Self.mapEngineTag(realEngine) ?? mode.rawValue
            storeMd(contentId: contentId, md: md, engine: actualEngine)
            // 真实引擎与调用模式不同（内部降级）——回写源的 fetch_mode，下次直接用真实引擎
            if let realEngine, let realMode = Self.fetchMode(forEngineTag: realEngine), realMode != mode {
                updateSourceFetchMode(contentId: contentId, newMode: realMode)
            }
            return true

        case .summary:
            markFetched(contentId: contentId, ok: true, engine: mode.rawValue)
            backfillExcerptIfEmpty(contentId: contentId, feedHtml: feedHtml)
            return false
        }
    }

    /// 降级链：当前模式失败后的下一级
    private func nextFallbackMode(after mode: FetchMode) -> FetchMode? {
        switch mode {
        case .feedFull: return .defuddle
        case .defuddle: return .summary
        case .summary: return nil
        }
    }

    // MARK: - 私有

    private func storeMd(contentId: Int64, md: String, engine: String) {
        db.execute(
            "UPDATE content SET content_md = ?, fetch_status = 2, fetch_engine = ? WHERE id = ?",
            params: [md, engine, contentId]
        )
        // 全文抓取完成——发通知刷新 ArticleRow 全文 badge（绿/红）
        NotificationCenter.default.post(name: .contentUpdated, object: nil)
    }

    /// summary 模式兜底：excerpt 空时从 content_html 剥标签生成
    private func backfillExcerptIfEmpty(contentId: Int64, feedHtml: String?) {
        let hasExcerpt = (db.scalarInt(
            "SELECT LENGTH(COALESCE(excerpt,'')) FROM content WHERE id = ?",
            params: [contentId]) ?? 0) > 0
        guard !hasExcerpt, let html = feedHtml, !html.isEmpty else { return }
        // 剥标签 + 压空白，取前 300 字
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ",
                                             options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ",
                                         options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        db.execute("UPDATE content SET excerpt = ? WHERE id = ?",
                   params: [String(text.prefix(300)), contentId])
    }

    private func markFetched(contentId: Int64, ok: Bool, engine: String) {
        db.execute(
            "UPDATE content SET fetch_status = ?, fetch_engine = ? WHERE id = ?",
            params: [ok ? 4 : 3, engine, contentId]
        )
    }

    // MARK: CLI 调用

    /// 调 node CLI 的 url 模式
    /// url 模式：返回 (markdown, realEngine)——realEngine 是引擎内部 fallback 后的真实抓取引擎
    private func runCLI(mode: String, input: String) -> (String?, String?) {
        runProcess(args: [cliPath, mode, input], stdinData: nil)
    }

    /// 调 node CLI 的 html 模式（stdin 喂 HTML）。
    /// content_html 常是正文片段（微信/wechat2rss 只给正文 <p> 序列，无 <html> 包裹），
    /// defuddle 对裸片段提取失败（"No content could be extracted"）。
    /// 包一层文档壳再喂——defuddle 需要完整 document 结构才能跑 Readability。
    private func runCLI(stdinHTML html: String) -> String? {
        let wrapped: String
        let lower = html.lowercased()
        if lower.contains("<html") || lower.contains("<!doctype") {
            wrapped = html   // 已是完整文档
        } else {
            wrapped = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>"
                    + html + "</body></html>"
        }
        return runProcess(args: [cliPath, "html"], stdinData: wrapped.data(using: .utf8)).0
    }

    /// 返回 (markdown, realEngine)：realEngine 从 stderr 的 RB_FETCH_ENGINE 解析（url 模式），
    /// html 模式无此标记返回 nil（调用方按 defuddle 记）。
    private func runProcess(args: [String], stdinData: Data?) -> (String?, String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodeBin)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["READBOARD_NODE_BIN"] = nodeBin
        proc.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // 关键修复：stderr 必须 drain——node 脚本 stderr 写满 64KB 管道缓冲即阻塞，
        // 父进程又在等 stdout EOF，双向死锁。两个管道都用 readabilityHandler 异步读。
        // 数据用锁保护的盒（readabilityHandler 并发执行，不能直接 mutate 捕获 var）。
        final class DataBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _data = Data()
            func append(_ d: Data) { lock.lock(); _data.append(d); lock.unlock() }
            var value: Data { lock.lock(); defer { lock.unlock() }; return _data }
        }
        let outBox = DataBox()
        let errBox = DataBox()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            outBox.append(h.availableData)
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            errBox.append(h.availableData)
        }

        // 关键修复：standardInput 必须在 run() 之前设好——进程启动后再设属性会抛
        // NSException（NOCOPY_SETTER_IMPL，Swift do/catch 抓不住直接 SIGABRT 崩溃）。
        // 之前把 standardInput 放在 run() 之后导致后台全文抓取崩 App。
        let inPipe = Pipe()
        if stdinData != nil {
            proc.standardInput = inPipe
        }

        do {
            try proc.run()
            if let stdinData, proc.isRunning {
                // 安全写 stdin：子进程可能在写之前就退出了 → pipe 断开 → write 抛
                // NSFileHandleOperationException（ObjC 异常，Swift do-catch 抓不住 → 崩溃）。
                // 用 POSIX write() 替代——失败返回 -1 而非抛异常。
                let fd = inPipe.fileHandleForWriting.fileDescriptor
                stdinData.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                    _ = write(fd, buf.baseAddress, buf.count)
                }
                inPipe.fileHandleForWriting.closeFile()
            }
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return (nil, nil)
        }

        // 超时保护：单次抓取最长 60s——此前无超时，一次挂死 runOnce 永不返回，
        // isRunning 恒 true，管线永久停摆。
        let deadline = Date().addingTimeInterval(60)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()   // 超时强杀
        }
        proc.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // 收尾读残留（handler 可能没读完最后的部分）
        outBox.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        errBox.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        let outData = outBox.value
        let errData = errBox.value

        guard proc.terminationStatus == 0, !outData.isEmpty else {
            // 记录失败原因（stderr）——MetalMiner 等源 defuddle 失败排查用
            if !errData.isEmpty, let errStr = String(data: errData, encoding: .utf8) {
                print("FullTextFetcher failed: \(errStr.prefix(200))")
            }
            return (nil, nil)
        }
        // 从 stderr 解析真实抓取引擎（fetch_engine.js url 模式输出 RB_FETCH_ENGINE:xxx）
        // ——引擎内部 fallback 后，标签要反映真实路径
        var realEngine: String? = nil
        if let errStr = String(data: errData, encoding: .utf8) {
            for line in errStr.split(separator: "\n") where line.hasPrefix("RB_FETCH_ENGINE:") {
                realEngine = String(line.dropFirst("RB_FETCH_ENGINE:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return (String(data: outData, encoding: .utf8), realEngine)
    }


}

// MARK: - 批量重抓全文（右键菜单调用）

extension FullTextFetcher {
    /// 重抓单篇全文
    func refetchSingleFulltext(contentId: Int64) async {
        guard let row = Database.shared.queryRows("""
            SELECT c.url, c.content_html, s.config
            FROM content c LEFT JOIN content_source s ON c.source_id = s.id
            WHERE c.id = ?
            """, params: [contentId]).first else { return }
        let url = row["url"] ?? ""
        let feedHtml = row["content_html"]
        // 从源 config 解析 fetch_mode
        var mode: FetchMode = .summary
        if let cfg = row["config"], !cfg.isEmpty,
           let data = cfg.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = obj["fetch_mode"] as? String,
           let m = FetchMode(rawValue: raw) { mode = m }
        await fetchAndStore(contentId: contentId, url: url, feedHtml: feedHtml, mode: mode)
    }

    /// 重抓某源全部文章全文
    func refetchSourceFulltext(sourceId: Int64) async {
        let rows = Database.shared.queryRows("""
            SELECT c.id, c.url, c.content_html, s.config
            FROM content c LEFT JOIN content_source s ON c.source_id = s.id
            WHERE c.source_id = ? AND c.is_duplicate = 0
            """, params: [sourceId])
        for row in rows {
            guard let cid = Int64(row["id"] ?? "") else { continue }
            let url = row["url"] ?? ""
            let feedHtml = row["content_html"]
            var mode: FetchMode = .summary
            if let cfg = row["config"], !cfg.isEmpty,
               let data = cfg.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = obj["fetch_mode"] as? String,
               let m = FetchMode(rawValue: raw) { mode = m }
            await fetchAndStore(contentId: cid, url: url, feedHtml: feedHtml, mode: mode)
        }
    }

    /// 重抓文件夹内所有源的全部文章全文
    func refetchFolderFulltext(folderId: Int64) async {
        let sourceIds = Database.shared.queryRows("""
            SELECT id FROM content_source WHERE folder_id = ?
            """, params: [folderId]).compactMap { Int64($0["id"] ?? "") }
        for sid in sourceIds {
            await refetchSourceFulltext(sourceId: sid)
        }
    }
}

// MARK: - URLSession 同步请求扩展

extension URLSession {
    func syncDataTask(with request: URLRequest) throws -> (Data, URLResponse)? {
        var result: (Data, URLResponse)?
        var error: Error?
        let semaphore = DispatchSemaphore(value: 0)
        let task = dataTask(with: request) { data, response, err in
            if let data = data, let response = response {
                result = (data, response)
            }
            error = err
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        if let error = error { throw error }
        return result
    }
}
