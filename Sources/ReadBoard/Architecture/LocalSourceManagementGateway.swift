import ReadBoardContract

public final class LocalSourceManagementGateway: SourceManagementGateway, @unchecked Sendable {
    public init() {}

    public func syncSettings() async -> SourceSyncSettings {
        await MainActor.run {
            SourceSyncSettings(
                enabled: SourceStore.shared.autoSyncEnabled,
                intervalMinutes: Int(SourceStore.shared.syncInterval / 60))
        }
    }

    public func updateSyncSettings(_ settings: SourceSyncSettings) async throws {
        guard settings.intervalMinutes > 0 else {
            throw SourceManagementGatewayError.invalidRequest
        }
        await MainActor.run {
            SourceStore.shared.autoSyncEnabled = settings.enabled
            SourceStore.shared.setSyncInterval(minutes: settings.intervalMinutes)
        }
    }

    public func createFolder(name: String) async throws -> SourceMaintenanceResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SourceManagementGatewayError.invalidRequest }
        let created = await MainActor.run { SourceStore.shared.addFolder(name: trimmed) }
        guard created else {
            throw SourceManagementGatewayError.operationFailed("文件夹已存在或创建失败")
        }
        return SourceMaintenanceResult(message: "已创建文件夹")
    }

    public func syncAll() async throws -> SourceMaintenanceResult {
        await SourceStore.shared.syncAll()
        let message = await MainActor.run { SourceStore.shared.lastSyncMessage }
        return SourceMaintenanceResult(message: message.isEmpty ? "刷新完成" : message)
    }

    public func rename(scope: SourceScope, name: String) async throws -> SourceMaintenanceResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard scope.id > 0, !trimmed.isEmpty else {
            throw SourceManagementGatewayError.invalidRequest
        }
        await MainActor.run {
            switch scope.kind {
            case .source: SourceStore.shared.renameSource(id: scope.id, name: trimmed)
            case .folder: SourceStore.shared.renameFolder(id: scope.id, name: trimmed)
            }
        }
        return SourceMaintenanceResult(message: "已重命名")
    }

    public func remove(scope: SourceScope) async throws -> SourceMaintenanceResult {
        guard scope.id > 0 else { throw SourceManagementGatewayError.invalidRequest }
        switch scope.kind {
        case .source:
            let count = await SourceStore.shared.removeSource(id: scope.id)
            return SourceMaintenanceResult(
                affectedCount: count,
                message: "已删除订阅源及其 \(count) 条内容")
        case .folder:
            await MainActor.run { SourceStore.shared.removeFolder(id: scope.id) }
            return SourceMaintenanceResult(message: "已删除文件夹")
        }
    }

    public func assignSource(sourceID: Int64, folderID: Int64?) async throws {
        guard sourceID > 0 else { throw SourceManagementGatewayError.invalidRequest }
        await MainActor.run {
            SourceStore.shared.assignSource(sourceId: sourceID, folderId: folderID)
        }
    }

    public func sync(scope: SourceScope) async throws -> SourceMaintenanceResult {
        let sources = await MainActor.run { matchingSources(scope) }
        guard !sources.isEmpty else {
            throw SourceManagementGatewayError.sourceNotFound(scope.id)
        }
        var imported = 0
        for source in sources where source.enabled {
            imported += try await SourceStore.shared.syncOne(source)
        }
        return SourceMaintenanceResult(
            affectedCount: imported,
            message: "刷新完成，新增 \(imported) 条")
    }

    public func setPolicy(
        scope: SourceScope,
        key: SourcePolicyKey,
        enabled: Bool
    ) async throws {
        await MainActor.run {
            switch scope.kind {
            case .source:
                SourceStore.shared.setPolicy(id: scope.id, key: key.rawValue, value: enabled)
            case .folder:
                SourceStore.shared.setFolderPolicy(id: scope.id, key: key.rawValue, value: enabled)
            }
        }
    }

    public func backfillProcessing(
        scope: SourceScope,
        key: SourcePolicyKey?
    ) async throws -> SourceMaintenanceResult {
        if let key {
            let enabled = await MainActor.run {
                switch scope.kind {
                case .source:
                    SourceStore.shared.setHistoricalItemsEnabled(
                        sourceId: scope.id, key: key.rawValue)
                case .folder:
                    SourceStore.shared.setHistoricalItemsEnabled(
                        folderId: scope.id, key: key.rawValue)
                }
            }
            guard enabled else {
                throw SourceManagementGatewayError.operationFailed("历史处理范围更新失败")
            }
        }
        switch scope.kind {
        case .source:
            await PipelineWorker.shared.backfillHistory(onlySourceId: scope.id)
        case .folder:
            await PipelineWorker.shared.backfillHistoryForFolder(folderId: scope.id)
        }
        return SourceMaintenanceResult(
            message: "历史处理已完成")
    }

    public func setFetchMode(scope: SourceScope, mode: SourceFetchMode) async throws {
        switch scope.kind {
        case .source:
            await SourceStore.shared.setFetchMode(id: scope.id, mode: mode.rawValue)
        case .folder:
            if mode == .automatic {
                await SourceStore.shared.setFolderFetchModeAuto(folderId: scope.id)
            } else {
                guard let localMode = FetchMode(rawValue: mode.rawValue) else {
                    throw SourceManagementGatewayError.invalidRequest
                }
                await MainActor.run {
                    SourceStore.shared.setFolderFetchMode(folderId: scope.id, mode: localMode)
                }
            }
        }
    }

    public func redetectFetchMode(scope: SourceScope) async throws {
        switch scope.kind {
        case .source: await SourceStore.shared.redetectFetchMode(id: scope.id)
        case .folder: await SourceStore.shared.redetectFolderFetchMode(folderId: scope.id)
        }
    }

    public func setFetchInterval(scope: SourceScope, minutes: Int) async throws {
        guard minutes > 0 else { throw SourceManagementGatewayError.invalidRequest }
        await MainActor.run {
            switch scope.kind {
            case .source:
                SourceStore.shared.setFetchInterval(id: scope.id, minutes: minutes)
            case .folder:
                SourceStore.shared.setFolderFetchInterval(folderId: scope.id, minutes: minutes)
            }
        }
    }

    public func setEnabled(sourceID: Int64, enabled: Bool) async throws {
        guard sourceID > 0 else { throw SourceManagementGatewayError.invalidRequest }
        await MainActor.run { SourceStore.shared.setEnabled(id: sourceID, enabled: enabled) }
    }

    public func setMaximumRetainedContent(sourceID: Int64, count: Int) async throws {
        guard sourceID > 0, count >= 0 else { throw SourceManagementGatewayError.invalidRequest }
        await MainActor.run {
            SourceStore.shared.setMaxKeep(id: sourceID, count: count)
            if count > 0 { _ = SourceStore.shared.enforceMaxKeep(sourceId: sourceID) }
        }
    }

    public func refetchFulltext(
        scope: SourceScope,
        fullHistory: Bool
    ) async throws -> SourceMaintenanceResult {
        if fullHistory {
            switch scope.kind {
            case .source:
                await FullTextFetcher.shared.refetchSourceFulltext(sourceId: scope.id)
            case .folder:
                await FullTextFetcher.shared.refetchFolderFulltext(folderId: scope.id)
            }
            return SourceMaintenanceResult(message: "全文重新提取完成")
        }
        let count: Int
        switch scope.kind {
        case .source:
            count = await PipelineWorker.shared.refetchFullTextForSource(onlySourceId: scope.id)
        case .folder:
            count = await PipelineWorker.shared.refetchFullTextForFolder(folderId: scope.id)
        }
        return SourceMaintenanceResult(
            affectedCount: count,
            message: "历史全文已重新提取 \(count) 条")
    }

    public func retryFulltext(contentID: Int64) async throws -> SourceMaintenanceResult {
        guard contentID > 0 else { throw SourceManagementGatewayError.invalidRequest }
        let success = await SourceStore.shared.retryExternalFulltext(contentId: contentID)
        guard success else {
            throw SourceManagementGatewayError.operationFailed("正文仍无法提取")
        }
        return SourceMaintenanceResult(affectedCount: 1, message: "正文补抓成功")
    }

    @MainActor
    private func matchingSources(_ scope: SourceScope) -> [FeedSource] {
        switch scope.kind {
        case .source:
            return SourceStore.shared.sources.filter { $0.id == scope.id }
        case .folder:
            return SourceStore.shared.sources.filter { $0.folderId == scope.id }
        }
    }
}
