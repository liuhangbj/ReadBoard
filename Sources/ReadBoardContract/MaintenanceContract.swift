import Foundation

public struct CleanupPolicy: Codable, Equatable, Sendable {
    public var deleteReadEnabled: Bool
    public var deleteReadAfterDays: Int
    public var backupRetentionEnabled: Bool
    public var backupKeepCount: Int
    public var cleanHTML: Bool
    public var cleanHTMLAfterDays: Int
    public init(deleteReadEnabled: Bool = true, deleteReadAfterDays: Int = 90,
                backupRetentionEnabled: Bool = true, backupKeepCount: Int = 5,
                cleanHTML: Bool = true, cleanHTMLAfterDays: Int = 7) {
        self.deleteReadEnabled = deleteReadEnabled; self.deleteReadAfterDays = deleteReadAfterDays
        self.backupRetentionEnabled = backupRetentionEnabled; self.backupKeepCount = backupKeepCount
        self.cleanHTML = cleanHTML; self.cleanHTMLAfterDays = cleanHTMLAfterDays
    }
}

public struct StorageUsage: Codable, Equatable, Sendable {
    public let databaseBytes: Int64
    public let backupBytes: Int64
    public let backupCount: Int
    public let temporaryBytes: Int64
    public let temporaryCount: Int
    public let cleanableHTMLCount: Int
    public let trashBytes: Int64
    public init(databaseBytes: Int64 = 0, backupBytes: Int64 = 0, backupCount: Int = 0,
                temporaryBytes: Int64 = 0, temporaryCount: Int = 0,
                cleanableHTMLCount: Int = 0, trashBytes: Int64 = 0) {
        self.databaseBytes = databaseBytes; self.backupBytes = backupBytes; self.backupCount = backupCount
        self.temporaryBytes = temporaryBytes; self.temporaryCount = temporaryCount
        self.cleanableHTMLCount = cleanableHTMLCount; self.trashBytes = trashBytes
    }
}

public struct BackupRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let date: Date
    public let sizeBytes: Int64
    public let displayName: String
    public init(id: String, date: Date, sizeBytes: Int64, displayName: String) {
        self.id = id; self.date = date; self.sizeBytes = sizeBytes; self.displayName = displayName
    }
}

public struct TrashBatchRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let date: String
    public let itemCount: Int
    public let sizeBytes: Int64
    public init(id: String, date: String, itemCount: Int, sizeBytes: Int64) {
        self.id = id; self.date = date; self.itemCount = itemCount; self.sizeBytes = sizeBytes
    }
}

public struct MaintenanceSnapshot: Codable, Equatable, Sendable {
    public let policy: CleanupPolicy
    public let usage: StorageUsage
    public let backups: [BackupRecord]
    public let trash: [TrashBatchRecord]
    public let lastCleanupSummary: String
    public let lastBackupAt: String?
    public let lastBackupError: String?
    public init(policy: CleanupPolicy, usage: StorageUsage, backups: [BackupRecord],
                trash: [TrashBatchRecord], lastCleanupSummary: String = "",
                lastBackupAt: String? = nil, lastBackupError: String? = nil) {
        self.policy = policy; self.usage = usage; self.backups = backups; self.trash = trash
        self.lastCleanupSummary = lastCleanupSummary; self.lastBackupAt = lastBackupAt
        self.lastBackupError = lastBackupError
    }
}

public struct TrashRestoreResult: Codable, Equatable, Sendable {
    public let restored: Int
    public let skipped: Int
    public init(restored: Int, skipped: Int) { self.restored = restored; self.skipped = skipped }
}

public protocol MaintenanceGateway: Sendable {
    func snapshot() async -> MaintenanceSnapshot
    func updatePolicy(_ policy: CleanupPolicy) async
    func runCleanup() async -> String
    func createBackup() async -> MaintenanceSnapshot
    func restoreBackup(id: String) async throws
    func restoreTrash(id: String) async -> TrashRestoreResult
    func deleteTrash(id: String) async
    func clearTrash() async
}
