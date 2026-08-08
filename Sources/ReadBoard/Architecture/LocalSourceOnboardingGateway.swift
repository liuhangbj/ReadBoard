import Foundation
import ReadBoardContract

public final class LocalSourceOnboardingGateway: SourceOnboardingGateway, @unchecked Sendable {
    public init() {}

    public func exportOPML() async -> String {
        await Task.detached { OPMLService.shared.exportOPML() }.value
    }

    public func supportedSourceTypes() async -> [SourceTypeDescriptor] {
        let builtin = [
            SourceTypeDescriptor(id: "article", displayName: "RSS 文章"),
            SourceTypeDescriptor(id: "podcast", displayName: "播客"),
            SourceTypeDescriptor(id: "youtube", displayName: "YouTube"),
            SourceTypeDescriptor(id: "bilibili", displayName: "BiliBili")
        ]
        let connectors = await MainActor.run {
            ReadBoardSourceConnectorRegistry.shared.connectorsSupportingAddSource()
        }
        let external = connectors
            .map { SourceTypeDescriptor(id: $0.sourceType, displayName: $0.displayName) }
        return builtin + external
    }

    public func discover(
        identifier: String,
        suggestedType: String?
    ) async throws -> SourceDiscoveryResult {
        let input = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw SourceOnboardingGatewayError.invalidIdentifier }

