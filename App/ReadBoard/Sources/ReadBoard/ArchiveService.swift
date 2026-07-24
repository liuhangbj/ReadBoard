import Foundation

// MARK: - 完成归档（最终 md 落盘）
// 核心定位：所有管线（打分/翻译/摘要/转录）是"中间环节"，
// 全部跑完后才把这篇落成最终 md 文件长期保存。
//
// 数据策略（用户拍板）：落盘后数据库记录保留（标题/md/LLM 产出/元数据都在，
// 仍是可检索统一视图），只清 content_html 这类抓取中间产物（retention cleanHtml A 路径
// 对已落盘的立即清 html，不等天数）。retention 物理 DELETE 跳过已落盘记录。
//
// 完成判定（按该源开启的管线）：
//   文章：开了打分要 llm_score、开了摘要要 llm_summary、开了翻译要 llm_translated_md
//   媒体：开了转录要 llm_translated_md（转录稿写这里）+ 开了摘要要 llm_summary
//   开关没开的不算缺——源没开翻译，文章打完分+摘要就算完成。
//
// 幂等：meta.archived_at 标记，已落盘的不重复写。

public final class ArchiveService: @unchecked Sendable {
    public static let shared = ArchiveService()
    private let db = Database.shared
    private init() {}

    /// 归档根目录（设置页可配，默认 ~/readboard/archive/）
    var archiveDir: String {
        let custom = UserDefaults.standard.string(forKey: "archive.dir")?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? NSHomeDirectory() + "/readboard/archive" : custom
    }

    // MARK: 入库即归档（无管线源）

    /// 该源是否没开任何管线开关（源 AND 文件夹全关）。
    /// 没开 = 没有中间环节 = 入库即"完成"，应立即归档纯原文 md。
    func sourceHasNoPipeline(sourceId: Int64?) -> Bool {
        guard let sid = sourceId else { return true }   // 存量/无源：无管线可开
        guard let row = db.queryRows("""
            SELECT s.config AS src_cfg, f.config AS folder_cfg
            FROM content_source s LEFT JOIN folder f ON s.folder_id = f.id
            WHERE s.id = ?;
            """, params: [sid]).first else { return true }
        let sp = PipelinePolicy.from(configJson: row["src_cfg"] ?? "{}")
        let fp = PipelinePolicy.from(configJson: row["folder_cfg"] ?? "{}")
        return !sp.autoScore && !sp.autoTranslate && !sp.autoSummarize && !sp.autoTranscribe
            && !fp.autoScore && !fp.autoTranslate && !fp.autoSummarize && !fp.autoTranscribe
    }

    /// 新内容入库后调用：源没开任何管线则立即归档（纯原文）。
    /// 开了管线的交给 worker 管线完成后归档（archiveIfComplete），这里不动。
    func archiveOnInsertIfNoPipeline(contentId: Int64, sourceId: Int64?) {
        guard sourceHasNoPipeline(sourceId: sourceId) else { return }
        renderAndWrite(contentId: contentId)
    }

    /// 存量补齐：把所有"源没开任何管线 且 未归档 且 有正文"的内容立即归档。
    /// 入库即归档只对新内容生效，本函数一次性补齐历史存量（启动时跑一次）。
    /// 返回新归档条数。
    @discardableResult
    func backfillNoPipelineArchives() -> Int {
        // 无管线源 = 源 AND 文件夹全关；source_id NULL 的存量也算（无管线可开）
        let rows = db.queryRows("""
            SELECT c.id FROM content c
            LEFT JOIN content_source s ON c.source_id = s.id
            LEFT JOIN folder f ON s.folder_id = f.id
            WHERE c.is_duplicate = 0
              AND c.meta NOT LIKE '%archived_at%'
              AND (c.content_md != '' OR c.excerpt != '')
              AND COALESCE(json_extract(s.config,'$.auto_score'),0) = 0
              AND COALESCE(json_extract(s.config,'$.auto_translate'),0) = 0
              AND COALESCE(json_extract(s.config,'$.auto_summarize'),0) = 0
              AND COALESCE(json_extract(s.config,'$.auto_transcribe'),0) = 0
              AND COALESCE(json_extract(f.config,'$.auto_score'),0) = 0
              AND COALESCE(json_extract(f.config,'$.auto_translate'),0) = 0
              AND COALESCE(json_extract(f.config,'$.auto_summarize'),0) = 0
              AND COALESCE(json_extract(f.config,'$.auto_transcribe'),0) = 0;
            """)
        var n = 0
        for r in rows {
            if let idStr = r["id"], let cid = Int64(idStr) {
                if renderAndWrite(contentId: cid) { n += 1 }
            }
        }
        return n
    }

