import Foundation
import SQLite3

// MARK: - SQLite 自动备份 + 恢复
// 805MB 单文件是单点风险。用 SQLite 在线备份 API(热备不锁库)周期备份到 Data/backups/，
// 保留最近 N 份，滚动清理。启动时跑一次 + 每日一次。
// 恢复：先校验候选文件合法性（能打开 + 有 content 表），再安全备份当前库后整体替换。

public struct BackupInfo: Identifiable, Hashable {
    public let id = UUID()
    let path: String
    let date: Date
    let sizeBytes: Int64

    var displayName: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let sizeMB = String(format: "%.1f MB", Double(sizeBytes) / 1_048_576.0)
        return "\(fmt.string(from: date))  (\(sizeMB))"
    }
}

@MainActor
public final class BackupService: ObservableObject {
    static let shared = BackupService()

    @Published var lastBackupAt: String? = nil
    @Published var lastBackupError: String? = nil

    private let dbPath = Database.databasePath
    private let backupDir = Database.dataDirectory + "/backups"
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

    func stop() { timer?.invalidate(); timer = nil }

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

    /// 列出已有备份（按文件名时间倒序）
    nonisolated func listBackups() -> [BackupInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: backupDir)
            .filter({ $0.hasPrefix("readboard-") && $0.hasSuffix(".db") })
            .sorted().reversed() else { return [] }
        return files.compactMap { f in
            let p = backupDir + "/" + f
            guard let attrs = try? fm.attributesOfItem(atPath: p) else { return nil }
            return BackupInfo(path: p,
                              date: attrs[.modificationDate] as? Date ?? Date.distantPast,
                              sizeBytes: (attrs[.size] as? Int64) ?? 0)
        }
    }

    /// 校验候选 db：能打开 + 有 content 表（只读，不动原文件）
    nonisolated func validate(candidate path: String) -> Bool {
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        defer { sqlite3_close(h) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(h, "SELECT name FROM sqlite_master WHERE type='table' AND name='content';",
                                 -1, &stmt, nil) == SQLITE_OK else { return false }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// 恢复：当前库先自动安全备份（restore-from-xxx），再用候选文件整体替换。
    /// 成功后调用方应退出 App（连接句柄已失效）。
    func restore(from candidatePath: String) throws {
        guard validate(candidate: candidatePath) else {
            throw RestoreError.invalidCandidate
        }
        // 1. 当前库安全备份（万一恢复错了还能回来）
        do {
            let dest = "\(backupDir)/readboard-restore-from-\(Self.stamp()).db"
            try fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
            // 同步版在线备份（恢复期间阻塞可接受，保证安全备份完成再替换）
            try Self.onlineBackupSync(source: dbPath, dest: dest)
        } catch {
            throw RestoreError.safetyBackupFailed(error.localizedDescription)
        }
        // 2. 恢复前先把 WAL 全量 checkpoint 进主文件（TRUNCATE）——
        //    不 checkpoint 直接替换的话，候选库（旧版）可能与残留 wal（新版）混出错乱页。
        checkpointCurrentDB()
        // 3. 关连接，替换文件
        Database.shared.close()
        do {
            // 删掉 wal/shm（候选是完整主文件，残留 wal 会造成错乱）
            for suffix in ["-wal", "-shm"] {
                try? fm.removeItem(atPath: dbPath + suffix)
            }
            try fm.removeItem(atPath: dbPath)
            try fm.copyItem(atPath: candidatePath, toPath: dbPath)
        } catch {
            // 替换失败 = 主库已被删/半替换 + 连接已关——继续跑会在坏库上迁移/写入，
            // 数据污染风险远大于直接退出。记录安全备份位置后强制终止，用户从安全备份手动恢复。
            fputs("""
                [restore] ⛔ 文件替换失败: \(error.localizedDescription)
                [restore] 当前库可能已损坏。安全备份在 \(backupDir)/readboard-restore-from-*.db
                [restore] 请将安全备份手动拷回 \(dbPath) 后重启 App。
                """, stderr)
            exit(1)
        }
    }

    /// 恢复前把当前库 WAL checkpoint 进主文件（FULL→TRUNCATE），保证主文件自包含。
    /// 在 Database.close() 之前调用（连接还活着才能 checkpoint）。
    private func checkpointCurrentDB() {
        var h: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(h) }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(h, "PRAGMA wal_checkpoint(TRUNCATE);", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private var fm: FileManager { FileManager.default }

    /// 同步版在线备份（restore 前安全备份用，保证完成后再替换）
    private static func onlineBackupSync(source: String, dest: String) throws {
        var srcDB: OpaquePointer?
        var dstDB: OpaquePointer?
        guard sqlite3_open_v2(source, &srcDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              sqlite3_open_v2(dest, &dstDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw BackupError.openFailed
        }
        defer { sqlite3_close(srcDB); sqlite3_close(dstDB) }
        guard let backup = sqlite3_backup_init(dstDB, "main", srcDB, "main") else {
            throw BackupError.initFailed
        }
        let rc = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        if rc != SQLITE_DONE { throw BackupError.stepFailed(rc) }
    }

    enum RestoreError: Error, LocalizedError {
        case invalidCandidate
        case safetyBackupFailed(String)
        case replaceFailed(String)
        var errorDescription: String? {
            switch self {
            case .invalidCandidate: return "所选文件不是合法的 readboard 数据库（缺少 content 表）"
            case .safetyBackupFailed(let m): return "恢复前安全备份失败：\(m)"
            case .replaceFailed(let m): return "文件替换失败：\(m)"
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
