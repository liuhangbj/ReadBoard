import Foundation

/// B站 UP 主动态流拉取适配器
/// 用 feed/space 接口(零 WBI 签名，只需 buvid3 + SESSDATA)拉取视频动态
public enum BilibiliFetcher {

    // MARK: - 常量

    private static let feedSpaceURL = "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/space"

    // MARK: - 主入口

    /// 拉取指定 UP 主的视频动态，返回 ParsedFeed
    /// - Parameters:
    ///   - uid: UP 主 UID
    ///   - historyScope: 历史回溯范围(recent_30d / recent_1y / all)
    /// - Returns: ParsedFeed(entries 为视频卡)
    static func fetch(uid: String, historyScope: HistoryScope = .recent30d) async throws -> ParsedFeed {
        guard let sessdata = BilibiliAuth.sessdata else {
            throw BilibiliError.badURL
        }
        let buvid3 = try await fetchBuvid3()
        let cookie = "buvid3=\(buvid3); SESSDATA=\(sessdata)"

        var allEntries: [ParsedEntry] = []
        var offset = ""
        var hasMore = true
        var pageCount = 0
        let maxPages = historyScope.maxPages

        while hasMore && pageCount < maxPages {
            let url = "\(feedSpaceURL)?host_mid=\(uid)&offset=\(offset)&timezone_offset=-480"
            let data = try await httpGet(url, cookie: cookie)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = json["code"] as? Int, code == 0,
                  let dataObj = json["data"] as? [String: Any] else {
                throw BilibiliError.badURL
            }

            let items = dataObj["items"] as? [[String: Any]] ?? []
            let videoEntries = items.compactMap { parseVideoCard($0) }
            allEntries.append(contentsOf: videoEntries)

            // 分页控制
            hasMore = dataObj["has_more"] as? Bool ?? false
            offset = dataObj["offset"] as? String ?? ""
            pageCount += 1

            // 历史范围过滤：如果当前页最老视频已超出范围，停止翻页
            if let oldest = videoEntries.last?.published,
               let cutoff = historyScope.cutoffDate,
               oldest < cutoff {
                hasMore = false
            }
        }

        // 按历史范围过滤
        let filtered = filterByHistoryScope(allEntries, scope: historyScope)

        return ParsedFeed(
            title: "B站 UP 主 \(uid)",
            siteURL: "https://space.bilibili.com/\(uid)",
            entries: filtered
        )
    }

    // MARK: - 字幕全文

    /// 用 BVID → CID → player/v2 字幕轨，提取正文字幕；不下载视频。
    static func fetchSubtitleMarkdown(videoURL: String) async throws -> String? {
        guard let bvid = extractBVID(from: videoURL), let sessdata = BilibiliAuth.sessdata else {
            return nil
        }
        let buvid3 = try await fetchBuvid3()
        let cookie = "buvid3=\(buvid3); SESSDATA=\(sessdata)"

        let pageData = try await httpGet(
            "https://api.bilibili.com/x/player/pagelist?bvid=\(bvid)", cookie: cookie)
        guard let pageRoot = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any],
              let code = pageRoot["code"] as? Int, code == 0,
              let pages = pageRoot["data"] as? [[String: Any]],
              let cid = pages.first?["cid"] as? Int else { return nil }

        let playerData = try await httpGet(
            "https://api.bilibili.com/x/player/v2?bvid=\(bvid)&cid=\(cid)", cookie: cookie)
        guard let playerRoot = try? JSONSerialization.jsonObject(with: playerData) as? [String: Any],
              let player = playerRoot["data"] as? [String: Any],
              let subtitle = player["subtitle"] as? [String: Any],
              let tracks = subtitle["subtitles"] as? [[String: Any]] else { return nil }

#if DEBUG
        if ProcessInfo.processInfo.environment["READBOARD_BILIBILI_DIAGNOSTICS"] == "1" {
            let languages = tracks.compactMap { $0["lan"] as? String }
            print("BILIBILI_SUBTITLE_DIAGNOSTIC bvid=\(bvid) track_count=\(tracks.count) languages=\(languages)")
        }
#endif

