import Foundation

// MARK: - 导出体系（后处理板块）
// 规则 = 筛选条件(criteria) + 触发时机(trigger_on) + 目标(target)。
// 管线完成后 PipelineWorker 调 runPending(trigger:)；设置页可手动 runFor(ruleId)。
// 幂等：export_record UNIQUE(rule_id, content_id)，重跑不产生重复交付。

struct ExportRule: Identifiable {
    let id: Int64
    var name: String
    var enabled: Bool
    var criteria: Criteria
    var triggerOn: String          // score / translate / transcribe / manual
    var target: String             // obsidian / mddir / webhook
    var targetConfig: [String: Any]
    var lastRunAt: String?

    static func == (lhs: ExportRule, rhs: ExportRule) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    struct Criteria: Hashable {
        var minScore: Int? = nil
        var sourceIds: [Int64]? = nil
        var requireTranslated = false
        var requireTranscribed = false
        var requireSummary = false
        var starredOnly = false

        static func from(json: String) -> Criteria {
            var c = Criteria()
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return c }
            c.minScore = obj["min_score"] as? Int
            c.sourceIds = (obj["source_ids"] as? [NSNumber])?.map { $0.int64Value }
            c.requireTranslated = obj["require_translated"] as? Bool ?? false
            c.requireTranscribed = obj["require_transcribed"] as? Bool ?? false
            c.requireSummary = obj["require_summary"] as? Bool ?? false
            c.starredOnly = obj["starred_only"] as? Bool ?? false
            return c
        }

        func toJSON() -> String {
            var obj: [String: Any] = [:]
            if let s = minScore { obj["min_score"] = s }
            if let ids = sourceIds { obj["source_ids"] = ids }
            if requireTranslated { obj["require_translated"] = true }
            if requireTranscribed { obj["require_transcribed"] = true }
            if requireSummary { obj["require_summary"] = true }
            if starredOnly { obj["starred_only"] = true }
            return (try? JSONSerialization.data(withJSONObject: obj))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
    }

    var targetDisplay: String {
        switch target {
        case "obsidian": return "Obsidian 仓库"
        case "mddir": return "Markdown 目录"
        case "webhook": return "Webhook"
        default: return target
        }
    }

    var triggerDisplay: String {
        switch triggerOn {
        case "score": return "打分后"
        case "translate": return "翻译后"
        case "transcribe": return "转录后"
        default: return "手动"
        }
    }
}

final class ExportService: @unchecked Sendable {

    static let shared = ExportService()
    private let db = Database.shared
    private init() {}

    // MARK: CRUD

    func listRules() -> [ExportRule] {
        db.queryRows("""
            SELECT id, name, enabled, criteria, trigger_on, target, target_config, last_run_at
            FROM export_rule ORDER BY id;
            """).map { r in
            ExportRule(
                id: Int64(r["id"] ?? "") ?? 0,
                name: r["name"] ?? "未命名",
                enabled: r["enabled"] == "1",
                criteria: ExportRule.Criteria.from(json: r["criteria"] ?? "{}"),
                triggerOn: r["trigger_on"] ?? "manual",
                target: r["target"] ?? "mddir",
                targetConfig: ((try? JSONSerialization.jsonObject(with: Data((r["target_config"] ?? "{}").utf8))) as? [String: Any]) ?? [:],
                lastRunAt: r["last_run_at"])
        }
    }

    @discardableResult
    func saveRule(_ rule: ExportRule) -> Int64 {
        let configJson = (try? JSONSerialization.data(withJSONObject: rule.targetConfig))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        if rule.id > 0 {
            db.execute("""
                UPDATE export_rule SET name=?, enabled=?, criteria=?, trigger_on=?, target=?, target_config=? WHERE id=?
                """, params: [rule.name, rule.enabled ? 1 : 0, rule.criteria.toJSON(),
                              rule.triggerOn, rule.target, configJson, rule.id])
            return rule.id
        }
        db.execute("""
            INSERT INTO export_rule (name, enabled, criteria, trigger_on, target, target_config)
            VALUES (?,?,?,?,?,?)
            """, params: [rule.name, rule.enabled ? 1 : 0, rule.criteria.toJSON(),
                          rule.triggerOn, rule.target, configJson])
        return Int64(db.scalarInt("SELECT last_insert_rowid();") ?? 0)
    }

