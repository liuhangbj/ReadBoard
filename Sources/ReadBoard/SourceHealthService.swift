import Foundation

// MARK: - 源健康监控
// 聚合各源抓取健康状况：报错、长期未更新（停更）、抓取量。帮助发现死源/问题源。

public struct SourceHealth: Identifiable, Hashable, Sendable {
    public let id: Int64
    let name: String
    let identifier: String
    let enabled: Bool
    let lastFetchedAt: String?
    let error: String?
    let contentCount: Int
    /// 距上次成功抓取的小时数（nil = 从未抓过）
    let hoursSinceFetch: Double?

    var isStale: Bool {
        guard let h = hoursSinceFetch else { return true }
        return h > 48   // 超 48 小时未更新视为停更可疑
    }
    var hasError: Bool { error != nil && !(error?.isEmpty ?? true) }
}

public final class SourceHealthService: @unchecked Sendable {
    static let shared = SourceHealthService()
    private let db = Database.shared
    private init() {}

    /// 全部源的健康状况
    func report() -> [SourceHealth] {
        let rows = db.queryRows("""
            SELECT s.id, s.name, s.identifier, s.enabled, s.last_fetched_at, s.error,
                   (SELECT COUNT(*) FROM content c WHERE c.source_id = s.id) AS cnt
            FROM content_source s ORDER BY s.name;
            """)
        return rows.map { r in
            var hours: Double? = nil
            if let t = r["last_fetched_at"], !t.isEmpty {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                f.timeZone = TimeZone(identifier: "UTC")
                if let d = f.date(from: t) {
                    hours = Date().timeIntervalSince(d) / 3600
                }
            }
            return SourceHealth(
                id: Int64(r["id"] ?? "0") ?? 0,
                name: r["name"] ?? "",
                identifier: r["identifier"] ?? "",
                enabled: r["enabled"] == "1",
                lastFetchedAt: r["last_fetched_at"],
                error: r["error"].flatMap { $0.isEmpty ? nil : $0 },
                contentCount: Int(r["cnt"] ?? "0") ?? 0,
                hoursSinceFetch: hours
            )
        }
    }

    /// 有问题的源（报错 或 停更）
    func problemSources() -> [SourceHealth] {
        report().filter { $0.enabled && ($0.hasError || $0.isStale) }
    }
}
