import Foundation

// MARK: - 导出体系（后处理板块）
// 规则 = 筛选条件(criteria) + 触发时机(trigger_on) + 目标(target)。
// 管线完成后 PipelineWorker 调 runPending(trigger:)；设置页可手动 runFor(ruleId)。
// 幂等：export_record UNIQUE(rule_id, content_id)，重跑不产生重复交付。

/// 导出平台配置（各平台的登录凭证/预设位置，存 UserDefaults）
/// class 引用类型——SwiftUI Binding 需要可变属性
public final class ExportPlatformConfig: @unchecked Sendable {
    static let shared = ExportPlatformConfig()
    private init() {}

    // Cubox
    var cuboxToken: String {
        get { UserDefaults.standard.string(forKey: "export.cubox.token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "export.cubox.token") }
    }
    // Instapaper
    var instapaperUser: String {
        get { UserDefaults.standard.string(forKey: "export.instapaper.user") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "export.instapaper.user") }
    }
    var instapaperPass: String {
        get { UserDefaults.standard.string(forKey: "export.instapaper.pass") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "export.instapaper.pass") }
    }
    // Readwise
    var readwiseToken: String {
        get { UserDefaults.standard.string(forKey: "export.readwise.token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "export.readwise.token") }
    }
    // Notion
    var notionToken: String {
        get { UserDefaults.standard.string(forKey: "export.notion.token") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "export.notion.token") }
    }
    var notionDatabaseId: String {
        get { UserDefaults.standard.string(forKey: "export.notion.databaseId") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "export.notion.databaseId") }
    }
    // Obsidian
    var obsidianDir: String {
        get { UserDefaults.standard.string(forKey: "export.obsidian.dir") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "export.obsidian.dir") }
    }
    // Webhook
    var webhookURL: String {
        get { UserDefaults.standard.string(forKey: "export.webhook.url") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "export.webhook.url") }
    }
    var webhookHeaders: [String: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "export.webhook.headers"),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
            return obj
        }
        set {
            if let data = try? JSONSerialization.data(withJSONObject: newValue) {
                UserDefaults.standard.set(data, forKey: "export.webhook.headers")
            }
        }
    }
}

public struct ExportRule: Identifiable {
    public let id: Int64
    var name: String
    var enabled: Bool
    var criteria: Criteria
    var triggerOn: String          // score / translate / transcribe / manual / archive（入库触发）
    var target: String             // obsidian / mddir / webhook / cubox / instapaper / readwise / notion
    var targetConfig: [String: Any]
    var overwrite: Bool = true     // 覆盖原文件（true）vs 生成新文件（false，加时间戳）
    /// frontmatter 包含的字段（nil = 默认全部：title/source/author/url/score/published/archived）
    var frontmatterFields: [String]? = nil
    /// 标题命名模板（{title}/{date}/{id} 占位符，默认 "{title}-{id}"）
    var titleTemplate: String = "{title}-{id}"
    var lastRunAt: String?

    static func == (lhs: ExportRule, rhs: ExportRule) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    struct Criteria: Hashable {
        var minScore: Int? = nil
        var sourceIds: [Int64]? = nil
        var folderIds: [Int64]? = nil          // 文件夹筛选（多选 OR）
        var requireTranslated = false
        var requireTranscribed = false
        var requireSummary = false
        var starredOnly = false
        var readStatus: String? = nil          // "read" / "unread" / nil（全部）
        var keywords: [String]? = nil          // 标题/正文关键词（AND）
        var contentTypes: [String]? = nil      // article/podcast/video（OR）
        var languages: [String]? = nil         // zh/en（OR）

        static func from(json: String) -> Criteria {
            var c = Criteria()
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return c }
            c.minScore = obj["min_score"] as? Int
            c.sourceIds = (obj["source_ids"] as? [NSNumber])?.map { $0.int64Value }
            c.folderIds = (obj["folder_ids"] as? [NSNumber])?.map { $0.int64Value }
            c.requireTranslated = obj["require_translated"] as? Bool ?? false
            c.requireTranscribed = obj["require_transcribed"] as? Bool ?? false
            c.requireSummary = obj["require_summary"] as? Bool ?? false
            c.starredOnly = obj["starred_only"] as? Bool ?? false
            c.readStatus = obj["read_status"] as? String
            c.keywords = obj["keywords"] as? [String]
            c.contentTypes = obj["content_types"] as? [String]
            c.languages = obj["languages"] as? [String]
            return c
        }

