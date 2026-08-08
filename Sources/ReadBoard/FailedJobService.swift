import Foundation

// MARK: - 管线失败记录 + 手动重试
// content_job 记了各管线的失败(status=3)。这里聚合失败项供重看/手动重试。

public struct FailedJob: Identifiable, Hashable, Sendable {
    public let id: Int64            // content_job.id
    let contentId: Int64
    let jtype: String        // score / translate / summarize / transcribe
    let error: String?
    let finishedAt: String?
    let title: String        // 关联 content.title
}

/// 连续失败达到暂停阈值的内容处理任务，供数据看板详情页展示和精确重试。
public struct PausedContentFailure: Identifiable, Hashable, Sendable {
    public let id: Int64             // 最近一次 content_job.id
    let contentId: Int64
    let jtype: String
    let error: String?
    let finishedAt: String?
    let title: String
    let sourceName: String
    let consecutiveFailures: Int
}

public final class FailedJobService: @unchecked Sendable {
    static let shared = FailedJobService()
    private let db = Database.shared
    private init() {}

    /// 失败记录是自动处理的告警，不是永久历史。展示或计数前再次核对当前目标：
    /// 工序已关闭、内容/来源已失效，或对应结果已经存在时，旧失败不再有行动价值。
    @discardableResult
    func clearResolvedAutomaticFailures() -> Bool {
        db.execute("""
            DELETE FROM content_job
            WHERE status = 3
              AND (
                NOT EXISTS (
                    SELECT 1 FROM content c WHERE c.id = content_job.content_id
                )
                OR EXISTS (
                    SELECT 1
                    FROM content c
                    LEFT JOIN content_source s ON s.id = c.source_id
                    WHERE c.id = content_job.content_id
                      AND (
                        c.deleted_at IS NOT NULL
                        OR c.is_duplicate = 1
                        OR COALESCE(s.enabled, 0) = 0
                        OR CASE content_job.jtype
                            WHEN 'score' THEN
                                c.auto_score IS NOT 1 OR c.llm_score IS NOT NULL
                            WHEN 'translate' THEN
                                c.auto_translate IS NOT 1
                                OR LENGTH(TRIM(COALESCE(c.llm_translated_md, ''))) > 0
                            WHEN 'summarize' THEN
                                c.auto_summarize IS NOT 1
                                OR LENGTH(TRIM(COALESCE(c.llm_summary, ''))) > 0
                            WHEN 'transcribe' THEN
                                c.auto_transcribe IS NOT 1
                                OR LENGTH(TRIM(COALESCE(c.llm_transcript_md, ''))) > 0
                            ELSE 0
                           END
                      )
                )
              );
            """)
    }

