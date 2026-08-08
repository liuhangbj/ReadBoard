import Foundation

enum BilibiliAccessState: String, Sendable {
    case open
    case paidPreview
    case paidSeason
    case upowerExclusive
    case upowerEarlyAccess
    case loginRequired

    var listLabel: String? {
        switch self {
        case .open: return nil
        case .paidPreview: return "单片付费"
        case .paidSeason: return "付费合集"
        case .upowerExclusive: return "充电专属"
        case .upowerEarlyAccess: return "充电抢先看"
        case .loginRequired: return "需登录"
        }
    }
}

struct BilibiliVideoAccess: Sendable, Equatable {
    let state: BilibiliAccessState
    let toast: String?
    let privilegeType: Int?
    let jumpURL: URL?
    let isPartial: Bool

    init(
        state: BilibiliAccessState,
        toast: String?,
        privilegeType: Int?,
        jumpURL: URL?,
        isPartial: Bool? = nil
    ) {
        self.state = state
        self.toast = toast
        self.privilegeType = privilegeType
        self.jumpURL = jumpURL
        self.isPartial = isPartial ?? (state != .open)
    }

    var transcriptNotice: String {
        switch state {
        case .paidPreview:
            return "> ⚠️ 该视频为 B站付费内容，当前账号仅获得试看片段，以下转录稿不完整。"
        case .paidSeason:
            return "> ⚠️ 该视频属于 B站付费合集，当前账号仅获得试看片段，以下转录稿不完整。"
        case .upowerExclusive:
            let detail = toast ?? "当前账号仅获得试看片段"
            return "> ⚠️ 该视频为 B站 UP 主充电专属内容，\(detail)，以下转录稿不完整。"
        case .upowerEarlyAccess:
            let detail = toast ?? "当前账号尚未解锁完整内容"
            return "> ⚠️ 该视频为 B站 UP 主充电抢先看内容，\(detail)，以下转录稿不完整。"
        case .loginRequired:
            return "> ⚠️ 该视频需要更高登录权限，以下转录稿可能不完整。"
        case .open:
            return ""
        }
    }
}

/// B站 UP 主动态流拉取适配器
/// 用 feed/space 接口(零 WBI 签名，只需 buvid3 + SESSDATA)拉取视频动态
public enum BilibiliFetcher {

    private actor DeviceIdentityStore {
        private var value: (buvid3: String, createdAt: Date)?

        func current(maxAge: TimeInterval) -> String? {
            guard let value, Date().timeIntervalSince(value.createdAt) < maxAge else { return nil }
            return value.buvid3
        }

        func store(_ buvid3: String) {
            value = (buvid3, Date())
        }
    }

    // MARK: - 常量

    private static let feedSpaceURL = "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/space"
    private static let deviceIdentityStore = DeviceIdentityStore()

    // MARK: - 主入口

    /// 拉取指定 UP 主的视频动态，返回 ParsedFeed
    /// - Parameters:
    ///   - uid: UP 主 UID
    ///   - historyScope: 历史回溯范围(recent_30d / recent_1y / all)
    /// - Returns: ParsedFeed(entries 为视频卡)
    static func fetch(uid: String, historyScope: HistoryScope = .recent30d) async throws -> ParsedFeed {
        guard let sessdata = BilibiliAuth.sessdata else {
            throw BilibiliError.loginRequired
        }
        do {
            return try await fetchDynamicFeed(
                uid: uid, historyScope: historyScope, sessdata: sessdata)
        } catch {
            guard isRiskControlError(error) else { throw error }
            do {
                return try await fetchWBIArchiveFeed(
                    uid: uid, historyScope: historyScope, sessdata: sessdata)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // WBI 与动态流都属于 Web 风控域，可能同时返回 412。移动端投稿
                // 列表使用独立 App 签名，保留标题、发布时间和 UGC 付费标记。
                return try await fetchAppArchiveFeed(
                    uid: uid, historyScope: historyScope, sessdata: sessdata)
            }
        }
    }

