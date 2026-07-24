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

        guard let row = db.queryRows("""
            SELECT c.id, c.title, c.url, c.source, c.author, c.published_at,
                   c.llm_score, c.llm_summary, c.llm_translated_md, c.content_md, c.excerpt,
                   c.ctype, s.name AS source_name
            FROM content c
            LEFT JOIN content_source s ON c.source_id = s.id
            WHERE c.id = ?;
            """, params: [contentId]).first else { return false }

        let md = renderBilingual(row: row)
        let sourceName = row["source_name"] ?? row["source"] ?? "unknown"
        let ok = writeFile(md: md,
                           title: row["title"] ?? "untitled",
                           sourceName: sourceName,
                           contentId: contentId)
        if ok {
            // 标记已归档（幂等锚点 + 统计）
            db.execute("""
                UPDATE content SET meta = json_set(COALESCE(meta,'{}'), '$.archived_at', datetime('now'))
                WHERE id = ?;
                """, params: [contentId])
        }
        return ok
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
