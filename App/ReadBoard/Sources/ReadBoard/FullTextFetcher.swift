import Foundation

// MARK: - 自适应全文引擎
// 探测每个源最适合的全文获取方式, 缓存进 content_source.config.fetch_mode:
//   feed_full  — feed 自带 content_html ≥800 字符, 直接用 defuddle 转 md
//   defuddle   — defuddle 直连原页抓得动
//   cdp        — 需要浏览器渲染(Chrome CDP), 经 clip_core.fetchMarkdown
//   summary    — 抓不到全文, 只留摘要
// 执行时按 mode 走对应路径, 结果写 content_md + fetch_status + fetch_engine。

enum FetchMode: String, CaseIterable {
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

final class FullTextFetcher: @unchecked Sendable {
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
    func probeMode(feedUrl: String) async -> FetchMode {
        guard let feed = try? await FeedFetcher.fetch(urlString: feedUrl) else {
            return .summary
        }
        let samples = Array(feed.entries.prefix(2))
        guard !samples.isEmpty else { return .summary }

        // 第 1 级：feed 自带全文?
        let feedLongEnough = samples.contains { $0.html.count >= fullTextMinChars }
        if feedLongEnough { return .feedFull }

        // 第 2 级：defuddle 直连
        for entry in samples where !entry.url.isEmpty {
            if let md = runCLI(mode: "url", input: entry.url), md.count >= fullTextMinChars {
                return .defuddle
            }
        }

        // 第 3 级：CDP 浏览器渲染（只对已知需要浏览器的域名尝试, 避免无差别拉起 Chrome）
        for entry in samples where !entry.url.isEmpty {
            if Self.needsBrowser(entry.url),
               let md = runCLI(mode: "url", input: entry.url), md.count >= fullTextMinChars {
                return .cdp
            }
        }

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
        // media 类（播客/视频）没有正文网页, 直接跳过
        switch mode {
        case .feedFull:
            guard let html = feedHtml, html.count >= 40 else {
                markFetched(contentId: contentId, ok: false, engine: mode.rawValue)
                return false
            }
            guard let md = runCLI(stdinHTML: html), md.count >= 40 else {
                markFetched(contentId: contentId, ok: false, engine: mode.rawValue)
                return false
            }
            storeMd(contentId: contentId, md: md, engine: mode.rawValue, direct: true)
            return true

        case .defuddle, .cdp:
            guard !url.isEmpty, let md = runCLI(mode: "url", input: url), md.count >= 40 else {
                markFetched(contentId: contentId, ok: false, engine: mode.rawValue)
                return false
            }
            storeMd(contentId: contentId, md: md, engine: mode.rawValue, direct: true)
            return true

        case .summary:
            // 抓不到全文: 保留 feed 摘要, fetch_status=4(直入)
            markFetched(contentId: contentId, ok: true, engine: mode.rawValue)
            return false
        }
    }

    // MARK: - 私有

    private func storeMd(contentId: Int64, md: String, engine: String, direct: Bool) {
        db.execute(
            "UPDATE content SET content_md = ?, fetch_status = 2, fetch_engine = ? WHERE id = ?",
            params: [md, engine, contentId]
        )
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

    /// 调 node CLI 的 html 模式（stdin 喂 HTML）
    private func runCLI(stdinHTML html: String) -> String? {
        runProcess(args: [cliPath, "html"], stdinData: html.data(using: .utf8))
    }

    private func runProcess(args: [String], stdinData: Data?) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodeBin)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        if let stdinData {
            let inPipe = Pipe()
            proc.standardInput = inPipe
            do {
                try proc.run()
                inPipe.fileHandleForWriting.write(stdinData)
                inPipe.fileHandleForWriting.closeFile()
            } catch { return nil }
        } else {
            do { try proc.run() } catch { return nil }
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, !out.isEmpty else { return nil }
        return String(data: out, encoding: .utf8)
    }
}
