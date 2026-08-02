import Foundation

// MARK: - Feed 抓取与解析（自研，脱离 FreshRSS）
// 收编原 FeedParser.php 逻辑：RSS 2.0 <item> / Atom <entry>，识别 podcast enclosure / YouTube 扩展

public struct ParsedEntry: Sendable {
    public let guid: String
    public let title: String
    public let url: String
    public let published: Date?
    public let html: String
    public let author: String?
    public var language: String?
    public var meta: [String: String]   // audio_url / video_id / duration 等
    /// 外部平台适配器已经完成提取的 Markdown。公开核心只负责统一入库，
    /// 不需要知道微信等平台的鉴权和反爬协议。
    public var contentMarkdown: String?

    public init(
        guid: String,
        title: String,
        url: String,
        published: Date?,
        html: String,
        author: String?,
        language: String? = nil,
        meta: [String: String] = [:],
        contentMarkdown: String? = nil
    ) {
        self.guid = guid
        self.title = title
        self.url = url
        self.published = published
        self.html = html
        self.author = author
        self.language = language
        self.meta = meta
        self.contentMarkdown = contentMarkdown
    }
}

public enum FeedKind: String, Sendable {
    case article, podcast, video
}

public struct ParsedFeed: Sendable {
    public let title: String
    public let siteURL: String?
    public let entries: [ParsedEntry]
    public var language: String?

    public init(
        title: String,
        siteURL: String?,
        entries: [ParsedEntry],
        language: String? = nil
    ) {
        self.title = title
        self.siteURL = siteURL
        self.entries = entries
        self.language = language
    }
    /// 按内容特征判定类型（收编 detectType 逻辑）
    var kind: FeedKind {
        // YouTube/media:content 是原生视频源；普通 RSS enclosure 即使承载 MP4，
        // 仍是音视频播客，不能因为容器是 video/mp4 就把整条播客源改成 youtube。
        if entries.contains(where: {
            $0.meta["video_id"] != nil ||
            ($0.meta["video_url"] != nil && $0.meta["enclosure_type"] == nil)
        }) { return .video }
        if entries.contains(where: {
            $0.meta["audio_url"] != nil ||
            ($0.meta["video_url"] != nil && $0.meta["enclosure_type"] != nil)
        }) { return .podcast }
        return .article
    }
}

public enum FeedFetchError: Error, LocalizedError {
    case badURL
    case httpError(Int)
    case emptyBody
    case parseFailed

    public var errorDescription: String? {
        switch self {
        case .badURL: return "无效的订阅地址"
        case .httpError(let c): return "HTTP 错误 \(c)"
        case .emptyBody: return "订阅内容为空"
        case .parseFailed: return "无法解析订阅格式（非 RSS/Atom）"
        }
    }
}

/// YouTube 输入 → feed URL 解析器
/// 支持：UC 频道 id、youtube.com/@handle、/channel/UC...、/c/xxx、/user/xxx、任意频道/视频页 URL
/// 原理：抓频道页 HTML，提取 "channelId":"UC..."（或 /channel/UC... 链接），拼 feeds/videos.xml
public enum YouTubeResolver {
    public enum ResolveError: Error, LocalizedError {
        case notYouTube
        case channelIdNotFound

        public var errorDescription: String? {
            switch self {
            case .notYouTube: return "不是有效的 YouTube 频道地址"
            case .channelIdNotFound: return "无法从频道页解析 channel_id（频道可能不存在）"
            }
        }
    }

    /// 把用户输入规范化为 videos.xml feed URL
    public static func resolveFeedURL(_ input: String, proxy: String? = nil) async throws -> String {
        let id = input.trimmingCharacters(in: .whitespaces)
        // 已是 feed URL
        if id.contains("feeds/videos.xml") { return id }
        // 纯 UC 频道 id
        if id.hasPrefix("UC"), !id.contains("/") {
            return "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)"
        }
        // URL 形式
        guard let url = URL(string: id), let host = url.host?.lowercased(),
              host.contains("youtube.com") || host.contains("youtu.be") else {
            throw ResolveError.notYouTube
        }
        // /channel/UC... 直接提取
        if let range = id.range(of: #"/channel/(UC[\w-]+)"#, options: .regularExpression) {
            let cid = String(id[range]).replacingOccurrences(of: "/channel/", with: "")
            return "https://www.youtube.com/feeds/videos.xml?channel_id=\(cid)"
        }
        // 其余（@handle、/c/、/user/、视频页）：抓页面 HTML 提取 channelId
        // proxy 传 nil 时回落到全局代理（FeedFetcher.globalProxy）
        let cid = try await fetchChannelId(pageURL: url, proxy: proxy ?? FeedFetcher.globalProxy)
        return "https://www.youtube.com/feeds/videos.xml?channel_id=\(cid)"
    }

