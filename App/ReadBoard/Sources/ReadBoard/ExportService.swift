import Foundation

// MARK: - 导出体系（后处理板块）
// 规则 = 筛选条件(criteria) + 触发时机(trigger_on) + 目标(target)。
// 管线完成后 PipelineWorker 调 runPending(trigger:)；设置页可手动 runFor(ruleId)。
// 幂等：export_record UNIQUE(rule_id, content_id)，重跑不产生重复交付。

public struct ExportRule: Identifiable {
    public let id: Int64
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

public final class ExportService: @unchecked Sendable {

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
        return db.lastInsertId()  // 走写连接 C API（读写分离后 scalarInt 的读连接拿不到本次插入的 rowid）
    }

    func deleteRule(id: Int64) {
        db.execute("DELETE FROM export_rule WHERE id = ?", params: [id])  // record 级联删
    }

    /// 清除某规则的已交付记录（下次「立即执行」全量重导）。
    /// 修 P1-11：幂等键 (rule_id, content_id) 不含 criteria/target——改规则配置后
    /// 「立即执行」把历史全跳过看似没反应。提供清除入口让用户改了配置能重导，
    /// 不用删规则重建。
    func resetDelivered(ruleId: Int64) {
        db.execute("DELETE FROM export_record WHERE rule_id = ?", params: [ruleId])
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
        // 分页跑完所有候选（此前 LIMIT 200 + 失败项重查 → 游标永不前进，积压 >200 时只反复处理同一批）
        var beforeId: Int64? = nil
        var totalProcessed = 0
        while totalProcessed < 2000 {   // 单轮总量保险丝
            let candidates = matchingContents(rule: rule, contentId: contentId, beforeId: beforeId)
            guard !candidates.isEmpty else { break }
            for c in candidates {
                let (ok, dest, err) = await deliver(rule: rule, c: c)
                db.execute("""
                    INSERT OR REPLACE INTO export_record (rule_id, content_id, status, destination, error)
                    VALUES (?,?,?,?,?)
                    """, params: [rule.id, c.id, ok ? "delivered" : "failed", dest, err])
            }
            beforeId = candidates.last?.id
            totalProcessed += candidates.count
            // 失败项会重复出现（record 只挡 delivered），靠 beforeId 翻页保证不重查同一页
        }
        db.execute("UPDATE export_rule SET last_run_at = datetime('now') WHERE id = ?", params: [rule.id])
    }

    /// 按 criteria 组装 SQL，只取还没被这条规则成功导出过的内容。
    /// beforeId 翻页游标：取 id < beforeId 的下一页（配合 ORDER BY id DESC）。
    private func matchingContents(rule: ExportRule, contentId: Int64?, beforeId: Int64? = nil) -> [ExportContent] {
        var whereClauses = ["is_duplicate = 0"]
        var params: [Any?] = []
        if let cid = contentId { whereClauses.append("id = ?"); params.append(cid) }
        if let bid = beforeId { whereClauses.append("id < ?"); params.append(bid) }
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

    // MARK: 交付（渲染统一走 ArchiveService，归档 md 是唯一产物）

    /// 去掉正文开头的 YAML frontmatter 块（--- ... ---），防止导出后双重 frontmatter
    static func stripLeadingFrontmatter(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return text }
        // 找第二个独立成行的 ---
        var lines = trimmed.components(separatedBy: "\n")
        guard lines.count > 2 else { return text }
        lines.removeFirst()  // 开头的 ---
        if let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            let body = lines[(end + 1)...].joined(separator: "\n")
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// 交付 = 把归档 md 分发到目标。归档文件是唯一产物（ArchiveService 渲染），
    /// 本服务不再自己渲染——mddir/obsidian 拷贝归档文件，webhook 读归档内容发送。
    /// 内容未归档（没走完管线）：临时渲染内容分发，不落盘不打归档标记
    ///（完成才归档是归档语义，导出只是分发，不该把未完成的标成已归档）。
    private func deliver(rule: ExportRule, c: ExportContent) async -> (Bool, String?, String?) {
        let md: String
        if let archivePath = ArchiveService.shared.archiveFilePath(contentId: c.id),
           FileManager.default.fileExists(atPath: archivePath),
           let content = try? String(contentsOfFile: archivePath, encoding: .utf8) {
            md = content   // 已归档：直接用归档文件（SSOT）
        } else if let rendered = ArchiveService.shared.renderString(contentId: c.id) {
            md = rendered  // 未归档：临时渲染，不落盘不打标记
        } else {
            return (false, nil, "内容不存在")
        }
        switch rule.target {
        case "obsidian", "mddir":
            guard let dir = rule.targetConfig["dir"] as? String, !dir.isEmpty else {
                return (false, nil, "目标目录未配置")
            }
            return writeMarkdown(md: md, title: c.title, source: c.source, contentId: c.id,
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

    private func writeMarkdown(md: String, title: String, source: String, contentId: Int64, dir: String, bySource: Bool) -> (Bool, String?, String?) {
        let fm = FileManager.default
        var targetDir = dir
        if bySource && !source.isEmpty {
            targetDir += "/" + Self.sanitizeFilename(source)
        }
        do {
            try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
            // 同名不同内容防互相覆盖：先按纯标题写，若已存在且内容不同则追加 contentId
            let base = String(Self.sanitizeFilename(title).prefix(80))
            var filename = base + ".md"
            var path = targetDir + "/" + filename
            if fm.fileExists(atPath: path),
               let existing = try? String(contentsOfFile: path, encoding: .utf8), existing != md {
                filename = "\(base)-\(contentId).md"
                path = targetDir + "/" + filename
            }
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
        // webhook 体积上限：多数接收端（飞书/Slack/n8n）对单条 payload 有 1-4MB 限制，
        // 超长转录稿直接打满会被整包拒收。截断正文 + 标注，保住元信息送达。
        let maxBody = 900_000   // ~900KB markdown 上限
        let mdCapped = md.count > maxBody
            ? String(md.prefix(maxBody)) + "\n\n[...正文过长，已截断，完整版见应用内]"
            : md
        let payload: [String: Any] = [
            "title": content.title, "url": content.url, "source": content.source,
            "score": content.score ?? 0, "markdown": mdCapped,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        // 重试 3 次（1s/3s 退避）：网络抖动/临时 5xx 不至于丢导出
        var lastErr = "未知错误"
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(attempt == 1 ? 1_000_000_000 : 3_000_000_000))
            }
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if (200..<300).contains(code) { return (true, "HTTP \(code)", nil) }
                lastErr = "HTTP \(code)"
                // 4xx（除 429）是请求本身问题，重试无意义
                if (400..<500).contains(code), code != 429 { break }
            } catch {
                lastErr = error.localizedDescription
            }
        }
        return (false, nil, lastErr)
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
