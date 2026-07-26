import Foundation

// MARK: - 自适应全文引擎
// 探测每个源最适合的全文获取方式, 缓存进 content_source.config.fetch_mode:
//   feed_full  — feed 自带 content_html ≥800 字符, 直接用 defuddle 转 md
//   defuddle   — defuddle 直连原页抓得动
//   cdp        — 需要浏览器渲染(Chrome CDP/微信绕过)。暂未收编——engine 返回 NEEDS_CDP 退出码 3，降级 summary
//   summary    — 抓不到全文, 只留摘要
// 执行时按 mode 走对应路径, 结果写 content_md + fetch_status + fetch_engine。
// 抓取引擎：Resources/engine/fetch_engine.js（自包含，defuddle+Jina，node_modules 随 App 打包）

public enum FetchMode: String, CaseIterable, Sendable {
    case feedFull = "feed_full"
    case defuddle = "defuddle"
    case jinaFree = "jina_free"
    case jinaPro = "jina_pro"
    case summary = "summary"

    var displayName: String {
        switch self {
        case .feedFull: return "feed 自带全文"
        case .defuddle: return "defuddle 本地"
        case .jinaFree: return "Jina Free"
        case .jinaPro: return "Jina Pro"
        case .summary: return "仅摘要"
        }
    }
}

extension FullTextFetcher {
    /// 引擎 tag（fetch_engine.js 输出）→ fetch_engine 记录值。tag 与 FetchMode rawValue 一致，直接用。
    static func mapEngineTag(_ tag: String?) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        return FetchMode(rawValue: tag) != nil ? tag : nil
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
    private let cliPath = NSHomeDirectory() + "/readboard/App/ReadBoard/Resources/engine/fetch_engine.js"

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
    ///   2. 否则调 engine 抓原页——内部按域名路由（虎嗅预处理 / defuddle 直连 / Jina 兜底），
    ///      需 CDP 的源（微信/cubox/jiqizhixin）返回 NEEDS_CDP 退出码 3 → 降级 summary
    ///   3. 都抓不到 → summary 兜底（留 feed 摘要）
    /// 自动检测该源最高优先级的全文获取模式——确定后记录，后续固定用该模式
    /// 优先级：feed 自带全文 → defuddle → Jina Free → Jina Pro → feed 摘要
    func probeMode(feedUrl: String) async -> FetchMode {
        guard let feed = try? await FeedFetcher.fetch(urlString: feedUrl) else {
            return .summary
        }
        let samples = Array(feed.entries.prefix(2))
        guard !samples.isEmpty else { return .summary }

        // 第 1 级：feed 自带全文?
        let feedLongEnough = samples.contains { $0.html.count >= fullTextMinChars }
        if feedLongEnough { return .feedFull }

        // 第 2 级：defuddle 本地提取（引擎内部可能 fallback 到 Jina——用真实引擎标记模式）
        for entry in samples where !entry.url.isEmpty {
            let (md, realEngine) = runCLI(mode: "url", input: entry.url)
            if let md, md.count >= fullTextMinChars {
                // 真实引擎是 Jina Free/Pro 时直接返回对应模式——源管理显示真实抓取路径
                if let realEngine, let realMode = Self.fetchMode(forEngineTag: realEngine) {
                    return realMode
                }
                return .defuddle
            }
        }

        // 第 3 级：Jina Free（开关控制）
        if UserDefaults.standard.bool(forKey: "jina.free") {
            for entry in samples where !entry.url.isEmpty {
                if let md = runJina(url: entry.url, usePro: false), md.count >= fullTextMinChars {
                    return .jinaFree
                }
            }
        }

        // 第 4 级：Jina Pro（开关控制 + 有 key）
        if UserDefaults.standard.bool(forKey: "jina.pro"),
           let key = UserDefaults.standard.string(forKey: "jina.apiKey"), !key.isEmpty {
            for entry in samples where !entry.url.isEmpty {
                if let md = runJina(url: entry.url, usePro: true), md.count >= fullTextMinChars {
                    return .jinaPro
                }
            }
        }

        // 兜底：feed 摘要
        return .summary
    }

    // MARK: 执行

    /// 按 mode 抓全文并写入 content_md / fetch_status / fetch_engine。
    /// 失败时自动降级到下一级模式（defuddle→Jina Free→Jina Pro→summary）。
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
            // 用引擎回传的真实抓取引擎记录——defuddle 内部可能走了 Jina Free/Pro
            let actualEngine = Self.mapEngineTag(realEngine) ?? mode.rawValue
            storeMd(contentId: contentId, md: md, engine: actualEngine)
            // 真实引擎与调用模式不同（内部降级）——回写源的 fetch_mode，下次直接用真实引擎
            if let realEngine, let realMode = Self.fetchMode(forEngineTag: realEngine), realMode != mode {
                updateSourceFetchMode(contentId: contentId, newMode: realMode)
            }
            return true

        case .jinaFree:
            guard !url.isEmpty, let md = runJina(url: url, usePro: false), md.count >= 40 else {
                markFetched(contentId: contentId, ok: false, engine: mode.rawValue)
                return false
            }
            storeMd(contentId: contentId, md: md, engine: mode.rawValue)
            return true