    // MARK: 完成判定

    /// 该内容是否"全部中间环节结束"。
    /// 按该源开启的管线逐项核对：开了的必须有结果，没开的不看。
    func isComplete(contentId: Int64) -> Bool {
        guard let row = db.queryRows("""
            SELECT c.ctype, c.meta, c.llm_score, c.llm_summary, c.llm_translated_md,
                   c.content_md, c.excerpt,
                   s.config AS src_cfg, f.config AS folder_cfg
            FROM content c
            JOIN content_source s ON c.source_id = s.id
            LEFT JOIN folder f ON s.folder_id = f.id
            WHERE c.id = ?;
            """, params: [contentId]).first else { return false }

        // 有效开关 = 源 OR 文件夹
        let sp = PipelinePolicy.from(configJson: row["src_cfg"] ?? "{}")
        let fp = PipelinePolicy.from(configJson: row["folder_cfg"] ?? "{}")
        let autoScore = sp.autoScore || fp.autoScore
        let autoTranslate = sp.autoTranslate || fp.autoTranslate
        let autoSummarize = sp.autoSummarize || fp.autoSummarize
        let autoTranscribe = sp.autoTranscribe || fp.autoTranscribe

        let meta = row["meta"] ?? ""
        let isMedia = (row["ctype"] == "podcast" || row["ctype"] == "video"
                       || meta.contains("audio_url"))
        let hasScore = row["llm_score"] != nil && row["llm_score"] != ""
        let hasSummary = !(row["llm_summary"] ?? "").isEmpty
        let hasTranslated = !(row["llm_translated_md"] ?? "").isEmpty
        let hasBody = !(row["content_md"] ?? "").isEmpty || !(row["excerpt"] ?? "").isEmpty

        // 媒体：转录是主链路（转录稿写 llm_translated_md），开转录就必须有
        if isMedia {
            if autoTranscribe && !hasTranslated { return false }
            if autoSummarize && !hasSummary { return false }
            // 媒体不打分/翻译原文（转录稿才是内容主体），开了转录+摘要就够
            return autoTranscribe || autoSummarize ? (hasTranslated || !autoTranscribe) : hasBody
        }

        // 文章：逐项核对开启的管线
        if autoScore && !hasScore { return false }
        if autoSummarize && !hasSummary { return false }
        if autoTranslate && !hasTranslated { return false }
        // 至少要有正文可存
        return hasBody
    }

    // MARK: 落盘

    /// 完成则落盘（幂等）。返回是否本次写入。worker 每个管线完成后调用。
    @discardableResult
    func archiveIfComplete(contentId: Int64) -> Bool {
        // 已归档跳过
        if let r = db.queryRows("SELECT meta FROM content WHERE id = ?", params: [contentId]).first,
           (r["meta"] ?? "").contains("\"archived_at\"") {
            return false
        }
        guard isComplete(contentId: contentId) else { return false }
        return renderAndWrite(contentId: contentId)
    }

    /// 强制渲染+落盘（不判完成、不判已归档）。内部共用；手动重处理刷新也走它。
    /// 成功写 meta.archived_at。返回是否写入。
    @discardableResult
    func renderAndWrite(contentId: Int64) -> Bool {
        guard let md = renderString(contentId: contentId),
              let row = db.queryRows("""
                  SELECT c.title, c.source, s.name AS source_name
                  FROM content c LEFT JOIN content_source s ON c.source_id = s.id
                  WHERE c.id = ?;
                  """, params: [contentId]).first else { return false }
        let sourceName = row["source_name"] ?? row["source"] ?? "unknown"
        let ok = writeFile(md: md,
                           title: row["title"] ?? "untitled",
                           sourceName: sourceName,
                           contentId: contentId)
        if ok {
            db.execute("""
                UPDATE content SET meta = json_set(COALESCE(meta,'{}'), '$.archived_at', datetime('now'))
                WHERE id = ?;
                """, params: [contentId])
        }
        return ok
    }

