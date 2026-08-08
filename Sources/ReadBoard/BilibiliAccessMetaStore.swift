import Foundation

/// B站访问权限状态统一写入口。转录链路和一次性历史回填共用，
/// 避免不同路径写出不一致的 meta 键。
enum BilibiliAccessMetaStore {
    static func apply(contentId: Int64, access: BilibiliVideoAccess) {
        let db = Database.shared
        let current = db.scalarString("SELECT meta FROM content WHERE id = ?", params: [contentId]) ?? "{}"
        var object = (try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any]) ?? [:]
        object["bilibili_access_state"] = access.state.rawValue
        object["bilibili_access_label"] = access.state.listLabel
        object["bilibili_access_toast"] = access.toast
        object["bilibili_access_privilege_type"] = access.privilegeType
        object["bilibili_access_jump_url"] = access.jumpURL?.absoluteString
        object["bilibili_partial_transcript"] = access.isPartial ? 1 : 0
        object["bilibili_access_checked_at"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return }
        if db.execute("UPDATE content SET meta = ? WHERE id = ?", params: [json, contentId]) {
            NotificationCenter.default.post(name: .contentUpdated, object: nil)
        }
    }
}
