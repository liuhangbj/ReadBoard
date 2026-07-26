import Foundation

// MARK: - 评分结果

public struct ScoreResult {
    let depth: Int
    let quality: Int
    let readability: Int
    let total: Int
    let summary: String
}

// MARK: - LLM 管线（评分 + 翻译）

public final class LLMPipeline: @unchecked Sendable {
    private let client = LLMClient()
    private let db = Database.shared

    var isAvailable: Bool { client.isAvailable }

    /// 最近一次 LLM 调用失败的原因（区分 key 失效/限流/超时/解析失败，供 job 记录。
    /// 此前所有错误 catch{return false} 吞掉，job 只记"failed"无法诊断——修 P1-8）
    private(set) var lastError: String? = nil
    private let errorLock = NSLock()
    private func setError(_ msg: String?) {
        errorLock.lock(); lastError = msg; errorLock.unlock()
    }

    /// R5 截断：头尾保留 + 中段裁剪，并在拼接处标注，避免尾部信息无声丢失。
    static func truncateKeepEnds(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let headCount = Int(Double(maxChars) * 0.6)
        let tailCount = Int(Double(maxChars) * 0.3)
        let head = text.prefix(headCount)
        let tail = text.suffix(tailCount)
        let omitted = text.count - headCount - tailCount
        return "\(head)\n\n[中段已省略 \(omitted) 字]\n\n\(tail)"
    }

    // MARK: 评分（移植 rss-curation v4.0-pure 三维评分）

    static let scorePromptTemplate = """
    你是一位专注能源、矿业、宏观经济的独立研究者。对于全社会的经济现象有着广泛的关注，喜欢从各行各业洞见经济运行的逻辑，同时，你是一个拥有跨学科视角的观察者，对于影视音乐、人文历史、科学科技和时尚娱乐都有着广泛而独到的兴趣。

    你评价文章的标准是：分析框架是否清晰、论证逻辑是否完整、信息组织是否有条理。你不关心作者的立场是否正确，也不在乎预测是否应验，更不在意文章是否推广了某种理论或产品——你只关心文章本身的质量。

    请对以下文章进行客观评分。评分标准严格但聚焦框架质量。

    评分维度（总分100分）：

    1. 内容深度（0-40分）—— 评价分析框架的质量：
       - 35-40分：有原创理论框架、跨学科深度分析、或系统性综述能力
       - 28-34分：有清晰的论证层次和逻辑链条，观点扎实
       - 20-27分：普通分析，信息罗列，论证较浅（多数文章在此区间）
       - 10-19分：表面描述，无分析框架，纯叙事
       - 0-9分：毫无结构，明显拼凑或洗稿

    2. 信息质量（0-35分）—— 评价信息组织和来源：
       - 30-35分：数据来源清晰（无论一手还是二手），逻辑自洽，或高质量的转述/编译/综述
       - 24-29分：有信息支撑，逻辑清晰，但深度一般
       - 16-23分：信息来源模糊，论证不够充分
       - 8-15分：缺乏事实支撑，主观臆断较多
       - 0-7分：虚假信息、明显错误、或完全无信息价值

    3. 可读性（0-25分）—— 评价表达和结构：
       - 22-25分：结构精妙，语言精炼，层次分明
       - 18-21分：结构清晰，表达流畅，阅读无障碍
       - 12-17分：结构松散，啰嗦重复，逻辑跳跃
       - 6-11分：难以阅读，逻辑混乱
       - 0-5分：完全无法阅读，或明显机器生成

    重要原则：
    - 不评价预测正确性：如对某企业家的分析，即使事后证明判断有误，只要当时的分析框架清晰、逻辑完整，就不应因此扣分
    - 不排斥理论推广：如介绍某理论的文章，只要理论阐述清晰、案例组织有条理，就不应因为是"软广"而扣分
    - 硬性降级规则（满足任一，总分最高不超过55分）：
      * 纯产品推销，无分析内容（注意：理论介绍+案例分析不算纯推销）
      * 新闻资讯简单罗列，无任何分析框架
      * 纯情绪化宣泄，无任何事实或逻辑支撑
      * 内容明显未完成或截断

    文章标题：{title}

    文章内容：
    {content}

    严格输出JSON（不要其他内容，不要 markdown 代码块）：
    {"depth": 0-40, "quality": 0-35, "readability": 0-25, "total": 0-100, "summary": "150字以内中文摘要，提炼核心观点和数据"}
    """