    func deleteRule(id: Int64) {
        db.execute("DELETE FROM export_rule WHERE id = ?", params: [id])  // record 级联删
    }

    // MARK: 触发

    /// 管线完成后调用：跑所有 trigger_on 匹配且启用的规则。
    /// contentId 非 nil 时只评估这一条（增量）；nil 时全量扫规则匹配项（手动补跑）。
    func runPending(trigger: String, contentId: Int64? = nil) async {
        guard FeatureBoard.export.enabled else { return }
        for rule in listRules() where rule.enabled && rule.triggerOn == trigger {
            await runFor(rule: rule, contentId: contentId)
        }
    }

    /// 手动执行单条规则（设置页"立即执行"）
    func runFor(ruleId: Int64) async {
        guard let rule = listRules().first(where: { $0.id == ruleId }) else { return }
        await runFor(rule: rule, contentId: nil)
    }

    // MARK: 执行

    private func runFor(rule: ExportRule, contentId: Int64?) async {
        let candidates = matchingContents(rule: rule, contentId: contentId)
        guard !candidates.isEmpty else { return }
        for c in candidates {
            let (ok, dest, err) = await deliver(rule: rule, c: c)
            db.execute("""
                INSERT OR REPLACE INTO export_record (rule_id, content_id, status, destination, error)
                VALUES (?,?,?,?,?)
                """, params: [rule.id, c.id, ok ? "delivered" : "failed", dest, err])
        }
        db.execute("UPDATE export_rule SET last_run_at = datetime('now') WHERE id = ?", params: [rule.id])
    }

    /// 按 criteria 组装 SQL，只取还没被这条规则成功导出过的内容
    private func matchingContents(rule: ExportRule, contentId: Int64?) -> [ExportContent] {
        var whereClauses = ["is_duplicate = 0"]
        var params: [Any?] = []
        if let cid = contentId { whereClauses.append("id = ?"); params.append(cid) }
        if let minScore = rule.criteria.minScore { whereClauses.append("llm_score >= ?"); params.append(minScore) }
        if let ids = rule.criteria.sourceIds, !ids.isEmpty {
            whereClauses.append("source_id IN (\(ids.map { String($0) }.joined(separator: ",")))")
        }
        if rule.criteria.requireTranslated { whereClauses.append("llm_translated_md IS NOT NULL AND llm_translated_md != ''") }
        // 转录稿写入 llm_translated_md（TranscribePipeline），故"已转录"= 有媒体地址且有译文
        if rule.criteria.requireTranscribed {
            whereClauses.append("""
                llm_translated_md IS NOT NULL AND llm_translated_md != ''
                AND (meta LIKE '%audio_url%' OR meta LIKE '%video_id%')
                """)
        }
        if rule.criteria.requireSummary { whereClauses.append("llm_summary IS NOT NULL AND llm_summary != ''") }
        if rule.criteria.starredOnly { whereClauses.append("starred = 1") }
        // 幂等：跳过已成功交付的
        whereClauses.append("""
            id NOT IN (SELECT content_id FROM export_record WHERE rule_id = ? AND status = 'delivered')
            """)
        params.append(rule.id)

        let sql = """
            SELECT id, title, url, source, llm_score, llm_summary, llm_translated_md,
                   content_md, published_at
            FROM content
            WHERE \(whereClauses.joined(separator: " AND "))
            ORDER BY id DESC LIMIT 200;
            """
        return db.queryRows(sql, params: params).map { r in
            ExportContent(
                id: Int64(r["id"] ?? "") ?? 0,
                title: r["title"] ?? "",
                url: r["url"] ?? "",
                source: r["source"] ?? "",
                score: Int(r["llm_score"] ?? ""),
                summary: r["llm_summary"],
                translated: r["llm_translated_md"],
                contentMd: r["content_md"],
                publishedAt: r["published_at"] ?? "")
        }
    }

