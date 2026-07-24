import Foundation

// MARK: - Feed 抓取与解析（自研，脱离 FreshRSS）
// 收编原 FeedParser.php 逻辑：RSS 2.0 <item> / Atom <entry>，识别 podcast enclosure / YouTube 扩展

public struct ParsedEntry {
    let guid: String
    let title: String
    let url: String
    let published: Date?
    let html: String
    let author: String?
    var meta: [String: String] = [:]   // audio_url / video_id / duration 等
}

public enum FeedKind: String {
    case article, podcast, video
}

public struct ParsedFeed {
    let title: String
    let siteURL: String?
    var entries: [ParsedEntry]
    /// 按内容特征判定类型（收编 detectType 逻辑）
    var kind: FeedKind {
        if entries.contains(where: { $0.meta["video_id"] != nil }) { return .video }
        if entries.contains(where: { $0.meta["audio_url"] != nil }) { return .podcast }
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
        let cid = try await fetchChannelId(pageURL: url, proxy: proxy)
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
    /// 抓取并解析一个 feed
    static func fetch(urlString: String, proxy: String? = nil) async throws -> ParsedFeed {
        guard let url = URL(string: urlString) else { throw FeedFetchError.badURL }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("ReadBoard/1.0 (+https://readboard.local)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")

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
        guard !data.isEmpty else { throw FeedFetchError.emptyBody }

        guard let feed = FeedXMLParser().parse(data: data) else {
            throw FeedFetchError.parseFailed
        }
        return feed
    }
}

// MARK: - XML 解析（RSS 2.0 + Atom）

private final class FeedXMLParser: NSObject, XMLParserDelegate {
    private var feedTitle = ""
    private var siteURL: String?
    private var entries: [ParsedEntry] = []

    // 当前条目累积态
    private var inEntry = false        // <item> 或 <entry>
    private var currentElement = ""
    private var buf = ""
    private var eGuid = "", eTitle = "", eURL = "", eHTML = "", eAuthor: String?
    private var ePublished: Date?
    private var eMeta: [String: String] = [:]
    private var sawAnyEntryTag = false

    func parse(data: Data) -> ParsedFeed? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        let ok = parser.parse()
        guard ok, sawAnyEntryTag else { return nil }
        return ParsedFeed(title: feedTitle, siteURL: siteURL, entries: entries)
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
                // podcast 音频
                if let type = attr["type"], type.hasPrefix("audio"), let u = attr["url"] {
                    eMeta["audio_url"] = u
                    if let len = attr["length"] { eMeta["audio_length"] = len }
                }
            case "id":
                // YouTube Atom: <yt:videoId> 单独处理；media:content 见下
                break
            default:
                // media:content / media:group 里的媒体
                if element == "media:content", let u = attr["url"], let mt = attr["type"], mt.hasPrefix("video") {
                    eMeta["video_url"] = u
                }
            }
        } else {
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
            case "content:encoded", "content", "description", "summary":
                if eHTML.isEmpty { eHTML = text }
            case "author", "dc:creator", "itunes:author", "name":
                if eAuthor == nil && !text.isEmpty { eAuthor = text }
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
        }
        buf = ""
    }

    private func finishEntry() {
        let guid = !eGuid.isEmpty ? eGuid : (!eURL.isEmpty ? eURL : eTitle)
        guard !guid.isEmpty else { return }
        entries.append(ParsedEntry(
            guid: guid, title: eTitle, url: eURL, published: ePublished,
            html: eHTML, author: eAuthor, meta: eMeta
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