    private static func isRiskControlError(_ error: Error) -> Bool {
        switch error {
        case BilibiliError.apiError(let code, _): return code == -352
        case BilibiliError.httpError(let code): return code == 412
        default: return false
        }
    }

    private static func fetchDynamicFeed(
        uid: String,
        historyScope: HistoryScope,
        sessdata: String
    ) async throws -> ParsedFeed {
        let buvid3 = try await fetchBuvid3()
        let cookie = "buvid3=\(buvid3); SESSDATA=\(sessdata)"

        var allEntries: [ParsedEntry] = []
        var offset = ""
        var hasMore = true
        var pageCount = 0
        var creatorName: String?
        let maxPages = historyScope.maxPages

        while hasMore && pageCount < maxPages {
            let url = "\(feedSpaceURL)?host_mid=\(uid)&offset=\(offset)&timezone_offset=-480"
            let data = try await httpGet(url, cookie: cookie)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = json["code"] as? Int else {
                throw BilibiliError.apiError(-1, "响应格式异常")
            }
            guard code == 0 else {
                throw BilibiliError.apiError(code, json["message"] as? String ?? "unknown")
            }
            guard let dataObj = json["data"] as? [String: Any] else {
                throw BilibiliError.apiError(code, "响应缺少 data")
            }

            let items = dataObj["items"] as? [[String: Any]] ?? []
            if creatorName == nil {
                creatorName = firstAuthorName(in: items)
            }
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
            title: creatorName ?? "BiliBili UP 主 \(uid)",
            siteURL: "https://space.bilibili.com/\(uid)",
            entries: filtered
        )
    }

    /// 动态接口触发 -352/412 后的只读降级路径。WBI 投稿列表与 bili-cli 的
    /// user-videos 使用同一接口，不依赖动态流风控；下一轮动态恢复时会合并补齐付费标签。
    private static func fetchWBIArchiveFeed(
        uid: String,
        historyScope: HistoryScope,
        sessdata: String
    ) async throws -> ParsedFeed {
        var entries: [ParsedEntry] = []
        var creatorName: String?
        for page in 1...historyScope.maxPages {
            let request = try await BilibiliAuth.signedWBIRequest(
                path: "/x/space/wbi/arc/search",
                params: [
                    "mid": uid,
                    "pn": String(page),
                    "ps": "30",
                    "tid": "0",
                    "keyword": "",
                    "order": "pubdate"
                ],
                sessdata: sessdata
            )
            let data = try await httpGet(request.url, cookie: request.cookie)
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = root["code"] as? Int else {
                throw BilibiliError.apiError(-1, "WBI 投稿列表响应格式异常")
            }
            guard code == 0 else {
                throw BilibiliError.apiError(code, root["message"] as? String ?? "unknown")
            }
            guard let dataObject = root["data"] as? [String: Any],
                  let list = dataObject["list"] as? [String: Any],
                  let videos = list["vlist"] as? [[String: Any]] else {
                throw BilibiliError.apiError(code, "WBI 投稿列表缺少 vlist")
            }
            if videos.isEmpty { break }
            let pageEntries = videos.compactMap(parseArchiveListVideo)
            if creatorName == nil {
                creatorName = videos.compactMap { $0["author"] as? String }
                    .first { !$0.isEmpty }
            }
            entries.append(contentsOf: pageEntries)
            if videos.count < 30 { break }
            if let cutoff = historyScope.cutoffDate,
               let oldest = pageEntries.last?.published, oldest < cutoff {
                break
            }
        }
        return ParsedFeed(
            title: creatorName ?? "BiliBili UP 主 \(uid)",
            siteURL: "https://space.bilibili.com/\(uid)",
            entries: filterByHistoryScope(entries, scope: historyScope)
        )
    }