    /// 只渲染成字符串（不落盘、不打归档标记）。供导出层对"未走完管线"的内容取内容——
    /// 导出行为不该把内容标记成"已归档"（完成才归档是归档语义，导出只是分发）。
    func renderString(contentId: Int64) -> String? {
        guard let row = db.queryRows("""
            SELECT c.id, c.title, c.url, c.source, c.author, c.published_at,
                   c.llm_score, c.llm_summary, c.llm_translated_md, c.content_md, c.excerpt,
                   c.ctype, s.name AS source_name
            FROM content c
            LEFT JOIN content_source s ON c.source_id = s.id
            WHERE c.id = ?;
            """, params: [contentId]).first else { return nil }
        return renderBilingual(row: row)
    }

    /// 归档文件路径（归档目录/源名/标题-contentId.md）
    func archiveFilePath(contentId: Int64) -> String? {
        guard let row = db.queryRows("""
            SELECT c.title, c.source, s.name AS source_name
            FROM content c LEFT JOIN content_source s ON c.source_id = s.id
            WHERE c.id = ?;
            """, params: [contentId]).first else { return nil }
        let sourceName = row["source_name"] ?? row["source"] ?? "unknown"
        let title = row["title"] ?? "untitled"
        return archiveDir + "/" + ExportService.sanitizeFilename(sourceName)
             + "/" + ExportService.sanitizeFilename(title) + "-\(contentId).md"
    }

    /// 手动重处理后刷新归档：清标记 + 立即重新落盘（文件更新到最新产出）。
    /// 手动单篇 = 用户明确要这份内容，立即重新归档，不等 worker 下一轮。
    /// 返回是否重新落盘成功。
    @discardableResult
    func rearchive(contentId: Int64) -> Bool {
        renderAndWrite(contentId: contentId)
    }

    /// 双语对照渲染：frontmatter + AI 摘要 + 译文（如无则原文）+ 分隔 + 原文
    private func renderBilingual(row: [String: String]) -> String {
        let title = row["title"] ?? "untitled"
        let url = row["url"] ?? ""
        let source = row["source_name"] ?? row["source"] ?? ""
        let author = row["author"] ?? ""
        let published = row["published_at"] ?? ""
        let score = row["llm_score"]
        let summary = row["llm_summary"] ?? ""
        let translated = row["llm_translated_md"] ?? ""
        let body = !(row["content_md"] ?? "").isEmpty ? row["content_md"]! : (row["excerpt"] ?? "")

        func yaml(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }

        var md = "---\n"
        md += "title: \"\(yaml(title))\"\n"
        md += "source: \"\(yaml(source))\"\n"
        if !author.isEmpty { md += "author: \"\(yaml(author))\"\n" }
        md += "url: \"\(yaml(url))\"\n"
        if let s = score, !s.isEmpty { md += "score: \(s)\n" }
        md += "published: \"\(yaml(published))\"\n"
        md += "archived: true\n---\n\n"

        md += "# \(title)\n\n"
        if !summary.isEmpty { md += "> \(summary)\n\n" }

        let bodyClean = ExportService.stripLeadingFrontmatter(body)
        let transClean = ExportService.stripLeadingFrontmatter(translated)

        if !transClean.isEmpty && transClean != bodyClean {
            // 有译文：译文为主，原文附录（双语对照）
            md += transClean + "\n\n---\n\n## 原文\n\n" + bodyClean
        } else {
            // 无译文（中文文章 / 未开翻译）：直接原文
            md += bodyClean
        }
        if !url.isEmpty { md += "\n\n[原文链接](\(url))\n" }
        return md
    }

    /// 写文件：归档目录/源名/标题-contentId.md
    private func writeFile(md: String, title: String, sourceName: String, contentId: Int64) -> Bool {
        let dir = archiveDir + "/" + ExportService.sanitizeFilename(sourceName)
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let filename = ExportService.sanitizeFilename(title) + "-\(contentId).md"
            try md.write(toFile: dir + "/" + filename, atomically: true, encoding: .utf8)
            return true
        } catch {
            fputs("[archive] ⛔ 写入失败 id=\(contentId): \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    // MARK: 统计（设置页展示）

    /// 已落盘文件总数（按目录遍历）
    func archivedFileCount() -> Int {
        guard let en = FileManager.default.enumerator(atPath: archiveDir) else { return 0 }
        var n = 0
        while let f = en.nextObject() as? String {
            if f.hasSuffix(".md") { n += 1 }
        }
        return n
    }

    /// 数据库里已标记归档的内容数
    func archivedContentCount() -> Int {
        db.scalarInt("SELECT COUNT(*) FROM content WHERE meta LIKE '%archived_at%'") ?? 0
    }
}
