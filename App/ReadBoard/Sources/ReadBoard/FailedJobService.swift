import Foundation

// MARK: - 管线失败记录 + 手动重试
// content_job 记了各管线的失败(status=3)。这里聚合失败项供重看/手动重试。

struct FailedJob: Identifiable, Hashable {
    let id: Int64            // content_job.id
    let contentId: Int64
    let jtype: String        // score / translate / summarize / transcribe
    let error: String?
    let finishedAt: String?
    let title: String        // 关联 content.title
}

final class FailedJobService: @unchecked Sendable {
    static let shared = FailedJobService()
    private let db = Database.shared
    private init() {}

    /// 最近失败的 job（每 content+jtype 只取最新一条失败的）
    func recentFailures(limit: Int = 100) -> [FailedJob] {
        db.queryRows("""
            SELECT j.id, j.content_id, j.jtype, j.error, j.finished_at,
                   (SELECT title FROM content WHERE id = j.content_id) AS title
            FROM content_job j
            WHERE j.status = 3
            GROUP BY j.content_id, j.jtype
            HAVING j.id = MAX(j.id)
            ORDER BY j.finished_at DESC LIMIT ?;
            """, params: [limit]).map { r in
                FailedJob(
                    id: Int64(r["id"] ?? "0") ?? 0,
                    contentId: Int64(r["content_id"] ?? "0") ?? 0,
                    jtype: r["jtype"] ?? "",
                    error: r["error"].flatMap { $0.isEmpty ? nil : $0 },
                    finishedAt: r["finished_at"],
                    title: r["title"] ?? "(已删除)"
                )
            }
    }

    /// 手动重试某条失败 job（按 jtype 重跑对应管线）
    func retry(_ job: FailedJob) async -> Bool {
        guard let row = db.queryRows(
            "SELECT title, url, content_md, excerpt, meta, language FROM content WHERE id = ?",
            params: [job.contentId]).first else { return false }
        let title = row["title"] ?? ""
        let url = row["url"] ?? ""
        let body = (row["content_md"].flatMap { $0.isEmpty ? nil : $0 }) ?? (row["excerpt"] ?? "")
        let language = row["language"]
        var audioUrl: String? = nil
        if let metaStr = row["meta"], let data = metaStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            audioUrl = (obj["audio_url"] as? String) ?? (obj["video_url"] as? String)
        }

        let llm = LLMPipeline()
        switch job.jtype {
        case "score":     return await llm.score(contentId: job.contentId, title: title, body: body)
        case "translate": return await llm.translate(contentId: job.contentId, title: title, body: body)
        case "summarize": return await llm.summarize(contentId: job.contentId, title: title, body: body)
        case "transcribe":
            return await TranscribePipeline().transcribe(
                contentId: job.contentId, title: title, audioUrl: audioUrl, pageUrl: url, language: language)
        default: return false
        }
    }
}
