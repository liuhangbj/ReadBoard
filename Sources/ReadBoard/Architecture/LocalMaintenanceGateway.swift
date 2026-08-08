import Foundation
import ReadBoardContract

@MainActor
public final class LocalMaintenanceGateway: MaintenanceGateway, @unchecked Sendable {
    public nonisolated init() {}

    public func snapshot() async -> MaintenanceSnapshot {
        let cleanup = CacheCleanupService.shared
        cleanup.refreshStats()
        return MaintenanceSnapshot(
            policy: CleanupPolicy(deleteReadEnabled: cleanup.deleteEnabled,
                deleteReadAfterDays: cleanup.deleteAfterDays,
                backupRetentionEnabled: cleanup.backupKeepEnabled,
                backupKeepCount: cleanup.backupKeepCount,
                cleanHTML: cleanup.cleanContentHtml,
                cleanHTMLAfterDays: cleanup.cleanHtmlAfterDays),
            usage: StorageUsage(databaseBytes: cleanup.dbBytes, backupBytes: cleanup.backupBytes,
                backupCount: cleanup.backupCount, temporaryBytes: cleanup.tempBytes,
                temporaryCount: cleanup.tempCount, cleanableHTMLCount: cleanup.contentHtmlCount,
                trashBytes: cleanup.trashBytesPublished),
            backups: BackupService.shared.listBackups().map {
                BackupRecord(id: $0.path, date: $0.date, sizeBytes: $0.sizeBytes, displayName: $0.displayName)
            },
            trash: cleanup.listTrash().map {
                TrashBatchRecord(id: $0.path, date: $0.date, itemCount: $0.itemCount, sizeBytes: $0.sizeBytes)
            },
            lastCleanupSummary: cleanup.lastRunSummary,
            lastBackupAt: BackupService.shared.lastBackupAt,
            lastBackupError: BackupService.shared.lastBackupError)
    }

    public func updatePolicy(_ policy: CleanupPolicy) async {
        let cleanup = CacheCleanupService.shared
        cleanup.deleteEnabled = policy.deleteReadEnabled
        cleanup.deleteAfterDays = min(max(policy.deleteReadAfterDays, 0), 3650)
        cleanup.backupKeepEnabled = policy.backupRetentionEnabled
        cleanup.backupKeepCount = min(max(policy.backupKeepCount, 1), 100)
        cleanup.cleanContentHtml = policy.cleanHTML
        cleanup.cleanHtmlAfterDays = min(max(policy.cleanHTMLAfterDays, 1), 3650)
    }

    public func runCleanup() async -> String { await CacheCleanupService.shared.runAll() }

    public func createBackup() async -> MaintenanceSnapshot {
        await BackupService.shared.backupNow()
        return await snapshot()
    }

    public func restoreBackup(id: String) async throws {
        guard BackupService.shared.listBackups().contains(where: { $0.path == id }) else {
            throw MaintenanceError.unknownBackup
        }
        try BackupService.shared.restore(from: id)
    }

    public func restoreTrash(id: String) async -> TrashRestoreResult {
        let cleanup = CacheCleanupService.shared
        guard let batch = cleanup.listTrash().first(where: { $0.path == id }) else {
            return TrashRestoreResult(restored: 0, skipped: 0)
        }
        let result = cleanup.restoreTrash(batch: batch)
        if result.restored + result.skipped > 0 { cleanup.deleteTrash(batch: batch) }
        return TrashRestoreResult(restored: result.restored, skipped: result.skipped)
    }

    public func deleteTrash(id: String) async {
        let cleanup = CacheCleanupService.shared
        guard let batch = cleanup.listTrash().first(where: { $0.path == id }) else { return }
        cleanup.deleteTrash(batch: batch)
    }

    public func clearTrash() async { CacheCleanupService.shared.clearAllTrash() }
}

private enum MaintenanceError: LocalizedError {
    case unknownBackup
    var errorDescription: String? { "备份不存在或已被移除" }
}