        func toJSON() -> String {
            var obj: [String: Any] = [:]
            if let s = minScore { obj["min_score"] = s }
            if let ids = sourceIds { obj["source_ids"] = ids }
            if let fids = folderIds { obj["folder_ids"] = fids }
            if requireTranslated { obj["require_translated"] = true }
            if requireTranscribed { obj["require_transcribed"] = true }
            if requireSummary { obj["require_summary"] = true }
            if starredOnly { obj["starred_only"] = true }
            if let rs = readStatus { obj["read_status"] = rs }
            if let kw = keywords { obj["keywords"] = kw }
            if let ct = contentTypes { obj["content_types"] = ct }
            if let lang = languages { obj["languages"] = lang }
            return (try? JSONSerialization.data(withJSONObject: obj))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
    }

    var targetDisplay: String {
        switch target {
        case "obsidian": return "Obsidian 仓库"
        case "mddir": return "Markdown 目录"
        case "webhook": return "Webhook"
        case "cubox": return "Cubox"
        case "instapaper": return "Instapaper"
        case "readwise": return "Readwise"
        case "notebooklm": return "NotebookLM"
        case "notion": return "Notion"
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
        // 文件夹筛选（多选 OR）
        if let fids = rule.criteria.folderIds, !fids.isEmpty {
            whereClauses.append("source_id IN (SELECT id FROM content_source WHERE folder_id IN (\(fids.map { String($0) }.joined(separator: ","))))")
        }
        // 已读状态（read/unread）
        if let rs = rule.criteria.readStatus {
            if rs == "read" { whereClauses.append("read_at IS NOT NULL") }
            else if rs == "unread" { whereClauses.append("read_at IS NULL") }
        }
        // 关键词（标题/正文 AND——多个关键词都要出现）
        if let kws = rule.criteria.keywords, !kws.isEmpty {
            for kw in kws {
                whereClauses.append("(title LIKE ? OR content_md LIKE ? OR excerpt LIKE ?)")
                let pattern = "%\(kw)%"
                params.append(pattern); params.append(pattern); params.append(pattern)
            }
        }
        // 内容类型（article/podcast/video OR）
        if let cts = rule.criteria.contentTypes, !cts.isEmpty {
            let placeholders = cts.map { _ in "?" }.joined(separator: ",")
            whereClauses.append("ctype IN (\(placeholders))")
            params.append(contentsOf: cts.map { $0 as Any? })
        }
        // 语言（zh/en OR）
        if let langs = rule.criteria.languages, !langs.isEmpty {
            let placeholders = langs.map { _ in "?" }.joined(separator: ",")
            whereClauses.append("language IN (\(placeholders))")
            params.append(contentsOf: langs.map { $0 as Any? })
        }
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

    /// 单篇导出（不必遵循规则，直接导出到指定平台）
    /// 用平台预设配置（ExportPlatformConfig）+ 单篇内容 ID 直接 deliver
    func deliverSingle(rule: ExportRule, contentId: Int64) async -> (Bool, String?, String?) {
        // 查单篇内容
        guard let row = db.queryRows("""
            SELECT c.id, c.title, c.url, c.source, c.llm_score, c.llm_summary, c.llm_translated_md, c.content_md, c.published_at
            FROM content c WHERE c.id = ?
            """, params: [contentId]).first else {
            return (false, nil, "内容不存在")
        }
        let c = ExportContent(
            id: Int64(row["id"] ?? "") ?? 0,
            title: row["title"] ?? "",
            url: row["url"] ?? "",
            source: row["source"] ?? "",
            score: Int(row["llm_score"] ?? ""),
            summary: row["llm_summary"],
            translated: row["llm_translated_md"],
            contentMd: row["content_md"],
            publishedAt: row["published_at"] ?? "")
        return await deliver(rule: rule, c: c)
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
                                 dir: dir, bySource: rule.targetConfig["subdir_by_source"] as? Bool ?? false,
                                 overwrite: rule.overwrite,
                                 frontmatterFields: rule.frontmatterFields,
                                 titleTemplate: rule.titleTemplate)
        case "webhook":
            guard let urlStr = rule.targetConfig["url"] as? String, let url = URL(string: urlStr) else {
                return (false, nil, "Webhook URL 未配置")
            }
            return await postWebhook(md: md, content: c, url: url,
                                     headers: rule.targetConfig["headers"] as? [String: String] ?? [:])
        case "cubox":
            return await postToCubox(md: md, content: c, config: rule.targetConfig)
        case "instapaper":
            return await postToInstapaper(content: c, config: rule.targetConfig)
        case "readwise":
            return await postToReadwise(md: md, content: c, config: rule.targetConfig)
        case "notebooklm":
            return await postToNotebookLM(md: md, content: c, config: rule.targetConfig)
        case "notion":
            return await postToNotion(md: md, content: c, config: rule.targetConfig)
        default:
            return (false, nil, "未知目标类型 \(rule.target)")
        }
    }

