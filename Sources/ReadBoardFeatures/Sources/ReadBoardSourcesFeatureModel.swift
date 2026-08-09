import Foundation
import Observation
import ReadBoardContract

/// Core 与 Go 共用的订阅管理状态机。界面只调用 Contract gateway，刷新、写回、
/// 错误呈现和跨阅读器快照失效都在这里收口。
@MainActor
@Observable
public final class ReadBoardSourcesFeatureModel {
    public private(set) var snapshot: SourceCatalogSnapshot?
    public private(set) var syncSettings = SourceSyncSettings(
        enabled: false,
        intervalMinutes: 15)
    public private(set) var isLoading = false
    public private(set) var activeOperations: Set<String> = []
    public private(set) var statusMessage: String?
    public private(set) var errorMessage: String?

    private let environment: ReadBoardFeatureEnvironment

    public init(environment: ReadBoardFeatureEnvironment) {
        self.environment = environment
    }

    public var permissions: ReadBoardFeaturePermissions { environment.permissions }

    public func isWorking(_ key: String) -> Bool { activeOperations.contains(key) }

    public func clearStatus() { statusMessage = nil }
    public func clearError() { errorMessage = nil }
    public func presentExternalError(_ message: String) { errorMessage = message }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        async let catalogRequest = environment.sourceCatalog.snapshot()
        let settings = await environment.sourceManagement.syncSettings()
        do {
            snapshot = try await catalogRequest
            syncSettings = settings
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func syncAll() async {
        await maintenance(key: "sync:all") {
            try await self.environment.sourceManagement.syncAll()
        }
    }

    public func createFolder(name: String) async {
        await maintenance(key: "folder:create") {
            try await self.environment.sourceManagement.createFolder(name: name)
        }
    }

    public func sync(scope: SourceScope) async {
        await maintenance(key: operationKey("sync", scope)) {
            try await self.environment.sourceManagement.sync(scope: scope)
        }
    }

    public func rename(scope: SourceScope, name: String) async {
        await maintenance(key: operationKey("rename", scope)) {
            try await self.environment.sourceManagement.rename(scope: scope, name: name)
        }
    }

    public func remove(scope: SourceScope) async {
        await maintenance(key: operationKey("remove", scope)) {
            try await self.environment.sourceManagement.remove(scope: scope)
        }
    }

    public func assignSource(sourceID: Int64, folderID: Int64?) async {
        await setting(key: "assign:\(sourceID)", message: "分组已更新") {
            try await self.environment.sourceManagement.assignSource(
                sourceID: sourceID,
                folderID: folderID)
        }
    }

    public func setPolicy(
        scope: SourceScope,
        key: SourcePolicyKey,
        enabled: Bool,
        backfillHistory: Bool = false
    ) async {
        await setting(
            key: "policy:\(scope.kind.rawValue):\(scope.id):\(key.rawValue)",
            message: backfillHistory ? "处理策略已更新，历史内容已加入队列" : "处理策略已更新"
        ) {
            try await self.environment.sourceManagement.setPolicy(
                scope: scope,
                key: key,
                enabled: enabled)
            if enabled, backfillHistory {
                _ = try await self.environment.sourceManagement.backfillProcessing(
                    scope: scope,
                    key: key)
            }
        }
    }

    public func setFetchMode(scope: SourceScope, mode: SourceFetchMode) async {
        await setting(key: operationKey("mode", scope), message: "全文模式已更新") {
            try await self.environment.sourceManagement.setFetchMode(scope: scope, mode: mode)
        }
    }

    public func redetectFetchMode(scope: SourceScope) async {
        await setting(key: operationKey("detect", scope), message: "全文模式已重新检测") {
            try await self.environment.sourceManagement.redetectFetchMode(scope: scope)
        }
    }

    public func setFetchInterval(scope: SourceScope, minutes: Int) async {
        await setting(key: operationKey("interval", scope), message: "抓取频率已更新") {
            try await self.environment.sourceManagement.setFetchInterval(
                scope: scope,
                minutes: minutes)
        }
    }

    public func setEnabled(sourceID: Int64, enabled: Bool) async {
        await setting(key: "enabled:\(sourceID)", message: enabled ? "订阅源已启用" : "订阅源已停用") {
            try await self.environment.sourceManagement.setEnabled(
                sourceID: sourceID,
                enabled: enabled)
        }
    }

    public func setMaximumRetainedContent(sourceID: Int64, count: Int) async {
        await setting(key: "retention:\(sourceID)", message: "保留数量已更新") {
            try await self.environment.sourceManagement.setMaximumRetainedContent(
                sourceID: sourceID,
                count: count)
        }
    }

    public func refetchFulltext(scope: SourceScope, fullHistory: Bool) async {
        await maintenance(key: operationKey("fulltext", scope)) {
            try await self.environment.sourceManagement.refetchFulltext(
                scope: scope,
                fullHistory: fullHistory)
        }
    }

    public func updateSyncSettings(enabled: Bool, intervalMinutes: Int) async {
        await setting(key: "sync:settings", message: "自动刷新设置已更新") {
            try await self.environment.sourceManagement.updateSyncSettings(
                SourceSyncSettings(enabled: enabled, intervalMinutes: intervalMinutes))
        }
    }

    public func createSource(_ request: SourceCreationRequest) async -> Bool {
        await valueOperation(key: "source:create") {
            let result = try await self.environment.sourceOnboarding.create(request: request)
            return result.message
        }
    }

    public func importSources(
        _ items: [SourceBatchImportItem],
        refreshAfterCreation: Bool
    ) async -> Bool {
        await valueOperation(key: "source:import") {
            let result = try await self.environment.sourceOnboarding.importSources(
                items: items,
                refreshAfterCreation: refreshAfterCreation)
            return result.message
        }
    }

    public func discover(
        identifier: String,
        suggestedType: String?
    ) async throws -> SourceDiscoveryResult {
        try await environment.sourceOnboarding.discover(
            identifier: identifier,
            suggestedType: suggestedType)
    }

    public func supportedSourceTypes() async -> [SourceTypeDescriptor] {
        await environment.sourceOnboarding.supportedSourceTypes()
    }

    public func exportedOPML() async -> String {
        await environment.sourceOnboarding.exportOPML()
    }

    private func maintenance(
        key: String,
        operation: () async throws -> SourceMaintenanceResult
    ) async {
        guard begin(key) else { return }
        defer { finish(key) }
        do {
            let result = try await operation()
            statusMessage = result.message
            await refreshAfterMutation()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setting(
        key: String,
        message: String,
        operation: () async throws -> Void
    ) async {
        guard begin(key) else { return }
        defer { finish(key) }
        do {
            try await operation()
            statusMessage = message
            await refreshAfterMutation()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func valueOperation(
        key: String,
        operation: () async throws -> String
    ) async -> Bool {
        guard begin(key) else { return false }
        defer { finish(key) }
        do {
            statusMessage = try await operation()
            await refreshAfterMutation()
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func begin(_ key: String) -> Bool {
        guard !activeOperations.contains(key) else { return false }
        activeOperations.insert(key)
        errorMessage = nil
        return true
    }

    private func finish(_ key: String) {
        activeOperations.remove(key)
    }

    private func refreshAfterMutation() async {
        do {
            snapshot = try await environment.sourceCatalog.snapshot()
            syncSettings = await environment.sourceManagement.syncSettings()
            NotificationCenter.default.post(
                name: .readBoardLibrarySnapshotChanged,
                object: nil)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func operationKey(_ action: String, _ scope: SourceScope) -> String {
        "\(action):\(scope.kind.rawValue):\(scope.id)"
    }
}