        // 同一视频可能同时存在人工中文、AI 中文、自动翻译等多条轨道；语言名不能代表
        // 完整度。优先限定中文轨，再实际读取并选正文最长者，避免误取只有少量片段的轨道。
        let chineseTracks = tracks.filter { track in
            let language = (track["lan"] as? String ?? "").lowercased()
            return language.contains("zh") || language.contains("cn")
        }
        let candidates = (chineseTracks.isEmpty ? tracks : chineseTracks).prefix(6)
        var best: String?
        for track in candidates {
            guard var subtitleURL = track["subtitle_url"] as? String, !subtitleURL.isEmpty else { continue }
            if subtitleURL.hasPrefix("//") { subtitleURL = "https:" + subtitleURL }
            guard let subtitleData = try? await httpGet(subtitleURL, cookie: cookie),
                  let markdown = parseSubtitleMarkdown(subtitleData), !markdown.isEmpty else { continue }
            if markdown.count > (best?.count ?? 0) { best = markdown }
        }
        return best
    }

    static func parseSubtitleMarkdown(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["body"] as? [[String: Any]] else { return nil }
        let lines = body.compactMap { $0["content"] as? String }
        return SubtitleTextFormatter.markdown(from: lines)
    }

    private static func extractBVID(from input: String) -> String? {
        let pattern = #"BV[0-9A-Za-z]+"#
        guard let range = input.range(of: pattern, options: .regularExpression) else { return nil }
        return String(input[range])
    }

    // MARK: - 视频卡解析

    /// 从动态流 items 中解析视频卡(MAJOR_TYPE_ARCHIVE)
    private static func parseVideoCard(_ item: [String: Any]) -> ParsedEntry? {
        guard let modules = item["modules"] as? [String: Any],
              let moduleDynamic = modules["module_dynamic"] as? [String: Any],
              let major = moduleDynamic["major"] as? [String: Any],
              let type = major["type"] as? String,
              type == "MAJOR_TYPE_ARCHIVE",
              let archive = major["archive"] as? [String: Any] else {
            return nil
        }

        guard let bvid = archive["bvid"] as? String,
              let title = archive["title"] as? String else {
            return nil
        }

        // 视频页 URL
        let videoURL = "https://www.bilibili.com/video/\(bvid)"

        // 作者信息
        let author = (modules["module_author"] as? [String: Any])?["name"] as? String

        // 发布时间
        let published: Date? = {
            guard let ts = archive["pubdate"] as? Int else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(ts))
        }()

        // 视频简介(用于 summary 落 md)
        let desc = archive["desc"] as? String ?? ""

        // 封面图
        let cover = archive["cover"] as? String

        // 时长
        let duration = archive["duration_text"] as? String

        var meta: [String: String] = [:]
        meta["video_id"] = bvid
        meta["video_url"] = videoURL
        if let cover { meta["cover_url"] = cover }
        if let duration { meta["duration"] = duration }

        return ParsedEntry(
            guid: bvid,
            title: title,
            url: videoURL,
            published: published,
            html: desc,
            author: author,
            meta: meta
        )
    }

    // MARK: - 历史范围过滤

    private static func filterByHistoryScope(_ entries: [ParsedEntry], scope: HistoryScope) -> [ParsedEntry] {
        guard let cutoff = scope.cutoffDate else { return entries }
        return entries.filter { entry in
            guard let published = entry.published else { return true }
            return published >= cutoff
        }
    }

    // MARK: - UID 提取

    /// 从用户输入(space.bilibili.com/UID 或纯 UID)提取 UID
    static func extractUID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // 纯数字 UID
        if trimmed.allSatisfy({ $0.isNumber }), !trimmed.isEmpty {
            return trimmed
        }
        // space.bilibili.com/UID 或 space.bilibili.com/UID/
        if let url = URL(string: trimmed),
           let host = url.host, host.contains("bilibili.com") {
            let path = url.pathComponents.filter { $0 != "/" }
            if let uid = path.first, uid.allSatisfy({ $0.isNumber }) {
                return uid
            }
        }
        // space.bilibili.com/UID 无协议头
        if trimmed.contains("space.bilibili.com/") {
            let components = trimmed.components(separatedBy: "space.bilibili.com/")
            if components.count > 1 {
                let uidPart = components[1].components(separatedBy: "/").first ?? ""
                if uidPart.allSatisfy({ $0.isNumber }), !uidPart.isEmpty {
                    return uidPart
                }
            }
        }
        return nil
    }

    // MARK: - buvid3

    private static func fetchBuvid3() async throws -> String {
        let data = try await httpGet("https://api.bilibili.com/x/frontend/finger/spi", cookie: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0,
              let dataObj = json["data"] as? [String: Any],
              let buvid3 = dataObj["b_3"] as? String else {
            throw BilibiliError.buvid3Failed
        }
        return buvid3
    }

    // MARK: - HTTP 工具

    private static func httpGet(_ urlString: String, cookie: String?) async throws -> Data {
        guard let url = URL(string: urlString) else { throw BilibiliError.badURL }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BilibiliError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}

// MARK: - 历史范围

public enum HistoryScope: String, CaseIterable, Sendable {
    case recent30d = "recent_30d"
    case recent1y = "recent_1y"
    case all = "all"

    var displayName: String {
        switch self {
        case .recent30d: return "仅最近 30 天"
        case .recent1y: return "近 1 年"
        case .all: return "全部历史"
        }
    }

    var cutoffDate: Date? {
        let now = Date()
        switch self {
        case .recent30d: return Calendar.current.date(byAdding: .day, value: -30, to: now)
        case .recent1y: return Calendar.current.date(byAdding: .year, value: -1, to: now)
        case .all: return nil
        }
    }

    var maxPages: Int {
        switch self {
        case .recent30d: return 3   // 3 页 ≈ 36 条，足够覆盖 30 天
        case .recent1y: return 20   // 20 页 ≈ 240 条，覆盖 1 年
        case .all: return 100       // 上限 100 页，防无限翻页
        }
    }
}
