import Foundation

// MARK: - 数据保留策略
// 67k 内容会无限膨胀。按规则自动收缩：已读且超过 N 天的归档；归档超过 M 天的删除。
// 保护：星标/有标签的不动。周期执行（每日）。

@MainActor
final class RetentionService: ObservableObject {
    static let shared = RetentionService()

    @Published var lastRunSummary = ""

    private let db = Database.shared
    /// 已读内容超过该天数自动归档（默认 30 天）
    var archiveAfterDays = 30
    /// 归档内容超过该天数自动删除（默认 90 天；0 = 不删除）
    var deleteAfterDays = 90
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
    @discardableResult
    func runNow() async -> (archived: Int, deleted: Int) {
        // 1. 已读且超期的归档（保护星标/有标签）
        db.execute("""
            UPDATE content SET is_archived = 1
            WHERE is_archived = 0 AND starred = 0
              AND read_at IS NOT NULL
              AND read_at < datetime('now', '-\(archiveAfterDays) days')
              AND id NOT IN (SELECT content_id FROM content_tag);
            """)
        let archived = db.scalarInt("SELECT changes()") ?? 0

        // 2. 归档超期的删除（保护星标/有标签；0 = 不删）
        var deleted = 0
        if deleteAfterDays > 0 {
            db.execute("""
                DELETE FROM content
                WHERE is_archived = 1 AND starred = 0
                  AND updated_at < datetime('now', '-\(deleteAfterDays) days')
                  AND id NOT IN (SELECT content_id FROM content_tag);
                """)
            deleted = db.scalarInt("SELECT changes()") ?? 0
        }

        lastRunSummary = "保留策略：归档 \(archived)，删除 \(deleted)"
        return (archived, deleted)
    }
}
