import Foundation

// MARK: - 自适应全文引擎
// 探测每个源最适合的全文提取方式, 缓存进 content_source.config.fetch_mode:
//   feed_full  — feed 自带 content_html ≥800 字符, 直接用 defuddle 转 md
//   defuddle   — defuddle 直连原页抓得动
//   youtube_subtitle  — YouTube 字幕提取
//   bilibili_subtitle — Bilibili 字幕提取
//   cdp        — 需要浏览器渲染(Chrome CDP/微信绕过)。暂未收编——engine 返回 NEEDS_CDP 退出码 3，降级 summary
//   summary    — 抓不到全文, 只留摘要
// 执行时按 mode 走对应路径, 结果写 content_md + fetch_status + fetch_engine。
// 抓取引擎：Resources/engine/fetch_engine.js（defuddle + node_modules 随 App 打包）

public enum FetchMode: String, CaseIterable, Sendable {
    case feedFull = "feed_full"
    case defuddle = "defuddle"
    case youtubeSubtitle = "youtube_subtitle"
    case bilibiliSubtitle = "bilibili_subtitle"
    case externalFulltext = "external_fulltext"
    case summary = "summary"

    var displayName: String {
        switch self {
        case .feedFull: return "feed 自带全文"
        case .defuddle: return "defuddle 本地"
        case .youtubeSubtitle: return "YouTube字幕提取"
        case .bilibiliSubtitle: return "BiliBili 字幕提取"
        case .externalFulltext: return "平台内置全文提取"
        case .summary: return "仅摘要"
        }
    }

    var isPlatformSubtitle: Bool {
        self == .youtubeSubtitle || self == .bilibiliSubtitle
    }

    /// 用户可手动选择的通用全文方式；平台专有连接器模式由 stype/连接器自动决定，
    /// 不出现在 RSS 通用的手动菜单里。
    var isUserSelectable: Bool {
        self != .externalFulltext && !isPlatformSubtitle
    }