    /// 抓频道页 HTML，正则提取 channelId
    private static func fetchChannelId(pageURL: URL, proxy: String?) async throws -> String {
        var req = URLRequest(url: pageURL, timeoutInterval: 30)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let config = URLSessionConfiguration.default
        if let proxy, let purl = URL(string: proxy), let host = purl.host, let port = purl.port {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: host,
                kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: host,
                kCFNetworkProxiesHTTPSPort: port,
            ]
        }
        let session = URLSession(configuration: config)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw FeedFetchError.httpError(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw ResolveError.channelIdNotFound
        }
        // 频道页 ytInitialData 内含 "channelId":"UC..."；视频页有 "externalChannelId"
        for pattern in [#""channelId"\s*:\s*"(UC[\w-]+)""#,
                        #""externalChannelId"\s*:\s*"(UC[\w-]+)""#,
                        #"youtube\.com/channel/(UC[\w-]+)"#] {
            if let m = html.range(of: pattern, options: .regularExpression) {
                let s = String(html[m])
                if let cidRange = s.range(of: #"UC[\w-]+"#, options: .regularExpression) {
                    return String(s[cidRange])
                }
            }
        }
        throw ResolveError.channelIdNotFound
    }
}

public final class FeedFetcher {
    /// 抓一个可能是网站主页的 URL，自动发现 RSS/Atom feed。
    /// 先直接试抓：是 feed 就返回；不是则按 HTML 解析 <link rel="alternate" type="application/rss+xml">。
    /// 返回 (feedURL, ParsedFeed)。找不到 feed 抛 parseFailed。
    static func discoverAndFetch(urlString: String, proxy: String? = nil) async throws -> (feedURL: String, feed: ParsedFeed) {
        let effectiveProxy = proxy ?? globalProxy
        // 1. 已知播客平台的节目页先解析为真实 RSS。
        if let resolvedURL = await resolvePlatformFeedURL(urlString: urlString, proxy: effectiveProxy),
           let feed = try? await fetch(urlString: resolvedURL, proxy: effectiveProxy) {
            return (resolvedURL, feed)
        }
        // 2. 直接试抓（已经是 feed URL 的情况）
        if let feed = try? await fetch(urlString: urlString, proxy: effectiveProxy) {
            return (urlString, feed)
        }
        // 3. 当 HTML 主页解析 feed 链接
        guard let url = URL(string: urlString) else { throw FeedFetchError.badURL }
        let data = try await downloadData(from: url, proxy: effectiveProxy)
        guard let html = String(data: data, encoding: .utf8) else { throw FeedFetchError.parseFailed }

        // 提取 <link ... type="application/rss+xml" ... href="...">（也认 atom）。
        // 用 NSRegularExpression 而非 String.ranges(of:options:)——后者对多选项 + 复杂模式推断不稳。
        guard let linkRe = try? NSRegularExpression(
            pattern: #"<link[^>]+type=["']application/(?:rss|atom)\+xml["'][^>]*>"#,
            options: [.caseInsensitive]) else { throw FeedFetchError.parseFailed }
        let full = NSRange(html.startIndex..., in: html)
        let linkTags = linkRe.matches(in: html, range: full).compactMap { Range($0.range, in: html) }
        guard let hrefRe = try? NSRegularExpression(pattern: #"href=["']([^"']+)["']"#) else {
            throw FeedFetchError.parseFailed
        }
        for tagRange in linkTags {
            let tag = String(html[tagRange])
            let tagNS = NSRange(tag.startIndex..., in: tag)
            guard let hrefMatch = hrefRe.firstMatch(in: tag, range: tagNS),
                  let hrefNS = Range(hrefMatch.range(at: 1), in: tag) else { continue }
            let href = String(tag[hrefNS])
                .replacingOccurrences(of: "&amp;", with: "&")
            // 相对 URL 补全
            if let feedURL = URL(string: href, relativeTo: url)?.absoluteURL,
               let feed = try? await fetch(urlString: feedURL.absoluteString, proxy: effectiveProxy) {
                return (feedURL.absoluteString, feed)
            }
        }
        throw FeedFetchError.parseFailed
    }