        let resolved = try await resolve(input: input, suggestedType: suggestedType)
        let storedType = resolved.sourceType == "article" ? "rss" : resolved.sourceType
        let mode: FetchMode
        let connector = await MainActor.run {
            ReadBoardSourceConnectorRegistry.shared.connector(for: storedType)
        }
        if let connector {
            mode = connector.fulltextMode
        } else if let platformMode = FetchMode.platformDefault(for: storedType) {
            mode = platformMode
        } else {
            mode = await FullTextFetcher.shared.probeMode(feedUrl: resolved.identifier)
        }
        let lookupIdentifier = storedType == "bilibili"
            ? (BilibiliFetcher.extractUID(from: resolved.identifier) ?? resolved.identifier)
            : resolved.identifier
        let existingID = Database.shared.scalarInt(
            "SELECT id FROM content_source WHERE identifier=? LIMIT 1",
            params: [lookupIdentifier]).map(Int64.init)
        return SourceDiscoveryResult(
            canonicalIdentifier: resolved.identifier,
            suggestedName: resolved.feed.title,
            sourceType: resolved.sourceType,
            previewItemCount: resolved.feed.entries.count,
            fetchMode: SourceFetchMode(rawValue: mode.rawValue) ?? .summary,
            fetchModeDisplayName: resolved.fulltextDisplayName ?? mode.displayName,
            existingSourceID: existingID)
    }

    public func create(request: SourceCreationRequest) async throws -> SourceCreationResult {
        let identifier = request.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !name.isEmpty else {
            throw SourceOnboardingGatewayError.invalidIdentifier
        }
        let normalizedIdentifier = request.sourceType == "bilibili"
            ? (BilibiliFetcher.extractUID(from: identifier) ?? identifier)
            : identifier
        let existingID = Database.shared.scalarInt(
            "SELECT id FROM content_source WHERE identifier=? LIMIT 1",
            params: [normalizedIdentifier]).map(Int64.init)
        if let existingID { throw SourceOnboardingGatewayError.duplicateSource(existingID) }

        let sourceID = await SourceStore.shared.addSource(
            stype: normalizedSourceType(request.sourceType),
            name: name,
            identifier: identifier,
            folderId: request.folderID,
            pipeline: makePolicy(request.policy),
            fetchMode: request.fetchMode.flatMap { FetchMode(rawValue: $0.rawValue) },
            historyScope: request.historyScope.flatMap { HistoryScope(rawValue: $0.rawValue) })
        guard let sourceID else {
            throw SourceOnboardingGatewayError.creationFailed("添加失败，可能已存在相同源")
        }

        var imported = 0
        if request.refreshAfterCreation,
           let source = await MainActor.run(body: {
               SourceStore.shared.sources.first { $0.id == sourceID }
           }) {
            imported = (try? await SourceStore.shared.syncOne(source)) ?? 0
        }
        return SourceCreationResult(
            sourceID: sourceID,
            importedContentCount: imported,
            message: request.refreshAfterCreation
                ? "已添加并刷新，新增 \(imported) 条内容"
                : "已添加订阅源")
    }

    public func importSources(
        items: [SourceBatchImportItem],
        refreshAfterCreation: Bool
    ) async throws -> SourceBatchImportResult {
        let localItems = items.map {
            OPMLImportItem(
                name: $0.name,
                url: $0.identifier,
                stype: $0.sourceType,
                fetchModeRaw: $0.fetchMode.rawValue,
                folderName: $0.folderName,
                inLibrary: false)
        }
        var policies: [String: PipelinePolicy] = [:]
        for item in items where policies[item.identifier] == nil {
            policies[item.identifier] = makePolicy(item.policy)
        }
        let sourceIDs = await MainActor.run {
            SourceStore.shared.commitImport(localItems, policies: policies)
        }
        var imported = 0
        if refreshAfterCreation {
            for sourceID in sourceIDs {
                if let source = await MainActor.run(body: {
                    SourceStore.shared.sources.first { $0.id == sourceID }
                }) {
                    imported += (try? await SourceStore.shared.syncOne(source)) ?? 0
                }
            }
        }
        let skipped = max(0, items.count - sourceIDs.count)
        return SourceBatchImportResult(
            createdSourceIDs: sourceIDs,
            skippedCount: skipped,
            importedContentCount: imported,
            message: refreshAfterCreation
                ? "已添加 \(sourceIDs.count) 项并完成首次刷新"
                : "已添加 \(sourceIDs.count) 项")
    }

    public func platformSubscriptions(
        platform: String
    ) async throws -> [PlatformSubscriptionCandidate] {
        guard platform == "bilibili" else {
            throw SourceOnboardingGatewayError.unsupportedSource("暂不支持该平台批量导入")
        }
        guard let sessdata = BilibiliAuth.sessdata, let uid = BilibiliAuth.uid else {
            throw SourceOnboardingGatewayError.authenticationRequired("未登录或登录态失效")
        }
        let followings: [(mid: String, uname: String)]
        do {
            followings = try await BilibiliAuth.fetchFollowings(sessdata: sessdata, uid: uid)
        } catch {
            throw SourceOnboardingGatewayError.discoveryFailed(error.localizedDescription)
        }
        let existing = await MainActor.run { Set(SourceStore.shared.sources.map(\.identifier)) }
        return followings.map {
            PlatformSubscriptionCandidate(
                id: $0.mid,
                name: $0.uname,
                identifier: "https://space.bilibili.com/\($0.mid)",
                alreadySubscribed: existing.contains($0.mid))
        }
    }

    private func resolve(
        input: String,
        suggestedType: String?
    ) async throws -> (
        identifier: String,
        feed: ParsedFeed,
        sourceType: String,
        fulltextDisplayName: String?
    ) {
        if isWeChatArticleURL(input) {
            let connectors = await MainActor.run {
                ReadBoardSourceConnectorRegistry.shared.connectorsSupportingAddSource()
            }
            for connector in connectors {
                guard let resolved = try await connector.resolveSourceIdentifier(input), !resolved.isEmpty else {
                    continue
                }
                let feed = try await connector.previewSource(identifier: resolved)
                return (resolved, feed, connector.sourceType, connector.fulltextDisplayName)
            }
            throw SourceOnboardingGatewayError.unsupportedSource(
                "请升级 Pro 版本支持微信公众号订阅")
        }
        if suggestedType == "youtube"
            || input.lowercased().contains("youtube.com")
            || input.lowercased().contains("youtu.be") {
            let url = try await YouTubeResolver.resolveFeedURL(input)
            return (url, try await FeedFetcher.fetch(urlString: url), "youtube", nil)
        }
        if suggestedType == "bilibili" || input.lowercased().contains("bilibili.com") {
            guard let uid = BilibiliFetcher.extractUID(from: input) else {
                throw SourceOnboardingGatewayError.invalidIdentifier
            }
            return (
                uid,
                try await BilibiliFetcher.fetch(uid: uid, historyScope: .recent30d),
                "bilibili",
                nil)
        }
        do {
            let result = try await FeedFetcher.discoverAndFetch(urlString: input)
            let type: String
            switch result.feed.kind {
            case .article: type = "article"
            case .podcast: type = "podcast"
            case .video: type = "youtube"
            }
            return (result.feedURL, result.feed, type, nil)
        } catch {
            throw SourceOnboardingGatewayError.discoveryFailed(error.localizedDescription)
        }
    }

    private func isWeChatArticleURL(_ input: String) -> Bool {
        guard let url = URL(string: input), let host = url.host?.lowercased() else { return false }
        return host == "mp.weixin.qq.com"
    }

    private func normalizedSourceType(_ type: String) -> String {
        type == "article" ? "rss" : type
    }

    private func makePolicy(_ snapshot: SourcePolicySnapshot) -> PipelinePolicy {
        PipelinePolicy(
            autoScore: snapshot.autoScore,
            autoTranslate: snapshot.autoTranslate,
            autoTranscribe: snapshot.autoTranscribe,
            autoSummarize: snapshot.autoSummarize)
    }
}
