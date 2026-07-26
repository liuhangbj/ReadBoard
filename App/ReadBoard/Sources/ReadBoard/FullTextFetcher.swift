import Foundation

// MARK: - 自适应全文引擎
// 探测每个源最适合的全文获取方式, 缓存进 content_source.config.fetch_mode:
//   feed_full  — feed 自带 content_html ≥800 字符, 直接用 defuddle 转 md
//   defuddle   — defuddle 直连原页抓得动
//   cdp        — 需要浏览器渲染(Chrome CDP), 经 clip_core.fetchMarkdown
//   summary    — 抓不到全文, 只留摘要
// 执行时按 mode 走对应路径, 结果写 content_md + fetch_status + fetch_engine。

public enum FetchMode: String, CaseIterable, Sendable {
    case feedFull = "feed_full"
    case defuddle = "defuddle"
    case cdp = "cdp"
    case summary = "summary"

    var displayName: String {
        switch self {
        case .feedFull: return "feed 自带全文"
        case .defuddle: return "defuddle 直连"
        case .cdp: return "浏览器渲染 (CDP)"
        case .summary: return "仅摘要"
        }
    }
}

public final class FullTextFetcher: @unchecked Sendable {
    static let shared = FullTextFetcher()

    /// node / CLI 脚本路径（node 走 DependencyPaths 解析，脚本在 App 资源内）
    private var nodeBin: String { DependencyPaths.resolve(.node) ?? "node" }
    private let cliPath = NSHomeDirectory() + "/readboard/App/ReadBoard/Resources/fetch_fulltext.js"

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
    ///   2. 否则调工具抓原页——clip_core 内部已按域名自动路由
    ///      （微信/jiqizhixin 走 CDP 浏览器，虎嗅走预处理，其余 defuddle 直连），
    ///      抓到 → 按域名记 defuddle 或 cdp（语义标记，实际路由 clip_core 定）
    ///   3. 都抓不到 → summary 兜底（留 feed 摘要）
    func probeMode(feedUrl: String) async -> FetchMode {
        guard let feed = try? await FeedFetcher.fetch(urlString: feedUrl) else {
            return .summary
        }
        let samples = Array(feed.entries.prefix(2))
        guard !samples.isEmpty else { return .summary }

        // 第 1 级：feed 自带全文?
        let feedLongEnough = samples.contains { $0.html.count >= fullTextMinChars }
        if feedLongEnough { return .feedFull }

        // 第 2 级：抓原页（clip_core 按域名自动路由 defuddle/CDP/预处理）。
        // 能抓到就按域名标记 mode——cdp 域名（微信/jiqizhixin）记 .cdp，其余记 .defuddle。
        for entry in samples where !entry.url.isEmpty {
            if let md = runCLI(mode: "url", input: entry.url), md.count >= fullTextMinChars {
                return Self.needsBrowser(entry.url) ? .cdp : .defuddle
            }
        }

        // 第 3 级：兜底——feed 摘要
        return .summary
    }

    /// 与 clip_core.needsBrowser 保持一致的域名判定
    static func needsBrowser(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host == "mp.weixin.qq.com" || host.hasSuffix(".mp.weixin.qq.com")
            || host == "cubox.pro" || host.hasSuffix(".cubox.pro")
            || host == "jiqizhixin.com" || host.hasSuffix(".jiqizhixin.com")
    }

    // MARK: 执行

    /// 按 mode 抓全文并写入 content_md / fetch_status / fetch_engine。
    /// 返回是否成功拿到全文。
    @discardableResult
    func fetchAndStore(contentId: Int64, url: String, feedHtml: String?, mode: FetchMode) async -> Bool {
        switch mode {
        case .feedFull:
            // feed 自带全文：html 转 md。阈值与 probeMode 对齐（800）——
            // 低于它的"feed 全文"其实是摘要，转出来没价值。
            guard let html = feedHtml, html.count >= fullTextMinChars else {
                markFetched(contentId: contentId, ok: false, engine: mode.rawValue)
                return false
            }
            guard let md = runCLI(stdinHTML: html), md.count >= 40 else {
                markFetched(contentId: contentId, ok: false, engine: mode.rawValue)
                return false
            }
            storeMd(contentId: contentId, md: md, engine: mode.rawValue)
            return true

        case .defuddle, .cdp:
            guard !url.isEmpty, let md = runCLI(mode: "url", input: url), md.count >= 40 else {
                markFetched(contentId: contentId, ok: false, engine: mode.rawValue)
                return false
            }
            storeMd(contentId: contentId, md: md, engine: mode.rawValue)
            return true

        case .summary:
            // 抓不到全文：保留 feed 摘要。fetch_status=4（直入）。
            // 兜底：excerpt 为空时把 content_html 剥标签填上——阅读器/归档都用 excerpt，
            // 空 excerpt 显示"（无内容）"（机器之心修解析器前就这状态）。
            markFetched(contentId: contentId, ok: true, engine: mode.rawValue)
            backfillExcerptIfEmpty(contentId: contentId, feedHtml: feedHtml)
            return false
        }
    }

    // MARK: - 私有

    private func storeMd(contentId: Int64, md: String, engine: String) {
        db.execute(
            "UPDATE content SET content_md = ?, fetch_status = 2, fetch_engine = ? WHERE id = ?",
            params: [md, engine, contentId]
        )
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
    private func runCLI(mode: String, input: String) -> String? {
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
        return runProcess(args: [cliPath, "html"], stdinData: wrapped.data(using: .utf8))
    }

    private func runProcess(args: [String], stdinData: Data?) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodeBin)
        proc.arguments = args
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
            return nil
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

        guard proc.terminationStatus == 0, !outData.isEmpty else { return nil }
        return String(data: outData, encoding: .utf8)
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
