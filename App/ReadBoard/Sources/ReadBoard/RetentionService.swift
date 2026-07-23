import Foundation

// MARK: - 数据保留策略
// 67k 内容会无限膨胀。按规则自动收缩：已读且超过 N 天的归档；归档超过 M 天的删除。
// 保护：星标/有标签的不动。周期执行（每日）。

@MainActor
final class RetentionService: ObservableObject {
    static let shared = RetentionService()

    @Published var lastRunSummary = ""

    private let db = Database.shared
    /// 天数统一由 CacheCleanupService 持有（UserDefaults 持久化，设置页可调），这里只做只读透传
    private var archiveAfterDays: Int { CacheCleanupService.shared.archiveAfterDays }
    private var deleteAfterDays: Int { CacheCleanupService.shared.deleteAfterDays }
    private var timer: Timer?

    private init() {}

    func start() {
        Task { await runIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runIfDue() }
        }
    }

    /// 每日跑一次
    func runIfDue() async {
        let last = UserDefaults.standard.double(forKey: "retention.lastRun")
        if Date().timeIntervalSince1970 - last < 24 * 3600 { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "retention.lastRun")
        await runNow()
    }

    /// 立即执行保留策略。返回 (归档数, 删除数)。
    /// R4: 统一委托 CacheCleanupService.runRetention()——两处 SQL 完全重复会漂移，单一实现消除风险。
    @discardableResult
    func runNow() async -> (archived: Int, deleted: Int) {
        let result = CacheCleanupService.shared.runRetention()
        lastRunSummary = "保留策略：归档 \(result.archived)，删除 \(result.deleted)"
        return result
    }
}
