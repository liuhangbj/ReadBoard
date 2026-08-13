import Foundation
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
        let job = try await submitBackfillProcessing(scope: scope, key: key)
        return SourceMaintenanceResult(message: job.message)
    }

    public func submitBackfillProcessing(
        scope: SourceScope,
        key: SourcePolicyKey?
    ) async throws -> SourceOperationJobSnapshot {
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
        return await SourceOperationJobCoordinator.shared.submit(
            kind: .processingBackfill,
            scope: scope)
    }

    public func submitSourceSync(scope: SourceScope?) async throws -> SourceOperationJobSnapshot {
        await SourceOperationJobCoordinator.shared.submit(kind: .sourceSync, scope: scope)
    }

    public func submitFulltextRefetch(
        scope: SourceScope,
        fullHistory: Bool
    ) async throws -> SourceOperationJobSnapshot {
        await SourceOperationJobCoordinator.shared.submit(
            kind: .fulltextRefetch,
            scope: scope,
            fullHistory: fullHistory)
    }

    public func sourceOperationStatus(id: String) async throws -> SourceOperationJobSnapshot {
        try await SourceOperationJobCoordinator.shared.status(id: id)
    }

    public func cancelSourceOperation(id: String) async {
        await SourceOperationJobCoordinator.shared.cancel(id: id)
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

    public func setMaximumRetainedContent(scope: SourceScope, count: Int) async throws {
        guard scope.id > 0, count >= 0 else { throw SourceManagementGatewayError.invalidRequest }
        await MainActor.run {
            switch scope.kind {
            case .source:
                SourceStore.shared.setMaxKeep(id: scope.id, count: count)
                if count > 0 { _ = SourceStore.shared.enforceMaxKeep(sourceId: scope.id) }
            case .folder:
                SourceStore.shared.setFolderMaxKeep(folderId: scope.id, count: count)
            }
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

private actor SourceOperationJobCoordinator {
    static let shared = SourceOperationJobCoordinator()

    private var snapshots: [String: SourceOperationJobSnapshot] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func submit(
        kind: SourceOperationJobKind,
        scope: SourceScope?,
        fullHistory: Bool = false
    ) -> SourceOperationJobSnapshot {
        let snapshot = SourceOperationJobSnapshot(
            kind: kind,
            scope: scope,
            phase: .queued,
            message: queuedMessage(kind))
        snapshots[snapshot.id] = snapshot
        tasks[snapshot.id] = Task { [weak self] in
            await self?.run(
                id: snapshot.id,
                kind: kind,
                scope: scope,
                fullHistory: fullHistory)
        }
        return snapshot
    }

    func status(id: String) async throws -> SourceOperationJobSnapshot {
        guard var snapshot = snapshots[id] else {
            throw SourceManagementGatewayError.operationFailed("长任务不存在或已过期")
        }
        if snapshot.phase == .running, snapshot.kind == .processingBackfill {
            let progressMessage = await MainActor.run { PipelineWorker.shared.backfillProgress }
            if !progressMessage.isEmpty {
                snapshot = copy(snapshot, message: progressMessage)
                snapshots[id] = snapshot
            }
        }
        return snapshot
    }

    func cancel(id: String) {
        guard let task = tasks[id], let snapshot = snapshots[id], !snapshot.phase.isTerminal else {
            return
        }
        task.cancel()
        snapshots[id] = copy(
            snapshot,
            phase: .cancelled,
            message: "任务已取消",
            finishedAt: Date().timeIntervalSince1970)
        tasks[id] = nil
    }

    private func run(
        id: String,
        kind: SourceOperationJobKind,
        scope: SourceScope?,
        fullHistory: Bool
    ) async {
        guard let queued = snapshots[id] else { return }
        snapshots[id] = copy(queued, phase: .running, message: runningMessage(kind))
        let result: SourceMaintenanceResult
        do {
            let gateway = LocalSourceManagementGateway()
            switch kind {
            case .processingBackfill:
                guard let scope else { throw SourceManagementGatewayError.invalidRequest }
                switch scope.kind {
                case .source:
                    await PipelineWorker.shared.backfillHistory(onlySourceId: scope.id)
                case .folder:
                    await PipelineWorker.shared.backfillHistoryForFolder(folderId: scope.id)
                }
                let message = await MainActor.run { PipelineWorker.shared.backfillProgress }
                result = SourceMaintenanceResult(
                    message: message.isEmpty ? "历史处理已完成" : message)
            case .sourceSync:
                if let scope {
                    result = try await gateway.sync(scope: scope)
                } else {
                    result = try await gateway.syncAll()
                }
            case .fulltextRefetch:
                guard let scope else { throw SourceManagementGatewayError.invalidRequest }
                result = try await gateway.refetchFulltext(
                    scope: scope,
                    fullHistory: fullHistory)
            }
        } catch {
            guard let running = snapshots[id], running.phase != .cancelled else { return }
            snapshots[id] = copy(
                running,
                phase: .failed,
                message: error.localizedDescription,
                finishedAt: Date().timeIntervalSince1970)
            tasks[id] = nil
            return
        }
        guard let running = snapshots[id], running.phase != .cancelled else { return }
        let wasCancelled = Task.isCancelled
        snapshots[id] = copy(
            running,
            phase: wasCancelled ? .cancelled : .succeeded,
            message: wasCancelled ? "任务已取消" : result.message,
            affectedCount: result.affectedCount,
            finishedAt: Date().timeIntervalSince1970)
        tasks[id] = nil
    }

    private func copy(
        _ value: SourceOperationJobSnapshot,
        phase: SourceOperationJobPhase? = nil,
        message: String? = nil,
        affectedCount: Int? = nil,
        finishedAt: TimeInterval? = nil
    ) -> SourceOperationJobSnapshot {
        SourceOperationJobSnapshot(
            id: value.id,
            kind: value.kind,
            scope: value.scope,
            phase: phase ?? value.phase,
            progress: value.progress,
            message: message ?? value.message,
            affectedCount: affectedCount ?? value.affectedCount,
            startedAt: value.startedAt,
            finishedAt: finishedAt ?? value.finishedAt)
    }

    private func queuedMessage(_ kind: SourceOperationJobKind) -> String {
        switch kind {
        case .processingBackfill: "历史处理已加入队列"
        case .sourceSync: "订阅源更新已加入队列"
        case .fulltextRefetch: "全文重新提取已加入队列"
        }
    }

    private func runningMessage(_ kind: SourceOperationJobKind) -> String {
        switch kind {
        case .processingBackfill: "正在处理历史内容…"
        case .sourceSync: "正在更新订阅源…"
        case .fulltextRefetch: "正在重新提取全文…"
        }
    }
}