    private static func parseArchiveListVideo(_ value: [String: Any]) -> ParsedEntry? {
        guard let bvid = value["bvid"] as? String,
              let title = value["title"] as? String else { return nil }
        let videoURL = "https://www.bilibili.com/video/\(bvid)"
        let published = unixTimestamp(value["created"] ?? value["pubdate"])
            .map { Date(timeIntervalSince1970: $0) }
        var meta = ["video_id": bvid, "video_url": videoURL,
                    "bilibili_access_source": "wbi_archive_fallback"]
        if let cover = value["pic"] as? String { meta["cover_url"] = cover }
        if let duration = value["length"] as? String { meta["duration"] = duration }
        return ParsedEntry(
            guid: bvid,
            title: title,
            url: videoURL,
            published: published,
            html: value["description"] as? String ?? value["desc"] as? String ?? "",
            author: value["author"] as? String,
            meta: meta
        )
    }

    /// Web 动态流和 WBI 投稿列表都触发风控时的移动端签名降级路径。
    private static func fetchAppArchiveFeed(
        uid: String,
        historyScope: HistoryScope,
        sessdata: String
    ) async throws -> ParsedFeed {
        let pageSize = 20
        var entries: [ParsedEntry] = []
        var creatorName: String?
        var cursorAid: String?

        for _ in 0..<historyScope.maxPages {
            var params = [
                "build": "8430300",
                "version": "8.43.0",
                "c_locale": "zh_CN",
                "channel": "master",
                "order": "pubdate",
                "ps": String(pageSize),
                "qn": "80",
                "s_locale": "zh_CN",
                "statistics": #"{"appId":1,"platform":3,"version":"8.43.0","abtest":""}"#,
                "vmid": uid
            ]
            if let cursorAid { params["aid"] = cursorAid }
            let request = try BilibiliAuth.signedAppArchiveRequest(
                params: params, sessdata: sessdata)
            let data = try await httpGet(request)
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = root["code"] as? Int else {
                throw BilibiliError.apiError(-1, "移动端投稿列表响应格式异常")
            }
            guard code == 0 else {
                throw BilibiliError.apiError(code, root["message"] as? String ?? "unknown")
            }
            guard let dataObject = root["data"] as? [String: Any],
                  let videos = dataObject["item"] as? [[String: Any]] else {
                throw BilibiliError.apiError(code, "移动端投稿列表缺少 item")
            }
            if videos.isEmpty { break }
            let pageEntries = videos.compactMap(parseAppArchiveVideo)
            if creatorName == nil {
                creatorName = videos.compactMap { $0["author"] as? String }
                    .first { !$0.isEmpty }
            }
            entries.append(contentsOf: pageEntries)

            guard let nextAid = videos.last.flatMap(appArchiveAid),
                  nextAid != cursorAid else { break }
            cursorAid = nextAid
            if videos.count < pageSize { break }
            if let cutoff = historyScope.cutoffDate,
               let oldest = pageEntries.last?.published, oldest < cutoff {
                break
            }
        }
        return ParsedFeed(
            title: creatorName ?? "BiliBili UP 主 \(uid)",
            siteURL: "https://space.bilibili.com/\(uid)",
            entries: filterByHistoryScope(entries, scope: historyScope)
        )
    }

    static func parseAppArchiveVideo(_ value: [String: Any]) -> ParsedEntry? {
        guard let bvid = value["bvid"] as? String,
              let title = value["title"] as? String else { return nil }
        let videoURL = "https://www.bilibili.com/video/\(bvid)"
        let published = unixTimestamp(value["ctime"] ?? value["pubdate"])
            .map { Date(timeIntervalSince1970: $0) }
        var meta = [
            "video_id": bvid,
            "video_url": videoURL,
            "bilibili_access_source": "app_archive_fallback"
        ]
        if let cover = value["cover"] as? String { meta["cover_url"] = cover }
        if let duration = flexibleInt(value["duration"]) {
            meta["duration"] = durationText(duration)
        }
        if let access = dynamicVideoAccess(from: value) {
            meta["bilibili_access_state"] = access.state.rawValue
            meta["bilibili_access_label"] = access.state.listLabel
            meta["bilibili_access_checked_at"] = ISO8601DateFormatter().string(from: Date())
        }
        return ParsedEntry(
            guid: bvid,
            title: title,
            url: videoURL,
            published: published,
            html: value["subtitle"] as? String ?? "",
            author: value["author"] as? String,
            meta: meta
        )
    }