    /// 对单条内容打分并写库。返回是否成功。
    @discardableResult
    func score(contentId: Int64, title: String, body: String) async -> Bool {
        guard isAvailable else { return false }
        // R5 正文截断：头尾保留+中段省略（评分不需全文，控制 token 且不丢尾部）
        let truncated = Self.truncateKeepEnds(body, maxChars: 12000)
        let prompt = Self.scorePromptTemplate
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{content}", with: truncated)
        do {
            let (text, model) = try await client.chat(
                messages: [ChatMessage(role: "user", content: prompt)],
                temperature: 0.3, maxTokens: 1024)
            guard let result = Self.parseScoreJSON(text) else {
                setError("评分结果解析失败（LLM 输出非预期 JSON）")
                return false
            }
            let ok = saveScore(contentId: contentId, result: result, model: model)
            if ok { setError(nil) } else { setError("评分写库失败") }
            return ok
        } catch {
            setError(Self.describeError(error))
            return false
        }
    }

    /// 把 LLM 调用错误转成可读诊断（区分 key 失效/限流/超时/网络/解析——决定该不该重试）
    static func describeError(_ error: Error) -> String {
        if let e = error as? LLMError {
            switch e {
            case .noProvider: return "无可用 LLM 配置（三槽全空且 .env 无 key）"
            case .httpError(let code, let body):
                if code == 401 || code == 403 { return "LLM 鉴权失败（\(code)，key 失效或未充值）" }
                if code == 429 { return "LLM 限流（429，可稍后重试）" }
                if code == 400 { return "LLM 请求格式错误（400，可能是模型名已下线）：\(body.prefix(80))" }
                return "LLM HTTP \(code)：\(body.prefix(80))"
            case .emptyResponse: return "LLM 返回空响应"
            case .invalidJSON: return "LLM 返回非 JSON"
            default: return "LLM 错误：\(error.localizedDescription)"
            }
        }
        return "网络/未知错误：\(error.localizedDescription)"
    }