    // MARK: - 各平台导出实现

    /// Cubox 收藏（API：https://cubox.pro/c/api/save）
    private func postToCubox(md: String, content: ExportContent, config: [String: Any]) async -> (Bool, String?, String?) {
        guard let token = config["token"] as? String, !token.isEmpty else {
            return (false, nil, "Cubox token 未配置")
        }
        let url = URL(string: "https://cubox.pro/c/api/save")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "type": "url",
            "content": content.url,
            "title": content.title,
            "description": content.summary ?? "",
            "tags": ["readboard"],
            "token": token
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                return (true, "cubox://saved", nil)
            } else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(code)"
                return (false, nil, "Cubox 保存失败：\(msg)")
            }
        } catch {
            return (false, nil, "Cubox 请求失败：\(error.localizedDescription)")
        }
    }

    /// Instapaper 保存（API：https://www.instapaper.com/api/add）
    private func postToInstapaper(content: ExportContent, config: [String: Any]) async -> (Bool, String?, String?) {
        guard let username = config["username"] as? String, !username.isEmpty,
              let password = config["password"] as? String, !password.isEmpty else {
            return (false, nil, "Instapaper 用户名/密码未配置")
        }
        var comps = URLComponents(string: "https://www.instapaper.com/api/add")!
        comps.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "url", value: content.url),
            URLQueryItem(name: "title", value: content.title)
        ]
        guard let url = comps.url else { return (false, nil, "Instapaper URL 构造失败") }
        do {
            let (_, resp) = try await URLSession.shared.data(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 201 {
                return (true, "instapaper://saved", nil)
            } else {
                return (false, nil, "Instapaper 保存失败：HTTP \(code)")
            }
        } catch {
            return (false, nil, "Instapaper 请求失败：\(error.localizedDescription)")
        }
    }

    /// Readwise Reader 保存（API：https://readwise.io/api/v3/save/）
    private func postToReadwise(md: String, content: ExportContent, config: [String: Any]) async -> (Bool, String?, String?) {
        guard let token = config["token"] as? String, !token.isEmpty else {
            return (false, nil, "Readwise token 未配置")
        }
        let url = URL(string: "https://readwise.io/api/v3/save/")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "url": content.url,
            "title": content.title,
            "summary": content.summary ?? "",
            "published_date": content.publishedAt,
            "tags": ["readboard"]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 || code == 201 {
                return (true, "readwise://saved", nil)
            } else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(code)"
                return (false, nil, "Readwise 保存失败：\(msg)")
            }
        } catch {
            return (false, nil, "Readwise 请求失败：\(error.localizedDescription)")
        }
    }

    /// NotebookLM 保存（Google NotebookLM API——需 OAuth token）
    private func postToNotebookLM(md: String, content: ExportContent, config: [String: Any]) async -> (Bool, String?, String?) {
        guard let token = config["token"] as? String, !token.isEmpty else {
            return (false, nil, "NotebookLM token 未配置（Google OAuth）")
        }
        // NotebookLM API 目前未公开稳定端点，先用占位实现
        return (false, nil, "NotebookLM API 暂未开放稳定端点，待 Google 官方支持")
    }

    /// Notion 保存（API：https://api.notion.com/v1/pages）
    private func postToNotion(md: String, content: ExportContent, config: [String: Any]) async -> (Bool, String?, String?) {
        guard let token = config["token"] as? String, !token.isEmpty,
              let databaseId = config["database_id"] as? String, !databaseId.isEmpty else {
            return (false, nil, "Notion token/database_id 未配置")
        }
        let url = URL(string: "https://api.notion.com/v1/pages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        let body: [String: Any] = [
            "parent": ["database_id": databaseId],
            "properties": [
                "Name": ["title": [["text": ["content": content.title]]]],
                "URL": ["url": content.url],
                "Score": ["number": content.score ?? 0]
            ],
            "children": [
                ["object": "block", "type": "paragraph", "paragraph": ["rich_text": [["text": ["content": String(md.prefix(2000))]]]]]
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                return (true, "notion://saved", nil)
            } else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(code)"
                return (false, nil, "Notion 保存失败：\(msg)")
            }
        } catch {
            return (false, nil, "Notion 请求失败：\(error.localizedDescription)")
        }
    }

    private func writeMarkdown(md: String, title: String, source: String, contentId: Int64, dir: String, bySource: Bool, overwrite: Bool = true, frontmatterFields: [String]? = nil, titleTemplate: String = "{title}-{id}") -> (Bool, String?, String?) {
        let fm = FileManager.default
        var targetDir = dir
        if bySource && !source.isEmpty {
            targetDir += "/" + Self.sanitizeFilename(source)
        }
        do {
            try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
            // 按模板生成文件名：{title}/{date}/{id} 占位符替换
            let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
            let filenameBase = titleTemplate
                .replacingOccurrences(of: "{title}", with: Self.sanitizeFilename(title).prefix(80).description)
                .replacingOccurrences(of: "{date}", with: String(dateStr))
                .replacingOccurrences(of: "{id}", with: String(contentId))
            var filename = filenameBase + ".md"
            var path = targetDir + "/" + filename
            if fm.fileExists(atPath: path) {
                if overwrite {
                    // 覆盖原文件：直接写（重入库更新内容）
                    try md.write(toFile: path, atomically: true, encoding: .utf8)
                    return (true, path, nil)
                } else {
                    // 生成新文件：加时间戳后缀（保留历史版本）
                    let timestamp = ISO8601DateFormatter().string(from: Date())
                        .replacingOccurrences(of: ":", with: "-")
                        .prefix(19)
                    filename = "\(filenameBase)-\(timestamp).md"
                    path = targetDir + "/" + filename
                }
            }
            // 按配置转换 frontmatter（有则增补/无则生成）
            let finalMd = transformFrontmatter(md: md, title: title, source: source, contentId: contentId, fields: frontmatterFields)
            try finalMd.write(toFile: path, atomically: true, encoding: .utf8)
            return (true, path, nil)
        } catch {
            return (false, nil, error.localizedDescription)
        }
    }

    /// 按配置转换 frontmatter：有 frontmatter 则增补/转换字段，无则生成插入顶部
    private func transformFrontmatter(md: String, title: String, source: String, contentId: Int64, fields: [String]?) -> String {
        let defaultFields = ["title", "source", "author", "url", "score", "published", "archived"]
        let includeFields = fields ?? defaultFields
        // 生成 frontmatter 内容
        var frontmatter = "---\n"
        if includeFields.contains("title") { frontmatter += "title: \"\(title.replacingOccurrences(of: "\"", with: "\\\""))\"\n" }
        if includeFields.contains("source") { frontmatter += "source: \"\(source.replacingOccurrences(of: "\"", with: "\\\""))\"\n" }
        if includeFields.contains("archived") { frontmatter += "archived: true\n" }
        frontmatter += "---\n\n"
        // 检查 md 是否已有 frontmatter
        if md.hasPrefix("---") {
            // 有 frontmatter：剥掉旧的，插入新的（转换）
            let stripped = Self.stripLeadingFrontmatter(md)
            return frontmatter + stripped
        } else {
            // 无 frontmatter：直接插入顶部（生成）
            return frontmatter + md
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