    private static func appArchiveAid(_ value: [String: Any]) -> String? {
        if let aid = value["param"] as? String, !aid.isEmpty { return aid }
        if let aid = flexibleInt(value["aid"]) { return String(aid) }
        return nil
    }

    private static func durationText(_ seconds: Int) -> String {
        let total = max(seconds, 0)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%02d:%02d", minutes, remaining)
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

#if DEBUG
        let diagnosticsEnabled = ProcessInfo.processInfo.environment["READBOARD_BILIBILI_DIAGNOSTICS"] == "1"
        if diagnosticsEnabled {
            let part = pages.first?["part"] as? String ?? ""
            print("BILIBILI_SUBTITLE_DIAGNOSTIC bvid=\(bvid) cid=\(cid) part=\(part)")
        }
#endif

        // 旧的 /x/player/v2 在当前风控下会对同一 bvid/cid 随机返回其他视频的字幕轨。
        // 改用 WBI 播放器接口，并确保签名与设备 Cookie 成对生成。
        let playerRequest = try await BilibiliAuth.signedWBIRequest(
            path: "/x/player/wbi/v2",
            params: ["bvid": bvid, "cid": String(cid)],
            sessdata: sessdata
        )
        let playerData = try await httpGet(playerRequest.url, cookie: playerRequest.cookie)
        guard let playerRoot = try? JSONSerialization.jsonObject(with: playerData) as? [String: Any],
              let player = playerRoot["data"] as? [String: Any],
              let subtitle = player["subtitle"] as? [String: Any],
              let tracks = subtitle["subtitles"] as? [[String: Any]] else { return nil }

#if DEBUG
        if diagnosticsEnabled {
            let rights = player["rights"] as? [String: Any] ?? [:]
            let vip = player["vip"] as? [String: Any] ?? [:]
            let payment = player["payment"] as? [String: Any] ?? [:]
            let probe: [String] = [
                "aid", "bvid", "cid", "duration", "duration_text", "is_owner",
                "need_vip", "need_login", "preview", "argue_msg", "status",
                "is_ugc_pay_preview", "is_upower_exclusive",
                "is_upower_exclusive_with_qa", "is_upower_play",
                "need_login_subtitle", "permission", "preview_toast",
                "operation_card", "jump_card", "view_points", "options",
                "elec_high_level", "guide_attention", "max_limit",
                "type", "desc", "part", "pay", "pay_type", "vip_type"
            ].compactMap { key in
                guard let value = player[key] else { return nil }
                return "\(key)=\(value)"
            }
            print("BILIBILI_SUBTITLE_DIAGNOSTIC bvid=\(bvid) player_keys=\(player.keys.sorted()) probe=[\(probe.joined(separator: ", "))] rights=\(rights.keys.sorted()) vip=\(vip.keys.sorted()) payment=\(payment.keys.sorted())")
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
            guard let subtitleData = try? await httpGet(subtitleURL, cookie: playerRequest.cookie),
                  let markdown = parseSubtitleMarkdown(subtitleData), !markdown.isEmpty else { continue }
#if DEBUG
            if diagnosticsEnabled {
                let trackId = track["id_str"] as? String
                    ?? (track["id"] as? Int).map(String.init)
                    ?? "unknown"
                let language = track["lan"] as? String ?? "unknown"
                let preview = markdown.prefix(80).replacingOccurrences(of: "\n", with: " ")
                print("BILIBILI_SUBTITLE_DIAGNOSTIC bvid=\(bvid) cid=\(cid) track=\(trackId) lan=\(language) chars=\(markdown.count) preview=\(preview)")
            }
#endif
            if markdown.count > (best?.count ?? 0) { best = markdown }
        }
        return best
    }

