import Foundation
import SQLite3

// MARK: - SQLite 自动备份
// 805MB 单文件是单点风险。用 SQLite 在线备份 API(热备不锁库)周期备份到 Data/backups/，
// 保留最近 N 份，滚动清理。启动时跑一次 + 每日一次。

@MainActor
final class BackupService: ObservableObject {
    static let shared = BackupService()

    @Published var lastBackupAt: String? = nil
    @Published var lastBackupError: String? = nil

    private let dbPath = NSHomeDirectory() + "/readboard/Data/readboard.db"
    private let backupDir = NSHomeDirectory() + "/readboard/Data/backups"
    /// 保留份数统一由 CacheCleanupService 持有（UserDefaults 持久化，设置页可调），这里只读透传
    private var keepCount: Int { CacheCleanupService.shared.backupKeepCount }
    /// 备份间隔（每日）
    private let interval: TimeInterval = 24 * 3600
    private var timer: Timer?

    private init() {}

    func start() {
        // 启动时若当天还没备份则立即备份一次
        Task { await backupIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.backupIfDue() }
        }
    }

    /// 距上次备份超过间隔才执行
    func backupIfDue() async {
        let last = UserDefaults.standard.double(forKey: "backup.lastAt")
        if Date().timeIntervalSince1970 - last < interval { return }
        await backupNow()
    }

    /// 立即备份（在线热备，不阻塞读写）
    func backupNow() async {
        do {
            try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
            let stamp = Self.stamp()
            let dest = "\(backupDir)/readboard-\(stamp).db"
            try await Self.onlineBackup(source: dbPath, dest: dest)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "backup.lastAt")
            lastBackupAt = stamp
            lastBackupError = nil
            pruneOld()
        } catch {
            lastBackupError = error.localizedDescription
        }
    }

    /// 滚动删除超出 keepCount 的旧备份（按文件名时间排序）
    private func pruneOld() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: backupDir) else { return }
        let backups = files.filter { $0.hasPrefix("readboard-") && $0.hasSuffix(".db") }.sorted()
        let excess = backups.count - keepCount
        guard excess > 0 else { return }
        for f in backups.prefix(excess) {
            try? FileManager.default.removeItem(atPath: "\(backupDir)/\(f)")
        }
    }

    /// SQLite 在线备份 API：边读边拷，不锁源库
    private static func onlineBackup(source: String, dest: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                var srcDB: OpaquePointer?
                var dstDB: OpaquePointer?
                guard sqlite3_open_v2(source, &srcDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                      sqlite3_open_v2(dest, &dstDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                    cont.resume(throwing: BackupError.openFailed)
                    return
                }
                defer {
                    sqlite3_close(srcDB)
                    sqlite3_close(dstDB)
                }
                guard let backup = sqlite3_backup_init(dstDB, "main", srcDB, "main") else {
                    cont.resume(throwing: BackupError.initFailed)
                    return
                }
                // -1 = 一次拷完所有页
                let rc = sqlite3_backup_step(backup, -1)
                sqlite3_backup_finish(backup)
                if rc == SQLITE_DONE {
                    cont.resume()
                } else {
                    cont.resume(throwing: BackupError.stepFailed(rc))
                }
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    enum BackupError: Error, LocalizedError {
        case openFailed, initFailed, stepFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .openFailed: return "无法打开源/目标库"
            case .initFailed: return "备份初始化失败"
            case .stepFailed(let rc): return "备份拷贝失败 rc=\(rc)"
            }
        }
    }
}