    /// Apple Podcasts 页面路径中的 `id123` → Apple podcast id。
    static func applePodcastID(from url: URL) -> String? {
        guard url.host?.lowercased() == "podcasts.apple.com",
              let re = try? NSRegularExpression(pattern: #"(?:^|/)id(\d+)(?:/|$)"#),
              let match = re.firstMatch(in: url.path, range: NSRange(url.path.startIndex..., in: url.path)),
              let range = Range(match.range(at: 1), in: url.path) else { return nil }
        return String(url.path[range])
    }

    /// 喜马拉雅节目页 → 公开 XML Feed。支持 `/album/8583636` 与 `/yule/8583636` 等栏目路径。
    static func ximalayaFeedURL(from url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "ximalaya.com" || host.hasSuffix(".ximalaya.com"),
              !url.path.lowercased().hasSuffix(".xml") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        let albumID: String?
        if let index = parts.firstIndex(where: { $0.lowercased() == "album" }), index + 1 < parts.count {
            albumID = parts[index + 1]
        } else if parts.count >= 2,
                  !["sound", "track"].contains(parts[parts.count - 2].lowercased()) {
            albumID = parts.last
        } else {
            albumID = nil
        }
        guard let albumID, !albumID.isEmpty,
              albumID.allSatisfy(\.isNumber) else { return nil }
        return "https://www.ximalaya.com/album/\(albumID).xml"
    }

    /// 荔枝节目页的 Next.js 数据包含 `band`（RSS 节目 id）。
    static func lizhiFeedURL(fromHTML html: String) -> String? {
        let normalized = html.replacingOccurrences(of: #"\""#, with: #"""#)
        guard let re = try? NSRegularExpression(pattern: #""band"\s*:\s*"(\d+)""#),
              let match = re.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let range = Range(match.range(at: 1), in: normalized) else { return nil }
        return "https://rss.lizhi.fm/rss/\(normalized[range]).xml"
    }

    /// 荔枝历史 Feed 常由 Apple 返回为 HTTP；统一 HTTPS，避免同一节目因协议不同重复入库。
    static func canonicalPlatformFeedURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw),
              components.scheme?.lowercased() == "http",
              components.host?.lowercased() == "rss.lizhi.fm" else { return raw }
        components.scheme = "https"
        return components.url?.absoluteString ?? raw
    }

    private struct AppleLookupResponse: Decodable {
        struct Result: Decodable { let feedUrl: String? }
        let results: [Result]
    }

    /// 平台节目页 → 真实 RSS。失败返回 nil，继续走通用 RSS 自动发现，不影响普通网站。
    private static func resolvePlatformFeedURL(urlString: String, proxy: String?) async -> String? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }

        if let podcastID = applePodcastID(from: url),
           let lookupURL = URL(string: "https://itunes.apple.com/lookup?id=\(podcastID)&entity=podcast"),
           let data = try? await downloadData(from: lookupURL, proxy: proxy, userAgent: "ReadBoard/1.0"),
           let response = try? JSONDecoder().decode(AppleLookupResponse.self, from: data) {
            return response.results.compactMap(\.feedUrl).first.map(canonicalPlatformFeedURL)
        }

        if let feedURL = ximalayaFeedURL(from: url) {
            return feedURL
        }

        if (host == "lizhi.fm" || host.hasSuffix(".lizhi.fm")),
           host != "rss.lizhi.fm", host != "nj.lizhi.fm",
           !url.path.lowercased().hasSuffix(".xml"),
           let data = try? await downloadData(from: url, proxy: proxy),
           let html = String(data: data, encoding: .utf8) {
            return lizhiFeedURL(fromHTML: html)
        }