    /// 读取单条视频的访问权限。B站明确返回 ugc_pay_preview/upower_exclusive 字段；
    /// 这比按转录长度猜测“会员/付费视频”可靠，也能区分开放视频。
    static func fetchVideoAccess(videoURL: String) async throws -> BilibiliVideoAccess? {
        guard let bvid = extractBVID(from: videoURL), let sessdata = BilibiliAuth.sessdata else {
            return nil
        }
        let buvid3 = try await fetchBuvid3()
        let cookie = "buvid3=\(buvid3); SESSDATA=\(sessdata)"
        let pageData = try await httpGet(
            "https://api.bilibili.com/x/player/pagelist?bvid=\(bvid)", cookie: cookie)
        guard let pageRoot = try? JSONSerialization.jsonObject(with: pageData) as? [String: Any],
              pageRoot["code"] as? Int == 0,
              let pages = pageRoot["data"] as? [[String: Any]],
              let cid = pages.first?["cid"] as? Int else { return nil }

        let playerRequest = try await BilibiliAuth.signedWBIRequest(
            path: "/x/player/wbi/v2",
            params: ["bvid": bvid, "cid": String(cid)],
            sessdata: sessdata
        )
        let playerData = try await httpGet(playerRequest.url, cookie: playerRequest.cookie)
        guard let playerRoot = try? JSONSerialization.jsonObject(with: playerData) as? [String: Any],
              let player = playerRoot["data"] as? [String: Any] else { return nil }

        return videoAccess(from: player)
    }

    static func videoAccess(from player: [String: Any]) -> BilibiliVideoAccess {
        let highLevel = player["elec_high_level"] as? [String: Any]
        let highLevelTitle = highLevel?["title"] as? String
        let highLevelToast = highLevel?["sub_title"] as? String
        let privilegeType = highLevel?["privilege_type"] as? Int
        let jumpURL = (highLevel?["jump_url"] as? String).flatMap(URL.init(string:))
        let toast = highLevelToast ?? player["preview_toast"] as? String
        if flexibleFlag(player["is_upower_exclusive"]) {
            let hint = [highLevelTitle, highLevelToast, toast]
                .compactMap { $0 }
                .joined(separator: " ")
            let state: BilibiliAccessState = hint.contains("抢先")
                ? .upowerEarlyAccess
                : .upowerExclusive
            return BilibiliVideoAccess(
                state: state,
                toast: toast,
                privilegeType: privilegeType,
                jumpURL: jumpURL,
                isPartial: !flexibleFlag(player["is_upower_play"])
            )
        }
        if flexibleFlag(player["is_ugc_pay_preview"]) {
            return BilibiliVideoAccess(
                state: .paidPreview,
                toast: toast,
                privilegeType: nil,
                jumpURL: nil
            )
        }
        if flexibleFlag(player["need_login_subtitle"]) {
            return BilibiliVideoAccess(
                state: .loginRequired,
                toast: toast,
                privilegeType: nil,
                jumpURL: nil
            )
        }
        return BilibiliVideoAccess(
            state: .open, toast: toast, privilegeType: nil, jumpURL: nil, isPartial: false)
    }