    /// 平台专属提取路径只能由 source.stype 决定，不能从笼统的 FeedKind.video 推断。
    static func platformDefault(for sourceType: String) -> FetchMode? {
        switch sourceType {
        case "youtube": return .youtubeSubtitle
        case "bilibili": return .bilibiliSubtitle
        default: return nil
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
    // 引擎路径：用户配置优先，其次 App/SwiftPM 资源；不再回落到源码仓库绝对路径。
    private lazy var cliPath: String = {
        DependencyPaths.resolve(.defuddleEngine) ?? ""
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
    /// 自动检测该源最高优先级的全文提取模式——确定后记录，后续固定用该模式
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

        // 播客：按用户决定固定为 summary 模式。
        // 注意 summary 模式现在也会把 feed 自带的 description/show notes 写入 content_md，
        // 因此「固定 summary」≠「不落盘正文」——播客正文在 summary 路径下照常进入 content_md，
        // 与文章一样走统一落盘逻辑（详见 tryFetch 的 .summary 分支 + writeBackFeedHtmlAsMd）。
        if feed.kind == .podcast {
            return .summary
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
            let success: Bool
            switch currentMode {
            case .youtubeSubtitle:
                if let md = try? await YouTubeSubtitleFetcher.fetchMarkdown(videoURL: url),
                   md.count >= 40 {
                    storeMd(contentId: contentId, md: md, engine: currentMode.rawValue)
                    success = true
                } else {
                    markFetched(contentId: contentId, ok: false, engine: currentMode.rawValue)
                    success = false
                }
            case .bilibiliSubtitle:
                if let md = try? await BilibiliFetcher.fetchSubtitleMarkdown(videoURL: url),
                   md.count >= 40 {
                    storeMd(contentId: contentId, md: md, engine: currentMode.rawValue)
                    success = true
                } else {
                    markFetched(contentId: contentId, ok: false, engine: currentMode.rawValue)
                    success = false
                }
            default:
                success = tryFetch(contentId: contentId, url: url, feedHtml: feedHtml, mode: currentMode)
            }
            if success {
                // 降级成功了——更新源的 fetch_mode 为降级后的模式
                // 平台字幕缺失只影响当前视频，不能把整个频道永久降级成「仅摘要」。
                if currentMode != mode && !mode.isPlatformSubtitle {
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

        case .externalFulltext:
            // 外部连接器应在条目入库前已经提供正文；这个模式只表示
            // “平台自带全文链路”，不要再按普通 RSS 走 defuddle/summary。
            markFetched(contentId: contentId, ok: true, engine: mode.rawValue)
            return false

        case .summary:
            markFetched(contentId: contentId, ok: true, engine: mode.rawValue)
            // summary 模式不再「只留摘要」。按统一落盘目标：把 feed 自带的
            // body（文章=feed HTML / 播客=show notes description；均以 feedHtml 传入，
            // 解析器已把 description 并入 entry.html）写入 content_md。
            // 与 feedFull 保持一致：html→markdown 后落盘；defuddle 对短片段/show notes 返空，
            // 故此处走「剥离 HTML 当纯文本」的降级写法（参照 backfillExcerptIfEmpty 的剥标签口径），
            // 把可读正文直接落 content_md，实现「所有提取模式都能落盘 content_md」。
            writeBackFeedHtmlAsMd(contentId: contentId, feedHtml: feedHtml)
            return false

        case .youtubeSubtitle, .bilibiliSubtitle:
            // 两个字幕路径包含异步网络/进程操作，由 fetchAndStore 处理。
            return false
        }
    }

    /// 降级链：当前模式失败后的下一级
    private func nextFallbackMode(after mode: FetchMode) -> FetchMode? {
        switch mode {
        case .feedFull: return .defuddle
        case .defuddle: return .summary
        case .externalFulltext: return nil
        case .youtubeSubtitle, .bilibiliSubtitle: return .summary
        case .summary: return nil
        }
    }

    // MARK: - 私有

    /// 外部平台适配器已经提取完成的 Markdown 统一落盘入口。
    /// 仅接受最终文稿，不暴露数据库，也不让公开核心感知平台鉴权细节。
    func storeExternalMarkdown(contentId: Int64, markdown: String, engine: String) {
        let value = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        storeMd(contentId: contentId, md: value, engine: engine)
    }

    /// 外部平台的源列表已经更新成功，但某一条正文提取失败。
    /// 错误只落到 content，不得污染 content_source.error 或中断同源其他条目。
    func markExternalFailure(contentId: Int64, error: Error, engine: String) {
        let message = String(error.localizedDescription.prefix(1_000))
        db.execute(
            """
            UPDATE content
            SET fetch_status = 3, fetch_engine = ?, fetch_error = ?, fetched_full_at = NULL
            WHERE id = ?
            """,
            params: [engine, message, contentId]
        )
        NotificationCenter.default.post(name: .contentUpdated, object: nil)
    }

    fileprivate func extractExternalHTML(_ html: String) -> String? {
        runCLI(stdinHTML: html)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func storeMd(contentId: Int64, md: String, engine: String) {
        db.execute(
            """
            UPDATE content
            SET content_md = ?, fetch_status = 2, fetch_engine = ?, fetch_error = NULL,
                fetched_full_at = datetime('now')
            WHERE id = ?
            """,
            params: [md, engine, contentId]
        )
        // 旧译文可能仍引用上一次全文中的透明占位图。图片数量一致时只同步图片标记，
        // 不重跑翻译、不改译文文字；导出与远程 Reader 也能立即得到修复后的版本。
        if let translation = db.scalarString(
            "SELECT llm_translated_md FROM content WHERE id = ?", params: [contentId]),
           let reconciled = MarkdownImageReconciler.reconcile(
               translation: translation, source: md),
           reconciled != translation {
            db.execute(
                "UPDATE content SET llm_translated_md = ? WHERE id = ?",
                params: [reconciled, contentId])
        }
        // 全文提取完成——通知共享资料库刷新全文状态标签。
        NotificationCenter.default.post(name: .contentUpdated, object: nil)
    }

    /// summary 模式兜底（仅 fetch_mode 显式设为"仅摘要"或三级判定降级到底时触发）：
    /// 不发起抓取，excerpt 空时从 content_html 剥标签生成展示摘要。
    /// 注意：正常文章/播客/视频源已不再默认落在此模式（见 probeMode 三级判定）。
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

    /// summary 模式的正文落盘：把 feed 自带正文（feedHtml）写入 content_md。
    /// 与 .feedFull 路径目标一致——保证「summary 模式也能落盘 content_md」，
    /// 所有类型/所有提取模式在提取阶段都产出 content_md，供 LLM 评分/翻译/摘要统一使用。
    /// 口径参照 backfillExcerptIfEmpty（剥离 HTML 标签 + 压空白），并已实测：
    /// 短 show notes / 摘要类片段喂给 defuddle 会返回空，故此处直接剥标签当纯文本落盘，
    /// 不依赖 defuddle。幂等：content_md 已存在则跳过，不覆盖既有抽取结果。
    private func writeBackFeedHtmlAsMd(contentId: Int64, feedHtml: String?) {
        let hasMd = (db.scalarInt(
            "SELECT LENGTH(COALESCE(content_md,'')) FROM content WHERE id = ?",
            params: [contentId]) ?? 0) > 0
        guard !hasMd, let html = feedHtml, !html.isEmpty else { return }
        // 与 backfillExcerptIfEmpty 一致：剥 HTML 标签 + 压空白。这里不截断（保留全文正文）。
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ",
                                             options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ",
                                         options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        db.execute("UPDATE content SET content_md = ?, fetch_status = 2, fetch_engine = ? WHERE id = ?",
                   params: [text, FetchMode.summary.rawValue, contentId])
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
        // 之前把 standardInput 放在 run() 之后导致后台全文提取崩 App。
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

/// 模块可复用的通用 HTML → Markdown 能力。网络请求和平台认证仍由模块负责；
/// 公开核心只复用已经随 App 打包的 Defuddle 引擎。
public enum ReadBoardContentExtractor {
    public static func markdown(fromHTML html: String) async -> String? {
        guard !html.isEmpty else { return nil }
        return await Task.detached(priority: .utility) {
            FullTextFetcher.shared.extractExternalHTML(html)
        }.value
    }
}

// MARK: - 批量重提全文（右键菜单调用）

extension FullTextFetcher {
    /// 重抓单篇全文
    func refetchSingleFulltext(contentId: Int64) async {
        guard let row = Database.shared.queryRows("""
            SELECT c.url, c.content_html, s.config, s.stype
            FROM content c LEFT JOIN content_source s ON c.source_id = s.id
            WHERE c.id = ?
            """, params: [contentId]).first else { return }
        if let sourceType = row["stype"],
           await MainActor.run(body: {
               ReadBoardSourceConnectorRegistry.shared.connector(for: sourceType) != nil
           }) {
            _ = await SourceStore.shared.retryExternalFulltext(contentId: contentId)
            return
        }
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
            SELECT c.id, c.url, c.content_html, s.config, s.stype
            FROM content c LEFT JOIN content_source s ON c.source_id = s.id
            WHERE c.source_id = ? AND c.is_duplicate = 0
            """, params: [sourceId])
        for row in rows {
            guard let cid = Int64(row["id"] ?? "") else { continue }
            if let sourceType = row["stype"],
               await MainActor.run(body: {
                   ReadBoardSourceConnectorRegistry.shared.connector(for: sourceType) != nil
               }) {
                _ = await SourceStore.shared.retryExternalFulltext(contentId: cid)
                continue
            }
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