    static func parseScoreJSON(_ text: String) -> ScoreResult? {
        // 提取第一个 {...} 块（LLM 可能包裹多余文本）
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        let jsonStr = String(text[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func int(_ k: String) -> Int { (obj[k] as? Int) ?? (obj[k] as? Double).map { Int($0) } ?? 0 }
        // R5: 维度校验——LLM 偶发幻觉会输出超上限的分值（如 depth=95），导致总分失真。
        // 各维度钳制到 prompt 约定的上限：depth≤40 / quality≤35 / readability≤25
        let depth = min(max(int("depth"), 0), 40)
        let quality = min(max(int("quality"), 0), 35)
        let readability = min(max(int("readability"), 0), 25)
        var total = int("total")
        // total 不可信（可能超 100 或与分项不符）时以分项之和为准
        let sum = depth + quality + readability
        if total <= 0 || total > 100 || abs(total - sum) > 10 { total = sum }
        total = min(max(total, 0), 100)
        let summary = (obj["summary"] as? String) ?? ""
        return ScoreResult(depth: depth, quality: quality, readability: readability, total: total, summary: summary)
    }

    private func saveScore(contentId: Int64, result: ScoreResult, model: String) -> Bool {
        // 三维明细存 meta.score_detail
        let detail: [String: Any] = [
            "depth": result.depth, "quality": result.quality, "readability": result.readability,
        ]
        let detailJson = (try? JSONSerialization.data(withJSONObject: detail))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // meta 合并：读出现有 meta，塞入 score_detail
        mergeMetaScoreDetail(contentId: contentId, detailJson: detailJson)
        return db.execute(
            "UPDATE content SET llm_score = ?, llm_summary = ?, llm_model = ?, llm_processed_at = datetime('now') WHERE id = ?",
            params: [result.total, result.summary, model, contentId])
    }

    private func mergeMetaScoreDetail(contentId: Int64, detailJson: String) {
        // 简化处理：meta 若为 {} 直接写入含 score_detail；否则尝试注入
        var current = "{}"
        if let existing = db.scalarString("SELECT meta FROM content WHERE id = ?", params: [contentId]), !existing.isEmpty {
            current = existing
        }
        var metaObj = (try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any]) ?? [:]
        if let detailObj = try? JSONSerialization.jsonObject(with: Data(detailJson.utf8)) {
            metaObj["score_detail"] = detailObj
        }
        if let data = try? JSONSerialization.data(withJSONObject: metaObj),
           let str = String(data: data, encoding: .utf8) {
            db.execute("UPDATE content SET meta = ? WHERE id = ?", params: [str, contentId])
        }
    }

    // MARK: 翻译（收编 Follo 全文翻译能力）

    /// 生成单篇摘要，写入 llm_summary。返回是否成功。
    /// 摘要管线独立于评分——不评分也能只出摘要。
    @discardableResult
    func summarize(contentId: Int64, title: String, body: String) async -> Bool {
        guard isAvailable else { return false }
        guard let text = await summarizeRaw(title: title, body: body) else { return false }
        return db.execute(
            "UPDATE content SET llm_summary = ?, llm_processed_at = datetime('now') WHERE id = ?",
            params: [text, contentId])
    }

    /// 生成摘要文本（不写库），供转录等管线复用。
    func summarizeRaw(title: String, body: String) async -> String? {
        guard isAvailable else { return nil }
        let truncated = Self.truncateKeepEnds(body, maxChars: 12000)
        let prompt = """
        你是一位专注能源、矿业、宏观经济的独立研究者，同时对影视音乐、人文历史、科学科技有广泛兴趣。
        请为以下内容写一段中文摘要，要求：
        - 150 字以内
        - 提炼核心观点和关键数据，不要复述背景
        - 直接输出摘要正文，不要"本文讲述了"这类开头

        标题：\(title)

        内容：
        \(truncated)
        """
        do {
            let (out, _) = try await client.chat(
                messages: [ChatMessage(role: "user", content: prompt)],
                temperature: 0.3, maxTokens: 512)
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { setError("摘要返回空"); return nil }
            setError(nil)
            return trimmed
        } catch {
            setError(Self.describeError(error))
            return nil
        }
    }

    /// 把任意文本翻译成目标语言，返回译文（不写库）。供转录管线复用。
    /// 短文本单次翻；长文本（>15000 字，如长转录稿）按段分块翻译再拼接，不静默截断丢内容。
    func translateRaw(_ text: String, targetLang: String = "中文") async -> String? {
        guard isAvailable else { return nil }
        // 长文本走分块，保住全文（转录稿 1-2 小时节目轻松破 15000 字）
        if text.count > 15000 {
            return await translateChunked(text, targetLang: targetLang)
        }
        return await translateSingle(text, targetLang: targetLang)
    }

    /// 单次翻译（<=15000 字）
    private func translateSingle(_ text: String, targetLang: String) async -> String? {
        let prompt = """
        你是一位专业的翻译。请将以下内容完整翻译成\(targetLang)，要求：
        - 保留原文的段落结构、数据、专有名词
        - 语言流畅自然，符合中文表达习惯，不是逐字直译
        - 直接输出译文，不要任何解释或"以下是翻译"之类的话

        内容：
        \(text)
        """
        do {
            let (out, _) = try await client.chat(
                messages: [ChatMessage(role: "user", content: prompt)],
                temperature: 0.3, maxTokens: 4096)
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    /// 分块翻译：按段落边界切 ~12000 字一块，逐块翻译后拼接。单块失败则该块保留原文，
    /// 不至于整篇丢。块间无上下文，靠段落边界保证语义相对完整。
    private func translateChunked(_ text: String, targetLang: String) async -> String? {
        let chunks = Self.splitByParagraph(text, maxChars: 12000)
        guard !chunks.isEmpty else { return nil }
        var parts: [String] = []
        var anyOK = false
        for (i, chunk) in chunks.enumerated() {
            if let t = await translateSingle(chunk, targetLang: targetLang) {
                parts.append(t)
                anyOK = true
            } else {
                // 单块失败：保留原文块 + 标注，不静默丢
                parts.append("[第 \(i + 1) 段翻译失败，保留原文]\n" + chunk)
            }
        }
        return anyOK ? parts.joined(separator: "\n\n") : nil
    }

    /// 按段落（空行）切分，每块不超过 maxChars；单段超限则硬截（保头尾）
    static func splitByParagraph(_ text: String, maxChars: Int) -> [String] {
        let paras = text.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var cur = ""
        for p in paras {
            let candidate = cur.isEmpty ? p : cur + "\n\n" + p
            if candidate.count > maxChars {
                if !cur.isEmpty { chunks.append(cur); cur = "" }
                // 单段就超限：按 truncateKeepEnds 收进一块
                if p.count > maxChars {
                    chunks.append(truncateKeepEnds(p, maxChars: maxChars))
                } else {
                    cur = p
                }
            } else {
                cur = candidate
            }
        }
        if !cur.isEmpty { chunks.append(cur) }
        return chunks
    }

    /// 把内容全文翻译成中文，写入 llm_translated_md
    /// 长文（>15000 字）走分块翻译，不再静默截断丢尾部（此前 truncateKeepEnds(15000) 会丢超长文的后半）
    @discardableResult
    func translate(contentId: Int64, title: String, body: String, targetLang: String = "中文") async -> Bool {
        guard isAvailable else { return false }
        var translated: String?
        var usedModel = ""
        var partial = false   // 分块翻译有块失败保留原文 → 译文不完整，标记到 meta 供 UI/导出判断
        if body.count > 15000 {
            // 分块：先翻标题（短），正文按段落切块逐块翻
            let titleT = await translateSingle(title, targetLang: targetLang) ?? title
            guard let bodyT = await translateChunked(body, targetLang: targetLang) else { return false }
            translated = titleT + "\n\n" + bodyT
            partial = bodyT.contains("[第 ") && bodyT.contains(" 段翻译失败，保留原文]")
        } else {
            // 翻译不截断——完整正文进 prompt（截断的 [中段已省略] 会被 LLM 翻译进去）
            // 输出保留原格式的译文（markdown）——阅读器译文/原文两个标签，译文保持原有格式
            let prompt = """
            你是一位专业的翻译。请将以下文章完整翻译成\(targetLang)，要求：
            - 保留原文的段落结构、数据、专有名词、图片链接（![alt](url) 格式保留，不翻译 alt 文本）
            - 保留原文的 markdown 格式（## 标题、**加粗**、*斜体*、- 列表、> 引用等）
            - 语言流畅自然，符合中文表达习惯，不是逐字直译
            - 标题也一并翻译，放在第一行（只输出译文标题，不输出原文标题，不要"标题："前缀）
            - 直接输出译文，不要任何解释或"以下是翻译"之类的话

            标题：\(title)

            正文：
            \(body)
            """
            do {
                let (text, model) = try await client.chat(
                    messages: [ChatMessage(role: "user", content: prompt)],
                    temperature: 0.3, maxTokens: 4096)
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                translated = t.isEmpty ? nil : t
                usedModel = model
            } catch {
                setError(Self.describeError(error))
                return false
            }
        }
        guard let final = translated, !final.isEmpty else {
            if lastError == nil { setError("翻译结果为空") }
            return false
        }
        let ok = db.execute(
            "UPDATE content SET llm_translated_md = ?, llm_model = ?, llm_processed_at = datetime('now') WHERE id = ?",
            params: [final, usedModel, contentId])
        if ok { setError(nil) } else { setError("译文写库失败") }
        if ok, partial {
            // 部分翻译标记：meta.translation_partial=1（不改变 hasTranslated 判定，
            // 但 UI/导出可提示"此译文不完整"）
            db.execute("""
                UPDATE content SET meta = json_set(COALESCE(meta, '{}'), '$.translation_partial', 1)
                WHERE id = ?;
                """, params: [contentId])
        }
        return ok
    }
}
