import CryptoKit
import Foundation
import ReadBoardContract

public final class LocalInboxGateway: InboxGateway, @unchecked Sendable {
    private enum Keys {
        static let configuration = "inbox.configuration.v1"
    }

    private struct ResolvedLink: Sendable {
        let canonicalURL: String
        let kind: InboxContentKind
        var source: String
        let title: String
        let author: String?
        let imageURL: String?
        let mediaURL: String?
        let videoID: String?
        let language: String?
        let excerpt: String?
    }

    private let db: Database
    private let defaults: UserDefaults

    init(database: Database = .shared, defaults: UserDefaults = .standard) {
        db = database
        self.defaults = defaults
    }

    public func configuration() async throws -> InboxConfiguration {
        storedConfiguration()
    }

    public func updateConfiguration(_ configuration: InboxConfiguration) async throws {
        guard let data = try? JSONEncoder().encode(configuration) else {
            throw InboxGatewayError.importFailed("无法保存收件箱设置")
        }
        defaults.set(data, forKey: Keys.configuration)
    }

    public func importURL(_ request: InboxImportRequest) async throws -> InboxImportResult {
        let normalized = try Self.normalizedURL(request.url)
        let resolved = await Self.resolve(normalized, suggestedKind: request.suggestedKind)
        let configuration = storedConfiguration()
        let targets = configuration.targets(for: resolved.kind)
        let markUnread = configuration.markNewItemsUnread
        let record = try await Task.detached(priority: .userInitiated) { [self] in
            try persist(resolved, requestID: request.requestID, targets: targets,
                        markUnread: markUnread,
                        allowAutomaticExport: configuration.allowAutomaticExport)
        }.value

        guard record.created else {
            return InboxImportResult(
                requestID: request.requestID, contentID: record.id,
                disposition: .existing, kind: record.kind, title: record.title,
                message: "该链接已经在资料库中")
        }

        if record.isDuplicate {
            return InboxImportResult(
                requestID: request.requestID, contentID: record.id,
                disposition: .existing, kind: resolved.kind, title: resolved.title,
                message: "该内容已经在资料库中")
        }

        if targets.fulltext {
            await fetchBody(contentID: record.id, link: resolved)
        }
        await MainActor.run {
            PipelineWorker.shared.requestPendingRefresh()
            PipelineWorker.shared.requestFullTextRecovery()
        }
        await ExportService.shared.runPending(trigger: "ingest", contentId: record.id)
        await ExportService.shared.runPending(trigger: "ready", contentId: record.id)
        NotificationCenter.default.post(name: .contentUpdated, object: nil)

        return InboxImportResult(
            requestID: request.requestID, contentID: record.id,
            disposition: .created, kind: resolved.kind, title: resolved.title,
            message: "已添加到收件箱")
    }

    public func applyCurrentTargetsToExistingItems() async throws -> InboxRetargetResult {
        let value = storedConfiguration()
        guard db.open() else { throw InboxGatewayError.storageUnavailable }
        let affected = await Task.detached(priority: .utility) { [self] in
            let ok = db.transaction {
                updateExisting(kindSQL: "ctype NOT IN ('podcast','video','youtube')",
                               targets: value.articleTargets,
                               allowAutomaticExport: value.allowAutomaticExport)
                && updateExisting(kindSQL: "ctype='podcast'", targets: value.podcastTargets,
                                  allowAutomaticExport: value.allowAutomaticExport)
                && updateExisting(kindSQL: "ctype IN ('video','youtube')", targets: value.videoTargets,
                                  allowAutomaticExport: value.allowAutomaticExport)
            }
            return ok ? db.scalarInt(
                "SELECT COUNT(*) FROM content WHERE ingest_origin='inbox' AND deleted_at IS NULL") ?? 0 : -1
        }.value
        guard affected >= 0 else { throw InboxGatewayError.importFailed("更新历史收件箱目标失败") }
        await MainActor.run {
            PipelineWorker.shared.requestPendingRefresh()
            PipelineWorker.shared.requestFullTextRecovery()
        }
        NotificationCenter.default.post(name: .contentUpdated, object: nil)
        return InboxRetargetResult(
            affectedCount: affected,
            message: affected == 0 ? "收件箱暂无历史内容" : "已更新 \(affected) 条收件箱内容的处理目标")
    }