    /// 最近失败的 job：每个 content+jtype 先取最新一次任务，只有最新状态仍失败才展示。
    /// 不能先筛 status=3，否则“失败后已成功”的旧记录会永远留在失败页。
    func recentFailures(limit: Int = 100) -> [FailedJob] {
        clearResolvedAutomaticFailures()
        return db.queryRows("""
            WITH latest AS (
                SELECT j.*,
                       ROW_NUMBER() OVER (
                           PARTITION BY j.content_id, j.jtype ORDER BY j.id DESC
                       ) AS rn
                FROM content_job j
                WHERE NOT EXISTS (
                    SELECT 1 FROM content_processing_ignore i
                    WHERE i.content_id=j.content_id AND i.jtype=j.jtype
                )
            )
            SELECT latest.id, latest.content_id, latest.jtype, latest.error,
                   latest.finished_at, COALESCE(c.title, '(已删除)') AS title
            FROM latest
            LEFT JOIN content c ON c.id = latest.content_id
            WHERE latest.rn = 1 AND latest.status = 3
            ORDER BY latest.finished_at DESC LIMIT ?;
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

    /// 连续失败至少 3 次、已被 Worker 暂停的任务。与 Worker 的失败计数使用同一口径。
    func pausedFailures(limit: Int = 200) -> [PausedContentFailure] {
        clearResolvedAutomaticFailures()
        return db.queryRows("""
            WITH ranked AS (
              SELECT j.*,
                     ROW_NUMBER() OVER (
                       PARTITION BY j.content_id, j.jtype ORDER BY j.id DESC
                     ) AS rn
              FROM content_job j
              WHERE NOT EXISTS (
                SELECT 1 FROM content_processing_ignore i
                WHERE i.content_id=j.content_id AND i.jtype=j.jtype
              )
            ),
            consec AS (
              SELECT content_id, jtype, COUNT(*) AS fails
              FROM ranked
              WHERE rn <= (
                SELECT COALESCE(MIN(rn) - 1, 999999) FROM ranked r2
                WHERE r2.content_id = ranked.content_id
                  AND r2.jtype = ranked.jtype
                  AND r2.status != 3
              ) AND status = 3
              GROUP BY content_id, jtype
            )
            SELECT r.id, r.content_id, r.jtype, r.error, r.finished_at,
                   COALESCE(c.title, '(内容已删除)') AS title,
                   COALESCE(s.name, '未知来源') AS source_name,
                   consec.fails
            FROM ranked r
            JOIN consec ON consec.content_id = r.content_id AND consec.jtype = r.jtype
            LEFT JOIN content c ON c.id = r.content_id
            LEFT JOIN content_source s ON s.id = c.source_id
            WHERE r.rn = 1 AND r.status = 3 AND consec.fails >= 3
            ORDER BY consec.fails DESC, r.finished_at DESC
            LIMIT ?;
            """, params: [limit]).map { row in
                PausedContentFailure(
                    id: Int64(row["id"] ?? "0") ?? 0,
                    contentId: Int64(row["content_id"] ?? "0") ?? 0,
                    jtype: row["jtype"] ?? "",
                    error: row["error"].flatMap { $0.isEmpty ? nil : $0 },
                    finishedAt: row["finished_at"],
                    title: row["title"] ?? "(内容已删除)",
                    sourceName: row["source_name"] ?? "未知来源",
                    consecutiveFailures: Int(row["fails"] ?? "0") ?? 0
                )
            }
    }

    func retry(_ failure: PausedContentFailure) async -> Bool {
        await retry(FailedJob(
            id: failure.id,
            contentId: failure.contentId,
            jtype: failure.jtype,
            error: failure.error,
            finishedAt: failure.finishedAt,
            title: failure.title
        ))
    }

    /// 永久忽略该内容的自动处理目标。手动处理按钮不读取此表，仍可直接执行。
    @discardableResult
    func ignore(_ failure: PausedContentFailure) -> Bool {
        let inserted = db.execute("""
            INSERT OR IGNORE INTO content_processing_ignore(content_id,jtype)
            VALUES (?, ?);
            """, params: [failure.contentId, failure.jtype])
        guard inserted else { return false }
        db.execute(
            "DELETE FROM content_job WHERE content_id=? AND jtype=? AND status=3",
            params: [failure.contentId, failure.jtype])
        return true
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

        guard await PipelineWorker.shared.tryLockContent(job.contentId) else { return false }

        let llm = LLMPipeline()
        let ok: Bool
        let error: String?
        var recordsOwnResult = false
        switch job.jtype {
        case "score":
            ok = await llm.score(contentId: job.contentId, title: title, body: body)
            error = llm.lastError
        case "translate":
            ok = await llm.translate(contentId: job.contentId, title: title, body: body)
            error = llm.lastError
        case "summarize":
            ok = await llm.summarize(contentId: job.contentId, title: title, body: body)
            error = llm.lastError
        case "transcribe":
            recordsOwnResult = true
            ok = await TranscribePipeline().transcribe(
                contentId: job.contentId, title: title, audioUrl: audioUrl, pageUrl: url, language: language)
            error = nil
        default:
            await PipelineWorker.shared.unlockContent(job.contentId)
            return false
        }
        await PipelineWorker.shared.unlockContent(job.contentId)
        if recordsOwnResult { return ok }
        // 成功结果必须记账；即使界面在模型返回后恰好消失/取消，也不能继续显示旧失败。
        // 只有“未成功且任务已取消”才不新增失败记录。
        guard ok || !Task.isCancelled else { return false }
        recordResult(contentId: job.contentId, jtype: job.jtype, ok: ok, error: error)
        return ok
    }

    private func recordResult(contentId: Int64, jtype: String, ok: Bool, error: String?) {
        db.execute(
            "INSERT INTO content_job (content_id, jtype, status, finished_at, error) VALUES (?, ?, ?, datetime('now'), ?)",
            params: [contentId, jtype, ok ? 2 : 3, ok ? nil : (error ?? "重试失败")])
    }
}
