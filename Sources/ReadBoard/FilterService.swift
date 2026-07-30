import Foundation

// MARK: - 规则过滤器
// 关键词/正则规则：新内容入库/管线扫描时命中则自动执行动作（标已读/加星/打标签）。
// source_id NULL=全局规则，否则仅对某源生效。

public struct FilterRule: Identifiable, Hashable {
    public let id: Int64
    var name: String
    var field: String        // title / content / author / url
    var matchType: String    // contains / regex / prefix
    var pattern: String
    var action: String       // mark_read / star / tag:<名>
    var sourceId: Int64?     // nil = 全局
    var enabled: Bool
}

public final class FilterService: @unchecked Sendable {
    static let shared = FilterService()
    private let db = Database.shared
    private init() {}

    // MARK: CRUD

    func allRules() -> [FilterRule] {
        db.queryRows("SELECT id, name, field, match_type, pattern, action, source_id, enabled FROM filter_rule ORDER BY id;")
            .map { r in
                FilterRule(
                    id: Int64(r["id"] ?? "0") ?? 0,
                    name: r["name"] ?? "",
                    field: r["field"] ?? "title",
                    matchType: r["match_type"] ?? "contains",
                    pattern: r["pattern"] ?? "",
                    action: r["action"] ?? "mark_read",
                    sourceId: r["source_id"].flatMap { Int64($0) },
                    enabled: r["enabled"] == "1"
                )
            }
    }

    @discardableResult
    func addRule(_ rule: FilterRule) -> Bool {
        db.execute("""
            INSERT INTO filter_rule (name, field, match_type, pattern, action, source_id, enabled)
            VALUES (?,?,?,?,?,?,?)
            """,
            params: [rule.name, rule.field, rule.matchType, rule.pattern, rule.action,
                     rule.sourceId.map { Int($0) }, rule.enabled ? 1 : 0])
    }

    func updateRule(_ rule: FilterRule) {
        db.execute("""
            UPDATE filter_rule SET name=?, field=?, match_type=?, pattern=?, action=?, source_id=?, enabled=? WHERE id=?
            """,
            params: [rule.name, rule.field, rule.matchType, rule.pattern, rule.action,
                     rule.sourceId.map { Int($0) }, rule.enabled ? 1 : 0, rule.id])
    }

    func removeRule(id: Int64) {
        db.execute("DELETE FROM filter_rule WHERE id = ?", params: [id])
    }

    // MARK: 应用

    /// 对一条新内容应用所有命中规则。在 upsertContent 插入后调用。
    func applyRules(contentId: Int64, sourceId: Int64, title: String, content: String, author: String, url: String) {
        for rule in allRules() where rule.enabled {
            // 源限定：规则有 source_id 且不匹配则跳过
            if let rsid = rule.sourceId, rsid != sourceId { continue }
            let target: String
            switch rule.field {
            case "content": target = content
            case "author": target = author
            case "url": target = url
            default: target = title
            }
            guard matches(rule: rule, text: target) else { continue }
            applyAction(rule.action, contentId: contentId)
        }
    }

    private func matches(rule: FilterRule, text: String) -> Bool {
        switch rule.matchType {
        case "regex":
            return text.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil
        case "prefix":
            return text.lowercased().hasPrefix(rule.pattern.lowercased())
        default: // contains
            return text.lowercased().contains(rule.pattern.lowercased())
        }
    }

    private func applyAction(_ action: String, contentId: Int64) {
        if action == "mark_read" {
            db.execute("UPDATE content SET read_at = datetime('now') WHERE id = ?", params: [contentId])
        } else if action == "star" {
            db.execute("UPDATE content SET starred = 1 WHERE id = ?", params: [contentId])
        } // TODO: tag 体系下一版实现
    }
}