    private struct ExportContent {
        let id: Int64
        let title, url, source: String
        let score: Int?
        let summary, translated, contentMd: String?
        let publishedAt: String
    }

    // MARK: 渲染 + 交付

    private func render(rule: ExportRule, c: ExportContent) -> String {
        var md = "---\n"
        md += "title: \"\(c.title.replacingOccurrences(of: "\"", with: "\\\""))\"\n"
        md += "source: \"\(c.source)\"\n"
        md += "url: \"\(c.url)\"\n"
        if let s = c.score { md += "score: \(s)\n" }
        md += "published: \"\(c.publishedAt)\"\n"
        md += "rule: \"\(rule.name)\"\n---\n\n"
        md += "# \(c.title)\n\n"
        if let sum = c.summary, !sum.isEmpty { md += "> \(sum)\n\n" }
        // 正文优先级：译文（含转录稿，TranscribePipeline 写入此字段）> 原文
        if let t = c.translated, !t.isEmpty {
            if let orig = c.contentMd, !orig.isEmpty {
                md += t + "\n\n---\n\n## 原文\n\n" + orig
            } else {
                md += t
            }
        } else {
            md += c.contentMd ?? ""
        }
        md += "\n\n[原文链接](\(c.url))\n"
        return md
    }

    private func deliver(rule: ExportRule, c: ExportContent) async -> (Bool, String?, String?) {
        let md = render(rule: rule, c: c)
        switch rule.target {
        case "obsidian", "mddir":
            guard let dir = rule.targetConfig["dir"] as? String, !dir.isEmpty else {
                return (false, nil, "目标目录未配置")
            }
            return writeMarkdown(md: md, title: c.title, source: c.source,
                                 dir: dir, bySource: rule.targetConfig["subdir_by_source"] as? Bool ?? false)
        case "webhook":
            guard let urlStr = rule.targetConfig["url"] as? String, let url = URL(string: urlStr) else {
                return (false, nil, "Webhook URL 未配置")
            }
            return await postWebhook(md: md, content: c, url: url,
                                     headers: rule.targetConfig["headers"] as? [String: String] ?? [:])
        default:
            return (false, nil, "未知目标类型 \(rule.target)")
        }
    }

    private func writeMarkdown(md: String, title: String, source: String, dir: String, bySource: Bool) -> (Bool, String?, String?) {
        let fm = FileManager.default
        var targetDir = dir
        if bySource && !source.isEmpty {
            targetDir += "/" + Self.sanitizeFilename(source)
        }
        do {
            try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
            let filename = Self.sanitizeFilename(title).prefix(80) + ".md"
            let path = targetDir + "/" + filename
            try md.write(toFile: path, atomically: true, encoding: .utf8)
            return (true, path, nil)
        } catch {
            return (false, nil, error.localizedDescription)
        }
    }

    private func postWebhook(md: String, content: ExportContent, url: URL, headers: [String: String]) async -> (Bool, String?, String?) {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let payload: [String: Any] = [
            "title": content.title, "url": content.url, "source": content.source,
            "score": content.score ?? 0, "markdown": md,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            return (200..<300).contains(code) ? (true, "HTTP \(code)", nil) : (false, nil, "HTTP \(code)")
        } catch {
            return (false, nil, error.localizedDescription)
        }
    }

    /// 文件名清洗：去掉路径分隔符和文件系统保留字符
    static func sanitizeFilename(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "untitled" : cleaned
    }

    // MARK: 统计（设置页展示）

    func statsFor(ruleId: Int64) -> (delivered: Int, failed: Int) {
        let d = db.scalarInt(
            "SELECT COUNT(*) FROM export_record WHERE rule_id = ? AND status = 'delivered'",
            params: [ruleId]) ?? 0
        let f = db.scalarInt(
            "SELECT COUNT(*) FROM export_record WHERE rule_id = ? AND status = 'failed'",
            params: [ruleId]) ?? 0
        return (d, f)
    }
}