        return nil
    }

    private static func downloadData(
        from url: URL,
        proxy: String?,
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.default
        if let proxy, let proxyURL = URL(string: proxy), let host = proxyURL.host, let port = proxyURL.port {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true, kCFNetworkProxiesHTTPProxy: host,
                kCFNetworkProxiesHTTPPort: port, kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: host, kCFNetworkProxiesHTTPSPort: port,
            ]
        }
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FeedFetchError.httpError(http.statusCode)
        }
        guard !data.isEmpty else { throw FeedFetchError.emptyBody }
        return data
    }

    /// 全局代理（设置页配置，UserDefaults 持久化）。所有 fetch/discover/probe 调用点统一走这里，
    /// 不再各处散落传参（此前只有 YouTubeResolver 用 proxy，常规抓取全丢代理）。
    static var globalProxy: String? {
        get {
            let v = UserDefaults.standard.string(forKey: "network.globalProxy")?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return v.isEmpty ? nil : v
        }
        set { UserDefaults.standard.set(newValue, forKey: "network.globalProxy") }
    }

    /// 抓取并解析一个 feed。proxy 传 nil 时自动回落到全局代理设置。
    static func fetch(urlString: String, proxy: String? = nil) async throws -> ParsedFeed {
        let effectiveProxy = proxy ?? globalProxy
        guard let url = URL(string: urlString) else { throw FeedFetchError.badURL }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("ReadBoard/1.0 (+https://readboard.local)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")

        let config = URLSessionConfiguration.default
        if let proxy = effectiveProxy, let purl = URL(string: proxy), let host = purl.host, let port = purl.port {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: host,
                kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: host,
                kCFNetworkProxiesHTTPSPort: port,
            ]
        }
        let session = URLSession(configuration: config)

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw FeedFetchError.httpError(http.statusCode)
        }
        guard !data.isEmpty else { throw FeedFetchError.emptyBody }

        guard let feed = FeedXMLParser().parse(data: data) else {
            throw FeedFetchError.parseFailed
        }
        return feed
    }

    // MARK: 测试辅助

    /// 剥嵌套 CDATA 壳：有的 feed（机器之心）把内容双重转义——
    /// 解析器拿到的字符串字面就是 "<![CDATA[<p>正文</p>]]>"，存库前剥掉这层壳，
    /// 否则 content_html 是废字符串、Defuddle 也解析不了。
    static func stripNestedCDATA(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("<![CDATA["), t.hasSuffix("]]>") else { return s }
        return String(t.dropFirst(9).dropLast(3))
    }

    /// 测试友好入口：直接解析 XML 字符串（绕过网络）
    static func parseFeedForTest(xml: String) -> ParsedFeed? {
        guard let data = xml.data(using: .utf8) else { return nil }
        return FeedXMLParser().parse(data: data)
    }
}

// MARK: - XML 解析（RSS 2.0 + Atom）

private final class FeedXMLParser: NSObject, XMLParserDelegate {
    private var feedTitle = ""
    private var siteURL: String?
    private var feedLanguage: String?
    private var entries: [ParsedEntry] = []

    // 当前条目累积态
    private var inEntry = false        // <item> 或 <entry>
    private var currentElement = ""
    private var buf = ""
    private var eGuid = "", eTitle = "", eURL = "", eHTML = "", eAuthor: String?
    private var eLanguage: String?
    private var ePublished: Date?
    private var eMeta: [String: String] = [:]
    private var sawAnyEntryTag = false