    /// 动态流的视频卡在入库前已经返回付费类型。这里做内容类型识别，不判断当前账号
    /// 是否已购买；完整播放权限会在转录时由 player/wbi/v2 再精确覆盖。
    static func dynamicVideoAccess(from archive: [String: Any]) -> BilibiliVideoAccess? {
        let badgeText: String? = {
            if let value = archive["elec_arc_badge"] as? String, !value.isEmpty { return value }
            if let badge = archive["badge"] as? [String: Any],
               let value = badge["text"] as? String, !value.isEmpty { return value }
            if let value = archive["badge"] as? String, !value.isEmpty { return value }
            return nil
        }()
        let chargingType = flexibleInt(archive["elec_arc_type"]) ?? 0
        if flexibleFlag(archive["is_charging_arc"]) || chargingType > 0 {
            let state: BilibiliAccessState = chargingType == 2 || badgeText?.contains("抢先") == true
                ? .upowerEarlyAccess
                : .upowerExclusive
            let level = (archive["charging_pay"] as? [String: Any])
                .flatMap { flexibleInt($0["level"]) }
            return BilibiliVideoAccess(
                state: state,
                toast: badgeText,
                privilegeType: level,
                jumpURL: nil,
                isPartial: false
            )
        }

        let rights = archive["rights"] as? [String: Any] ?? [:]
        let isPaidSeason = flexibleFlag(archive["is_chargeable_season"])
            || ((archive["ugc_season"] as? [String: Any])
                .map { flexibleFlag($0["is_pay_season"]) } ?? false)
        if isPaidSeason {
            return BilibiliVideoAccess(
                state: .paidSeason,
                toast: badgeText,
                privilegeType: nil,
                jumpURL: nil,
                isPartial: false
            )
        }

        let isUGCPaid = flexibleFlag(archive["is_ugcpay"])
            || (flexibleInt(archive["ugc_pay"]) ?? 0) > 0
            || (flexibleInt(archive["ugc_pay_preview"]) ?? 0) > 0
            || (flexibleInt(rights["ugc_pay"]) ?? 0) > 0
            || (flexibleInt(rights["ugc_pay_preview"]) ?? 0) > 0
        if isUGCPaid {
            return BilibiliVideoAccess(
                state: .paidPreview,
                toast: badgeText,
                privilegeType: nil,
                jumpURL: nil,
                isPartial: false
            )
        }
        return nil
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

    static func firstAuthorName(in items: [[String: Any]]) -> String? {
        items.lazy.compactMap { item -> String? in
            guard let modules = item["modules"] as? [String: Any],
                  let moduleAuthor = modules["module_author"] as? [String: Any],
                  let rawName = moduleAuthor["name"] as? String else { return nil }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }.first
    }

    /// 从动态流 items 中解析视频卡(MAJOR_TYPE_ARCHIVE)
    static func parseVideoCard(_ item: [String: Any]) -> ParsedEntry? {
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

        // 作者与发布时间位于 module_author。旧响应偶尔在 archive.pubdate
        // 返回时间戳，因此保留它作为兼容回退。
        let moduleAuthor = modules["module_author"] as? [String: Any]
        let author = moduleAuthor?["name"] as? String

        // 发布时间
        let published: Date? = {
            guard let timestamp = unixTimestamp(moduleAuthor?["pub_ts"])
                    ?? unixTimestamp(archive["pubdate"]) else { return nil }
            return Date(timeIntervalSince1970: timestamp)
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
        if let access = dynamicVideoAccess(from: archive) {
            meta["bilibili_access_state"] = access.state.rawValue
            meta["bilibili_access_label"] = access.state.listLabel
            meta["bilibili_access_toast"] = access.toast
            if let privilegeType = access.privilegeType {
                meta["bilibili_access_privilege_type"] = String(privilegeType)
            }
            meta["bilibili_access_source"] = "dynamic_card"
            meta["bilibili_access_checked_at"] = ISO8601DateFormatter().string(from: Date())
        }

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

    private static func unixTimestamp(_ value: Any?) -> TimeInterval? {
        switch value {
        case let value as Int:
            return TimeInterval(value)
        case let value as Int64:
            return TimeInterval(value)
        case let value as Double:
            return value
        case let value as String:
            return TimeInterval(value)
        default:
            return nil
        }
    }

    private static func flexibleFlag(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.intValue != 0 }
        if let value = value as? String {
            return value == "1" || value.lowercased() == "true"
        }
        return false
    }

    private static func flexibleInt(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
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
        if let cached = await deviceIdentityStore.current(maxAge: 3_600) {
            return cached
        }
        let data = try await httpGet("https://api.bilibili.com/x/frontend/finger/spi", cookie: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? Int, code == 0,
              let dataObj = json["data"] as? [String: Any],
              let buvid3 = dataObj["b_3"] as? String else {
            throw BilibiliError.buvid3Failed
        }
        await deviceIdentityStore.store(buvid3)
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

    private static func httpGet(_ request: URLRequest) async throws -> Data {
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