    private func storedConfiguration() -> InboxConfiguration {
        guard let data = defaults.data(forKey: Keys.configuration),
              let value = try? JSONDecoder().decode(InboxConfiguration.self, from: data)
        else { return InboxConfiguration() }
        return value
    }

    private func updateExisting(
        kindSQL: String,
        targets: InboxProcessingTargets,
        allowAutomaticExport: Bool
    ) -> Bool {
        db.execute("""
            UPDATE content
            SET auto_score=?, auto_summarize=?, auto_translate=?, auto_transcribe=?,
                meta=json_set(
                    CASE WHEN json_valid(meta) THEN meta ELSE '{}' END,
                    '$.inbox_fulltext_target', ?,
                    '$.inbox_allow_export', ?
                ),
                updated_at=datetime('now')
            WHERE ingest_origin='inbox' AND deleted_at IS NULL AND \(kindSQL)
            """, params: [targets.score ? 1 : 0, targets.summary ? 1 : 0,
                           targets.translate ? 1 : 0, targets.transcribe ? 1 : 0,
                           targets.fulltext ? "true" : "false",
                           allowAutomaticExport ? "true" : "false"])
    }

    private func persist(
        _ link: ResolvedLink,
        requestID: String,
        targets: InboxProcessingTargets,
        markUnread: Bool,
        allowAutomaticExport: Bool
    ) throws -> (id: Int64, title: String, kind: InboxContentKind, created: Bool, isDuplicate: Bool) {
        guard db.open() else { throw InboxGatewayError.storageUnavailable }
        if let existing = existingRecord(requestID: requestID, url: link.canonicalURL) {
            return (existing.id, existing.title, existing.kind, false, false)
        }

        var metadata: [String: String] = [
            "ingest_method": "share",
            "canonical_url": link.canonicalURL,
            "inbox_fulltext_target": targets.fulltext ? "true" : "false",
            "inbox_allow_export": allowAutomaticExport ? "true" : "false"
        ]
        if let imageURL = link.imageURL { metadata["image_url"] = imageURL }
        if let mediaURL = link.mediaURL {
            metadata[link.kind == .podcast ? "audio_url" : "video_url"] = mediaURL
        }
        if let videoID = link.videoID { metadata["video_id"] = videoID }
        let meta = (try? JSONSerialization.data(withJSONObject: metadata))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let guid = "inbox:" + SHA256.hash(data: Data(link.canonicalURL.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let hash = SHA256.hash(data: Data(link.canonicalURL.utf8))
            .map { String(format: "%02x", $0) }.joined()
        var isDuplicate = 0
        var duplicateOf: Int64?
        if let existing = db.queryRows("""
            SELECT id FROM content
            WHERE content_hash=? AND is_duplicate=0 AND deleted_at IS NULL LIMIT 1
            """, params: [hash]).first.flatMap({ Int64($0["id"] ?? "") }) {
            isDuplicate = 1
            duplicateOf = existing
        }
        var newID: Int64?
        let inserted = db.transaction {
            guard db.execute("""
                INSERT INTO content
                    (ctype, guid, source, source_id, title, author, url, language,
                     published_at, fetch_status, meta, content_hash, is_duplicate, duplicate_of,
                     auto_score, auto_translate, auto_summarize, auto_transcribe,
                     visibility_state, ingest_origin, ingest_request_id, first_image_url,
                     excerpt, read_at)
                VALUES (?, ?, ?, NULL, ?, ?, ?, ?, datetime('now'), 0, ?, ?, ?, ?,
                        ?, ?, ?, ?, 'visible', 'inbox', ?, ?, ?, ?)
                """, params: [link.kind.rawValue, guid, link.source, link.title,
                               link.author, link.canonicalURL, link.language, meta, hash,
                               isDuplicate, duplicateOf,
                               targets.score ? 1 : 0, targets.translate ? 1 : 0,
                               targets.summary ? 1 : 0, targets.transcribe ? 1 : 0,
                               requestID, link.imageURL, link.excerpt,
                               markUnread ? nil : ISO8601DateFormatter().string(from: Date())]) else { return false }
            newID = db.lastInsertId()
            return true
        }
        if !inserted {
            if let existing = existingRecord(requestID: requestID, url: link.canonicalURL) {
                return (existing.id, existing.title, existing.kind, false, false)
            }
            throw InboxGatewayError.importFailed("链接写入收件箱失败")
        }
        guard let newID else { throw InboxGatewayError.importFailed("链接写入收件箱失败") }
        if isDuplicate == 1, let duplicateOf {
            db.execute("DELETE FROM content WHERE id=?", params: [newID])
            if let row = db.queryRows("SELECT title, ctype FROM content WHERE id=?", params: [duplicateOf]).first {
                return (duplicateOf, row["title"] ?? link.title,
                        InboxContentKind(rawValue: row["ctype"] ?? "") ?? link.kind,
                        true, true)
            }
        }
        FilterService.shared.applyRules(
            contentId: newID, sourceId: nil, title: link.title,
            content: link.excerpt ?? "", author: link.author ?? "", url: link.canonicalURL)
        return (newID, link.title, link.kind, true, false)
    }

    private func existingRecord(
        requestID: String, url: String
    ) -> (id: Int64, title: String, kind: InboxContentKind)? {
        guard let row = db.queryRows("""
            SELECT id, title, ctype FROM content
            WHERE deleted_at IS NULL AND (ingest_request_id=? OR url=?)
            ORDER BY CASE WHEN ingest_request_id=? THEN 0 ELSE 1 END, id LIMIT 1
            """, params: [requestID, url, requestID]).first,
              let id = Int64(row["id"] ?? "") else { return nil }
        return (id, row["title"] ?? url,
                InboxContentKind(rawValue: row["ctype"] ?? "") ?? .article)
    }

    private func fetchBody(contentID: Int64, link: ResolvedLink) async {
        let mode: FetchMode = switch link.source {
        case "youtube": .youtubeSubtitle
        case "bilibili": .bilibiliSubtitle
        case "podcast" where link.mediaURL != nil: .summary
        default: .defuddle
        }
        _ = await FullTextFetcher.shared.fetchAndStore(
            contentId: contentID, url: link.canonicalURL, feedHtml: link.excerpt, mode: mode)
    }

    private static func normalizedURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), components.host != nil else {
            throw InboxGatewayError.invalidURL
        }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.fragment = nil
        let trackingNames = ["utm_source", "utm_medium", "utm_campaign", "utm_term",
                             "utm_content", "utm_id", "spm_id_from", "from", "feature", "si"]
        components.queryItems = components.queryItems?.filter {
            !trackingNames.contains($0.name.lowercased())
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        guard let value = components.url else { throw InboxGatewayError.invalidURL }
        return value
    }

    private static func resolve(
        _ url: URL, suggestedKind: InboxContentKind
    ) async -> ResolvedLink {
        let host = url.host?.lowercased() ?? ""
        var source: String
        let inferred: InboxContentKind
        if host == "youtu.be" || host.contains("youtube.com") {
            source = "youtube"; inferred = .video
        } else if host == "b23.tv" || host.contains("bilibili.com") {
            source = "bilibili"; inferred = .video
        } else if isPodcastHost(host) || isAudioURL(url) {
            source = "podcast"; inferred = .podcast
        } else if isVideoURL(url) {
            source = "video"; inferred = .video
        } else {
            source = "web"; inferred = .article
        }
        let kind = suggestedKind == .automatic ? inferred : suggestedKind
        if kind == .podcast, inferred != .video { source = "podcast" }
        if kind == .video, inferred != .video { source = "video" }
        // 直链媒体不读取响应体，避免一次“识别”就下载整段音视频。
        let isDirectMedia = isAudioURL(url) || isVideoURL(url)
        let metadata = isDirectMedia ? PageMetadata() : await fetchMetadata(url)
        let canonicalURL: String = {
            guard let raw = metadata.canonicalURL,
                  let candidate = URL(string: raw, relativeTo: url)?.absoluteURL,
                  let normalized = try? normalizedURL(candidate.absoluteString)
            else { return url.absoluteString }
            return normalized.absoluteString
        }()
        return ResolvedLink(
            canonicalURL: canonicalURL, kind: kind,
            source: source, title: metadata.title ?? fallbackTitle(url),
            author: metadata.author, imageURL: metadata.imageURL,
            mediaURL: metadata.mediaURL ?? (isDirectMedia ? url.absoluteString : nil),
            videoID: videoID(url: url, source: source), language: metadata.language,
            excerpt: metadata.excerpt)
    }

    private static func isPodcastHost(_ host: String) -> Bool {
        ["podcasts.apple.com", "xiaoyuzhoufm.com", "spotify.com", "podbean.com",
         "buzzsprout.com", "soundcloud.com"].contains { host.contains($0) }
    }

    private static func isAudioURL(_ url: URL) -> Bool {
        ["mp3", "m4a", "aac", "wav", "ogg", "opus"].contains(url.pathExtension.lowercased())
    }

    private static func isVideoURL(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov", "webm", "mkv"].contains(url.pathExtension.lowercased())
    }

    private static func videoID(url: URL, source: String) -> String? {
        if source == "youtube" {
            if url.host?.contains("youtu.be") == true {
                return url.pathComponents.dropFirst().first
            }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value
        }
        if source == "bilibili",
           let match = url.absoluteString.range(of: "BV[0-9A-Za-z]+", options: .regularExpression) {
            return String(url.absoluteString[match])
        }
        return nil
    }

    private static func fallbackTitle(_ url: URL) -> String {
        let last = url.deletingPathExtension().lastPathComponent
            .removingPercentEncoding?.replacingOccurrences(of: "-", with: " ") ?? ""
        return last.isEmpty ? (url.host ?? url.absoluteString) : last
    }

    private struct PageMetadata: Sendable {
        var title: String?
        var author: String?
        var imageURL: String?
        var mediaURL: String?
        var language: String?
        var canonicalURL: String?
        var excerpt: String?
    }

    private static func fetchMetadata(_ url: URL) async -> PageMetadata {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<400).contains($0.statusCode) }) == true,
              let html = String(data: data.prefix(1_500_000), encoding: .utf8) else {
            return PageMetadata()
        }
        func meta(_ keys: [String]) -> String? {
            for key in keys {
                let escaped = NSRegularExpression.escapedPattern(for: key)
                for pattern in [
                    "<meta[^>]+(?:property|name)=[\\\"']\(escaped)[\\\"'][^>]+content=[\\\"']([^\\\"']+)",
                    "<meta[^>]+content=[\\\"']([^\\\"']+)[\\\"'][^>]+(?:property|name)=[\\\"']\(escaped)[\\\"']"
                ] {
                    if let value = capture(pattern, in: html) { return decodeHTMLEntities(value) }
                }
            }
            return nil
        }
        let title = meta(["og:title", "twitter:title"])
            ?? capture("<title[^>]*>(.*?)</title>", in: html).map(decodeHTMLEntities)
        return PageMetadata(
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
            author: meta(["author", "article:author"]),
            imageURL: meta(["og:image", "twitter:image"]),
            mediaURL: meta(["og:audio", "og:audio:url", "twitter:player:stream"]),
            language: capture("<html[^>]+lang=[\\\"']([^\\\"']+)", in: html),
            canonicalURL: capture("<link[^>]+rel=[\\\"']canonical[\\\"'][^>]+href=[\\\"']([^\\\"']+)", in: html),
            excerpt: meta(["og:description", "twitter:description", "description"]))
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