    func parse(data: Data) -> ParsedFeed? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        let ok = parser.parse()
        guard ok, sawAnyEntryTag else { return nil }
        return ParsedFeed(title: feedTitle, siteURL: siteURL, entries: entries,
                          language: ContentLanguage.normalize(feedLanguage))
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attr: [String: String] = [:]) {
        currentElement = element
        buf = ""
        let local = element.lowercased()

        if local == "item" || local == "entry" {
            inEntry = true
            sawAnyEntryTag = true
            eGuid = ""; eTitle = ""; eURL = ""; eHTML = ""; eAuthor = nil
            eLanguage = attr["xml:lang"] ?? attr["lang"]
            ePublished = nil; eMeta = [:]
            return
        }

        if inEntry {
            switch local {
            case "link":
                // Atom <link href="...">；RSS <link>text</link>
                if let href = attr["href"], !href.isEmpty {
                    let rel = attr["rel"] ?? "alternate"
                    if rel == "alternate" && eURL.isEmpty { eURL = href }
                }
            case "enclosure":
                // RSS enclosure 既可能是音频，也可能是视频播客。二者都保留直链；
                // 来源分类仍由 content_source.stype 决定，不把 video/mp4 播客混入视频平台。
                if let rawType = attr["type"]?.lowercased(), let u = attr["url"] {
                    if rawType.hasPrefix("audio") {
                        eMeta["audio_url"] = u
                    } else if rawType.hasPrefix("video") {
                        eMeta["video_url"] = u
                    }
                    if rawType.hasPrefix("audio") || rawType.hasPrefix("video") {
                        eMeta["enclosure_type"] = rawType
                        if let len = attr["length"] { eMeta["media_length"] = len }
                    }
                }
            case "id":
                // YouTube Atom: <yt:videoId> 单独处理；media:content 见下
                break
            default:
                // media:content / media:group 里的媒体
                if element == "media:content", let u = attr["url"], let mt = attr["type"], mt.hasPrefix("video") {
                    eMeta["video_url"] = u
                    eMeta["media_type"] = mt.lowercased()
                }
            }
        } else {
            // Atom 常在根 <feed xml:lang="zh-CN"> 声明语言。
            if feedLanguage == nil {
                feedLanguage = attr["xml:lang"] ?? attr["lang"]
            }
            // 频道级 link
            if local == "link", let href = attr["href"], !href.isEmpty, siteURL == nil {
                siteURL = href
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buf += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let local = element.lowercased()
        let text = buf.trimmingCharacters(in: .whitespacesAndNewlines)

        if inEntry {
            switch local {
            case "item", "entry":
                finishEntry()
                inEntry = false
            case "guid", "id":
                if eGuid.isEmpty { eGuid = text }
            case "title":
                if eTitle.isEmpty { eTitle = text }
            case "link":
                if eURL.isEmpty && !text.isEmpty { eURL = text }
            case "pubdate", "published", "updated", "dc:date":
                if ePublished == nil { ePublished = Self.parseDate(text) }
            case "content:encoded":
                // 全文字段：优先于 description/summary——即使 description 先到了也用全文覆盖
                // （机器之心等 feed：description 一句话摘要，content:encoded 才是全文）
                if text.count > eHTML.count { eHTML = text }
            case "content", "description", "summary":
                if eHTML.isEmpty { eHTML = text }
            case "author", "dc:creator", "itunes:author", "name":
                if eAuthor == nil && !text.isEmpty { eAuthor = text }
            case "language", "dc:language", "itunes:language":
                if eLanguage == nil && !text.isEmpty { eLanguage = text }
            case "yt:videoid":
                eMeta["video_id"] = text
            case "itunes:duration":
                eMeta["duration"] = text
            default:
                break
            }
        } else {
            if local == "title" && feedTitle.isEmpty { feedTitle = text }
            if local == "link" && siteURL == nil && !text.isEmpty { siteURL = text }
            if ["language", "dc:language", "itunes:language"].contains(local),
               feedLanguage == nil, !text.isEmpty {
                feedLanguage = text
            }
        }
        buf = ""
    }

    private func finishEntry() {
        // guid fallback：guid → url → title+日期。
        // 修 P0-2：title 单独作 guid 不稳——改标题后同篇变两条（旧 guid 失配重入库）、
        // 多篇同 title（"早报"）guid 相同真新内容被误杀。title fallback 时拼日期区分，
        // 减少同 title 碰撞 + 改标题后日期仍能对上旧条目（同篇同日）。
        let guid: String
        if !eGuid.isEmpty {
            guid = eGuid
        } else if !eURL.isEmpty {
            guid = eURL
        } else if !eTitle.isEmpty {
            let dateStr = ePublished.map { ISO8601DateFormatter().string(from: $0).prefix(10) } ?? ""
            guid = dateStr.isEmpty ? eTitle : "\(eTitle)|\(dateStr)"
        } else {
            return
        }
        guard !guid.isEmpty else { return }
        entries.append(ParsedEntry(
            guid: guid, title: eTitle, url: eURL, published: ePublished,
            html: FeedFetcher.stripNestedCDATA(eHTML), author: eAuthor,
            language: ContentLanguage.normalize(eLanguage ?? feedLanguage), meta: eMeta
        ))
    }

    // 兼容 RFC822 / ISO8601 日期
    private static func parseDate(_ s: String) -> Date? {
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let d = rfc.date(from: s) { return d }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }
}