        case .jinaPro:
            guard !url.isEmpty, let md = runJina(url: url, usePro: true), md.count >= 40 else {
                markFetched(contentId: contentId, ok: false, engine: mode.rawValue)
                return false
            }
            storeMd(contentId: contentId, md: md, engine: mode.rawValue)
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
        case .defuddle:
            // defuddle 失败 → Jina Free（开了才走）→ Jina Pro（开了才走）→ summary
            if UserDefaults.standard.bool(forKey: "jina.free") { return .jinaFree }
            if UserDefaults.standard.bool(forKey: "jina.pro"),
               let key = UserDefaults.standard.string(forKey: "jina.apiKey"), !key.isEmpty { return .jinaPro }
            return .summary
        case .jinaFree:
            if UserDefaults.standard.bool(forKey: "jina.pro"),
               let key = UserDefaults.standard.string(forKey: "jina.apiKey"), !key.isEmpty { return .jinaPro }
            return .summary
        case .jinaPro: return .summary
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
        // 传 Jina 配置给 fetch_engine.js
        var env = ProcessInfo.processInfo.environment
        // node 路径——fetch_engine 用它调 defuddle CLI（保持与 App 解析的一致）
        env["READBOARD_NODE_BIN"] = nodeBin
        // Jina Free 开关（默认关——免费档 20 RPM，不能所有源都走）
        if UserDefaults.standard.bool(forKey: "jina.free") {
            env["JINA_FREE_ENABLED"] = "1"
        }
        // Jina Pro key（仅 Pro 开启且有 key 时传）
        if UserDefaults.standard.bool(forKey: "jina.pro"),
           let jinaKey = UserDefaults.standard.string(forKey: "jina.apiKey"), !jinaKey.isEmpty {
            env["JINA_API_KEY"] = jinaKey
        }
        if env["JINA_FREE_ENABLED"] != nil || env["JINA_API_KEY"] != nil {
            proc.environment = env
        }
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
            if let stdinData {
                inPipe.fileHandleForWriting.write(stdinData)
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
        // ——引擎内部 fallback 后，标签要反映真实路径（识别哪些源在烧 Jina token）
        var realEngine: String? = nil
        if let errStr = String(data: errData, encoding: .utf8) {
            for line in errStr.split(separator: "\n") where line.hasPrefix("RB_FETCH_ENGINE:") {
                realEngine = String(line.dropFirst("RB_FETCH_ENGINE:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return (String(data: outData, encoding: .utf8), realEngine)
    }

    /// 直接调 Jina Reader（不经过 clip_core 的 fallback 链）——jinaFree/jinaPro 模式用
    private func runJina(url: String, usePro: Bool) -> String? {
        let jinaUrl = "https://r.jina.ai/" + url
        var request = URLRequest(url: URL(string: jinaUrl)!)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        // 只保留链接文本，去掉 URL——导航链接变纯文本不占篇幅
        request.setValue("text", forHTTPHeaderField: "x-retain-links")
        // 延长超时——让 Jina 加载更多内容（展开按钮/懒加载）
        request.setValue("30", forHTTPHeaderField: "x-timeout")
        // 移除导航/广告/页脚——按通用选择器
        request.setValue("nav, footer, .sidebar, .ads, header, .advertisement, .social-share, .newsletter-signup", forHTTPHeaderField: "x-remove-selector")
        if usePro, let key = UserDefaults.standard.string(forKey: "jina.apiKey"), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 45
        guard let (data, response) = try? URLSession.shared.syncDataTask(with: request),
              let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
              let text = String(data: data, encoding: .utf8), text.count >= 50 else {
            return nil
        }
        // CAPTCHA/验证页检测——Jina 返回错误页不算成功
        let lower = text.lowercased()
        if lower.contains("access to this page has been denied")
            || lower.contains("press & hold to confirm")
            || lower.contains("captcha")
            || lower.contains("please make sure you are authorized") {
            return nil
        }
        // 清洗 Jina 返回——去掉导航/推荐链接段落（[text](url) 且 text < 50 字符的段落）
        let cleaned = Self.cleanJinaMarkdown(text)
        return cleaned.count >= 50 ? cleaned : nil
    }

    /// 清洗 Jina 返回的 markdown——去掉导航栏、推荐链接、订阅按钮等噪音段落
    /// 规则：段落全是链接（[text](url) 格式）且链接文本 < 50 字符 → 噪音
    private static func cleanJinaMarkdown(_ md: String) -> String {
        let paragraphs = md.components(separatedBy: "\n\n")
        var cleaned: [String] = []
        for para in paragraphs {
            let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空段落跳过
            if trimmed.isEmpty { continue }
            // 全是链接的段落（导航/推荐）——链接文本 < 50 字符
            let linkPattern = #"\[([^\]]{1,50})\]\([^)]+\)"#
            let regex = try! NSRegularExpression(pattern: linkPattern)
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            let matches = regex.matches(in: trimmed, range: range)
            var linkTextLen = 0
            for match in matches {
                if let r = Range(match.range(at: 1), in: trimmed) {
                    linkTextLen += trimmed[r].count
                }
            }
            // 段落长度和链接文本长度接近 → 全是链接，噪音
            if Double(linkTextLen) / Double(trimmed.count) > 0.8, trimmed.count < 500 {
                continue
            }
            // 订阅/导航关键词
            let navKeywords = ["subscribe", "sign in", "log in", "menu", "navigation"]
            if navKeywords.contains(where: { trimmed.lowercased().contains($0) }), trimmed.count < 200 {
                continue
            }
            cleaned.append(trimmed)
        }
        return cleaned.joined(separator: "\n\n")
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

// MARK: - URLSession 同步请求扩展（Jina 用）

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
