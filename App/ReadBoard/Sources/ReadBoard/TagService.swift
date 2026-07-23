import Foundation

// MARK: - 标签系统
// 跨源主题归类（AI/矿业/宏观），多对多。tag + content_tag 两表。

struct Tag: Identifiable, Hashable {
    let id: Int64
    let name: String
    let color: String?
}

final class TagService: @unchecked Sendable {
    static let shared = TagService()
    private let db = Database.shared
    private init() {}

    // MARK: 标签 CRUD

    func allTags() -> [Tag] {
        db.queryRows("SELECT id, name, color FROM tag ORDER BY name;").map {
            Tag(id: Int64($0["id"] ?? "0") ?? 0, name: $0["name"] ?? "", color: $0["color"])
        }
    }

    @discardableResult
    func addTag(name: String, color: String? = nil) -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        db.execute("INSERT OR IGNORE INTO tag (name, color) VALUES (?, ?)", params: [trimmed, color])
        return db.scalarInt("SELECT id FROM tag WHERE name = ?", params: [trimmed]).map { Int64($0) }
    }

    func removeTag(id: Int64) {
        db.execute("DELETE FROM tag WHERE id = ?", params: [id])
    }

    // MARK: 内容-标签关联

    func tagsFor(contentId: Int64) -> [Tag] {
        db.queryRows("""
            SELECT t.id, t.name, t.color FROM tag t
            JOIN content_tag ct ON ct.tag_id = t.id
            WHERE ct.content_id = ? ORDER BY t.name;
            """, params: [contentId]).map {
            Tag(id: Int64($0["id"] ?? "0") ?? 0, name: $0["name"] ?? "", color: $0["color"])
        }
    }

    /// 给内容加标签（按标签名，不存在则建）
    func tag(contentId: Int64, tagName: String) {
        guard let tid = addTag(name: tagName) else { return }
        db.execute("INSERT OR IGNORE INTO content_tag (content_id, tag_id) VALUES (?, ?)",
                   params: [contentId, tid])
    }

    func untag(contentId: Int64, tagId: Int64) {
        db.execute("DELETE FROM content_tag WHERE content_id = ? AND tag_id = ?",
                   params: [contentId, tagId])
    }

    /// 按标签筛内容 id 列表
    func contentIds(forTag tagId: Int64) -> [Int64] {
        db.queryRows("SELECT content_id FROM content_tag WHERE tag_id = ?;", params: [tagId])
            .compactMap { Int64($0["content_id"] ?? "") }
    }

    /// 各标签的内容数（用于标签列表计数）
    func tagCounts() -> [(tag: Tag, count: Int)] {
        db.queryRows("""
            SELECT t.id, t.name, t.color, COUNT(ct.content_id) AS cnt FROM tag t
            LEFT JOIN content_tag ct ON ct.tag_id = t.id
            GROUP BY t.id ORDER BY cnt DESC, t.name;
            """).map {
                (Tag(id: Int64($0["id"] ?? "0") ?? 0, name: $0["name"] ?? "", color: $0["color"]),
                 Int($0["cnt"] ?? "0") ?? 0)
            }
    }
}
