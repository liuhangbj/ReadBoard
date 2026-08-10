import Foundation

// MARK: - 评分结果

public struct ScoreResult {
    let depth: Int
    let quality: Int
    let readability: Int
    let total: Int
    let summary: String
}

/// 翻译+评分+摘要 一次 LLM 调用的完整结果
public struct TranslateFullResult {
    let title: String
    let translation: String
    let depth: Int
    let quality: Int
    let readability: Int
    let total: Int
    let summary: String
}

// MARK: - LLM 管线（评分 + 翻译）

public final class LLMPipeline: @unchecked Sendable {
    /// 单次长译文容易让推理模型把输出预算耗在 reasoning，最终 content 为空。
    /// 超过此长度即按段落切块，优先保证可靠产出而不是坚持单次请求。
    static let maxSingleTranslationChars = 6_000

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

    {custom_instruction}

    文章标题：{title}

    文章内容：
    {content}

    严格输出JSON（不要其他内容，不要 markdown 代码块）：
    {"depth": 0-40, "quality": 0-35, "readability": 0-25, "total": 0-100, "summary": "150字以内中文摘要，提炼核心观点和数据"}
    """

    /// 对单条内容做 AI 评分并写库。返回是否成功。
    @discardableResult
    func score(contentId: Int64, title: String, body: String) async -> Bool {
        guard isAvailable else { return false }
        // R5 正文截断：头尾保留+中段省略（评分不需全文，控制 token 且不丢尾部）
        let truncated = Self.truncateKeepEnds(body, maxChars: 12000)
        let prompt = Self.scorePromptTemplate
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{content}", with: truncated)
            .replacingOccurrences(of: "{custom_instruction}",
                                  with: AIPromptSettings.instructionBlock(for: .score))
        do {
            let (text, model) = try await client.chat(
                messages: [ChatMessage(role: "user", content: prompt)],
                maxTokens: 1024)
            guard !Task.isCancelled else { setError("任务已取消"); return false }
            guard let result = Self.parseScoreJSON(text, weights: AIPromptSettings.scoreWeights) else {
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
        if LLMClient.isCancellation(error) { return "任务已取消" }
        if let e = error as? LLMError {
            switch e {
            case .noProvider: return "无可用 LLM 配置（模型配置页未填写任何有效模型）"
            case .httpError(let code, let body):
                if code == 401 || code == 403 { return "LLM 鉴权失败（\(code)，key 失效或未充值）" }
                if code == 429 { return "LLM 限流（429，可稍后重试）" }
                if code == 400 { return "LLM 请求格式错误（400，可能是模型名已下线）：\(body.prefix(80))" }
                return "LLM HTTP \(code)：\(body.prefix(80))"
            case .emptyResponse: return "LLM 返回空响应"
            case .invalidJSON: return "LLM 返回非 JSON"
            case .providersFailed(let detail): return "所有模型均失败：\(detail)"
            }
        }
        return "网络/未知错误：\(error.localizedDescription)"
    }

    static func parseScoreJSON(_ text: String, weights: ScoreWeights = .default) -> ScoreResult? {
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
        // 三维量表保持固定（40/35/25），最终总分由程序按用户权重重算，不信任模型 total。
        let weightedTotal = Double(depth) / 40.0 * Double(weights.depth)
            + Double(quality) / 35.0 * Double(weights.quality)
            + Double(readability) / 25.0 * Double(weights.readability)
        let total = min(max(Int(weightedTotal.rounded()), 0), 100)
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
        请为以下内容生成中文摘要，要求：
        - \(AIPromptSettings.summaryLength) 字以内
        - 提炼核心观点和关键数据，不要复述背景
        - 直接输出摘要内容，不要"本文讲述了"这类开头

        \(AIPromptSettings.instructionBlock(for: .summarize))

        标题：\(title)

        内容：
        \(truncated)
        """
        do {
            let (out, _) = try await client.chat(
                messages: [ChatMessage(role: "user", content: prompt)],
                maxTokens: 512)
            guard !Task.isCancelled else { setError("任务已取消"); return nil }
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
    /// 短文本单次翻；长文本按段分块翻译再拼接，不静默截断丢内容。
    func translateRaw(_ text: String, targetLang: String = "中文") async -> String? {
        guard isAvailable else { return nil }
        if text.count > Self.maxSingleTranslationChars {
            return await translateChunked(text, targetLang: targetLang)
        }
        return await translateSingle(text, targetLang: targetLang)
    }

    /// 单次翻译（不超过 maxSingleTranslationChars）
    private func translateSingle(_ text: String, targetLang: String) async -> String? {
        let outputLanguage = AIPromptSettings.effectiveTranslationLanguage(fallback: targetLang)
        let prompt = """
        你是一位专业的翻译。请将以下内容完整翻译成\(outputLanguage)，要求：
        - 保留原文的段落结构、数据、专有名词
        - 语言流畅自然，符合\(outputLanguage)表达习惯，不是逐字直译
        - 直接输出译文，不要任何解释或"以下是翻译"之类的话

        \(AIPromptSettings.instructionBlock(for: .translate))

        内容：
        \(text)
        """
            do {
                let (out, _) = try await client.chat(
                    messages: [ChatMessage(role: "user", content: prompt)],
                    maxTokens: 16384)
                guard !Task.isCancelled else { setError("任务已取消"); return nil }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { setError("翻译结果为空"); return nil }
            setError(nil)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            setError(Self.describeError(error))
            return nil
        }
    }

    // MARK: - 原文与译文对照（转录稿专用）

    /// 把非中文转录稿翻译成原文与目标语言对照 Markdown。
    /// 转录稿是 whisper 碎句，让 LLM 先合并成通顺段落再对照——顺带提升可读性。
    func translateBilingual(_ text: String) async -> String? {
        await translateBilingual(text, maxChars: 6000)
    }

    /// maxChars 可调：单块越大单次调用越慢、越容易超时/空响应；越小调用越多、块间断点越多。
    /// 实测 6000 字对照单块 15~25s 稳定完成；12000 字在推理模型下曾长时间无输出。
    func translateBilingual(_ text: String, maxChars: Int) async -> String? {
        guard isAvailable else { return nil }
        let chunks = Self.splitByParagraph(text, maxChars: maxChars)
        guard !chunks.isEmpty else { return nil }
        var parts: [String] = []
        for (i, chunk) in chunks.enumerated() {
            guard !Task.isCancelled else { return nil }
            var translated = await translateBilingualSingle(chunk)
            // 单块失败重试一次：瞬时空响应/限流占多数，重试能消除大部分偶发失败。
            if translated == nil, !Task.isCancelled {
                translated = await translateBilingualSingle(chunk)
            }
            guard let translated else {
                setError("双语后处理失败：第 \(i + 1)/\(chunks.count) 块 \(lastError ?? "未知错误")")
                return nil
            }
            parts.append(translated)
        }
        return parts.joined(separator: "\n\n")
    }

    /// 单块中英对照（<=12000 字）。prompt 已实测：英文普通段落 + 中文 `> ` 引用块，格式稳定。
    private func translateBilingualSingle(_ text: String) async -> String? {
        let outputLanguage = AIPromptSettings.effectiveTranslationLanguage()
        let prompt = """
        你是一位专业的翻译。下面是一段非中文音视频转录稿。请输出**原文与\(outputLanguage)对照**版本，要求：
        - 按语义把转录稿组织成自然段落（转录稿是碎句，先合并成通顺的句子再分段）
        - 每段先输出原文（普通段落），紧接一段\(outputLanguage)译文
        - \(outputLanguage)译文必须用 markdown 引用块语法：每行以 `> ` 开头（大于号+空格），原文不用引用块
        - 原文段和译文段之间空一行，段与段之间空一行
        - 不要代码块包裹，不要任何解释或开场白，直接输出对照内容

        \(AIPromptSettings.instructionBlock(for: .transcribe))

        转录稿：
        \(text)
        """
        do {
            let (out, _) = try await client.chat(
                messages: [ChatMessage(role: "user", content: prompt)],
                maxTokens: 16384)
            guard !Task.isCancelled else { return nil }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                setError("双语翻译返回空内容")
                return nil
            }
            setError(nil)
            return trimmed
        } catch {
            setError(Self.describeError(error))
            return nil
        }
    }

    // MARK: - 原语言转录稿整理

    /// 转录稿交给 LLM 用原语言整理，但不翻译、不总结、不删减信息。
    /// 长稿沿用分块策略；单块失败保留 Whisper 原稿，不让后处理失败拖垮整次转录。
    func polishTranscript(_ text: String) async -> String? {
        guard isAvailable else { return nil }
        let chunks = Self.splitByParagraph(text, maxChars: 6000)
        guard !chunks.isEmpty else { return nil }
        var parts: [String] = []
        for (i, chunk) in chunks.enumerated() {
            guard !Task.isCancelled else { return nil }
            var polished = await polishTranscriptSingle(chunk)
            if polished == nil, !Task.isCancelled {
                polished = await polishTranscriptSingle(chunk)
            }
            guard let polished else {
                setError("转录稿整理失败：第 \(i + 1)/\(chunks.count) 块 \(lastError ?? "未知错误")")
                return nil
            }
            parts.append(polished)
        }
        return parts.joined(separator: "\n\n")
    }

    private func polishTranscriptSingle(_ text: String) async -> String? {
        let prompt = """
        你是一位严谨的口述稿编辑。请使用原稿语言整理下面的音视频转录稿，要求：
        - 只做原语言文本整理，绝对不要翻译成其他语言
        - 修复明显的断句和标点，把 Whisper 产生的碎句合并成通顺句子
        - 按语义组织成自然段落，保留原有叙述顺序
        - 保留全部观点、事实、数字、专有名词和语气；不要总结、扩写或添加原文没有的信息
        - 仅删除明确的识别重复和无意义口头语，不要删减有效内容
        - 不要代码块、标题、解释或开场白，直接输出整理后的中文稿

        \(AIPromptSettings.instructionBlock(for: .transcribe))

        转录稿：
        \(text)
        """
        do {
            let (out, _) = try await client.chat(
                messages: [ChatMessage(role: "user", content: prompt)],
                maxTokens: 16384)
            guard !Task.isCancelled else { return nil }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                setError("转录稿整理返回空内容")
                return nil
            }
            setError(nil)
            return trimmed
        } catch {
            setError(Self.describeError(error))
            return nil
        }
    }


    /// 分块翻译：按段落边界切至安全长度，逐块翻译后拼接。单块失败则该块保留原文，
    /// 不至于整篇丢。块间无上下文，靠段落边界保证语义相对完整。
    private func translateChunked(_ text: String, targetLang: String) async -> String? {
        let chunks = Self.translationChunks(text)
        guard !chunks.isEmpty else { return nil }
        var parts: [String] = []
        var anyOK = false
        var failures: [String] = []
        for (i, chunk) in chunks.enumerated() {
            guard !Task.isCancelled else { return nil }
            if let t = await translateSingle(chunk, targetLang: targetLang) {
                parts.append(t)
                anyOK = true
            } else {
                failures.append("第 \(i + 1) 块：\(lastError ?? "未知错误")")
                // 单块失败：保留原文块 + 标注，不静默丢
                parts.append("[第 \(i + 1) 段翻译失败，保留原文]\n" + chunk)
            }
        }
        guard anyOK else {
            setError("分块翻译全部失败：" + failures.joined(separator: "；"))
            return nil
        }
        setError(nil)
        return parts.joined(separator: "\n\n")
    }

    static func translationChunks(_ text: String) -> [String] {
        splitByParagraph(text, maxChars: maxSingleTranslationChars)
    }

    /// 按段落（空行）切分，每块不超过 maxChars；单段超限时连续切块，保证全文不丢。
    static func splitByParagraph(_ text: String, maxChars: Int) -> [String] {
        guard maxChars > 0 else { return text.isEmpty ? [] : [text] }
        let paras = text.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var cur = ""
        for p in paras {
            let candidate = cur.isEmpty ? p : cur + "\n\n" + p
            if candidate.count > maxChars {
                if !cur.isEmpty { chunks.append(cur); cur = "" }
                // Whisper 常输出没有空行的超长单段；必须连续切块，不能截断中间内容。
                if p.count > maxChars {
                    var start = p.startIndex
                    while start < p.endIndex {
                        let end = p.index(start, offsetBy: maxChars, limitedBy: p.endIndex) ?? p.endIndex
                        chunks.append(String(p[start..<end]))
                        start = end
                    }
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

    // MARK: 翻译+评分+摘要（整合调用，一条 LLM 请求全产出，按开关回写）

    /// 整合 prompt：翻译 + 三维评分 + 摘要。token 仅多 ~200 output（评分维度+摘要），
    /// 但省掉一次独立 score 调用（~12000 token input），净省 90%+ 重复输入开销。
    static let translateFullPromptTemplate = """
    你是一位专业的翻译兼独立研究者。请对以下文章完成三件事：
    1. 全文翻译成{translation_language}（保留 markdown 格式、段落结构、数据、专有名词）
    2. 按给定维度评分
    3. 提炼 {summary_length} 字以内中文摘要

    翻译要求：
    - 保留原文 markdown 格式（## 标题、**加粗**、- 列表、> 引用等）
    - 保留图片链接 (![alt](url))，不翻译 alt 文本
    - 语言流畅自然，不是逐字直译
    - 标题放在第一行（只输出译文标题，不要"标题："前缀）

    {translation_custom_instruction}

    评分维度（总分 100）：
    - depth 0-40：分析框架是否清晰
    - quality 0-35：论证逻辑是否完整
    - readability 0-25：信息组织是否有条理

    {score_custom_instruction}

    摘要要求：提炼核心观点和关键数据，控制在 {summary_length} 字以内。

    {summary_custom_instruction}

    严格输出 JSON（不要 markdown 代码块，不要其他文字）：
    {"title": "{translation_language}标题", "translation": "翻译全文(含 markdown)", "depth": 0-40, "quality": 0-35, "readability": 0-25, "total": 0-100, "summary": "{summary_length}字以内中文摘要"}

    标题：{title}

    正文：
    {content}
    """

    /// 整合翻译+评分+摘要，一次 LLM 调用。根据 policy 决定回写哪些字段。
    @discardableResult
    func translateFull(contentId: Int64, title: String, body: String, policy: PipelinePolicy) async -> Bool {
        // Worker 的评分+摘要+翻译整合调用仍保留原有 15,000 字上限，避免普通文章
        // 因可靠性修复退化成三次独立请求；手动纯翻译则使用更保守的 6,000 字分块。
        guard isAvailable, body.count <= 15_000 else {
            // 长文走旧路径：分块翻译 + 可选独立评分/摘要（整合 prompt 太长会炸）
            return await translateLongWithPolicy(contentId: contentId, title: title, body: body, policy: policy)
        }
        let prompt = Self.translateFullPromptTemplate
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{content}", with: body)
            .replacingOccurrences(of: "{summary_length}",
                                  with: String(AIPromptSettings.summaryLength))
            .replacingOccurrences(of: "{translation_language}",
                                  with: AIPromptSettings.effectiveTranslationLanguage())
            .replacingOccurrences(of: "{translation_custom_instruction}",
                                  with: AIPromptSettings.instructionBlock(for: .translate))
            .replacingOccurrences(of: "{score_custom_instruction}",
                                  with: policy.autoScore
                                    ? AIPromptSettings.instructionBlock(for: .score) : "")
            .replacingOccurrences(of: "{summary_custom_instruction}",
                                  with: policy.autoSummarize
                                    ? AIPromptSettings.instructionBlock(for: .summarize) : "")
        do {
            let (text, model) = try await client.chat(
                messages: [ChatMessage(role: "user", content: prompt)],
                maxTokens: 16384)
            guard !Task.isCancelled else { setError("任务已取消"); return false }
            guard let result = Self.parseTranslateFullJSON(
                text, weights: AIPromptSettings.scoreWeights,
                sourceLength: body.count) else {
                setError("整合翻译结果无效（JSON 异常、译文为空或明显不完整）")
                return false
            }
            return saveTranslateFull(
                contentId: contentId, result: result, sourceMarkdown: body,
                model: model, policy: policy)
        } catch {
            setError(Self.describeError(error))
            return false
        }
    }

    /// 长文降级：分块翻译（不走整合 prompt），再按开关分开跑评分/摘要
    private func translateLongWithPolicy(contentId: Int64, title: String, body: String, policy: PipelinePolicy) async -> Bool {
        let translated = await translate(contentId: contentId, title: title, body: body)
        let translationError = lastError
        guard !Task.isCancelled else { setError("任务已取消"); return false }
        if policy.autoScore {
            let _ = await score(contentId: contentId, title: title, body: body)
        }
        guard !Task.isCancelled else { setError("任务已取消"); return false }
        if policy.autoSummarize {
            let _ = await summarize(contentId: contentId, title: title, body: body)
        }
        if !translated { setError(translationError ?? "翻译失败") }
        return translated
    }

    static func parseTranslateFullJSON(
        _ text: String, weights: ScoreWeights = .default,
        sourceLength: Int? = nil
    ) -> TranslateFullResult? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        let jsonStr = String(text[start...end])
        // 翻译正文可能含未转义引号，用宽松解析 + JSONSerialization 容错
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func int(_ k: String) -> Int { (obj[k] as? Int) ?? (obj[k] as? Double).map { Int($0) } ?? 0 }
        let depth = min(max(int("depth"), 0), 40)
        let quality = min(max(int("quality"), 0), 35)
        let readability = min(max(int("readability"), 0), 25)
        let weightedTotal = Double(depth) / 40.0 * Double(weights.depth)
            + Double(quality) / 35.0 * Double(weights.quality)
            + Double(readability) / 25.0 * Double(weights.readability)
        let total = min(max(Int(weightedTotal.rounded()), 0), 100)
        guard let translation = obj["translation"] as? String,
              !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if let sourceLength {
            // 完整译文不应短到只剩一句拒绝或说明。10% 且封顶 1000 字是保守下限，
            // 用于挡住占位答复，同时兼容中英日韩之间正常的字符数差异。
            let minimumLength = min(max(sourceLength / 10, 20), 1_000)
            if translation.trimmingCharacters(in: .whitespacesAndNewlines).count < minimumLength {
                return nil
            }
        }
        return TranslateFullResult(
            title: (obj["title"] as? String) ?? "",
            translation: translation,
            depth: depth, quality: quality, readability: readability,
            total: total, summary: (obj["summary"] as? String) ?? "")
    }

    /// 按 policy 开关条件回写：翻译/评分/摘要各自判断
    private func saveTranslateFull(
        contentId: Int64,
        result: TranslateFullResult,
        sourceMarkdown: String,
        model: String,
        policy: PipelinePolicy
    ) -> Bool {
        var allOK = true
        if policy.autoTranslate {
            let translation = MarkdownImageReconciler.reconcile(
                translation: result.translation,
                source: sourceMarkdown) ?? result.translation
            let ok = db.execute(
                "UPDATE content SET llm_translated_md = ?, llm_title_translated = ?, llm_model = ?, llm_processed_at = datetime('now') WHERE id = ?",
                params: [translation, result.title.isEmpty ? nil : result.title, model, contentId])
            if !ok { setError("译文写库失败"); allOK = false }
        }
        if policy.autoScore {
            let detail: [String: Any] = ["depth": result.depth, "quality": result.quality, "readability": result.readability]
            if let detailJson = (try? JSONSerialization.data(withJSONObject: detail)).flatMap({ String(data: $0, encoding: .utf8) }) {
                mergeMetaScoreDetail(contentId: contentId, detailJson: detailJson)
            }
            let ok = db.execute(
                "UPDATE content SET llm_score = ?, llm_model = ?, llm_processed_at = datetime('now') WHERE id = ?",
                params: [result.total, model, contentId])
            if !ok { setError("评分写库失败"); allOK = false }
        }
        if policy.autoSummarize {
            let ok = db.execute(
                "UPDATE content SET llm_summary = ?, llm_processed_at = datetime('now') WHERE id = ?",
                params: [result.summary, contentId])
            if !ok { setError("摘要写库失败"); allOK = false }
        }
        if allOK { setError(nil) }
        return allOK
    }

    /// 把内容全文翻译成配置的目标语言，写入 llm_translated_md
    /// 较长正文走分块翻译，避免推理模型耗尽输出预算且不静默截断正文。
    @discardableResult
    func translate(contentId: Int64, title: String, body: String, targetLang: String = "中文") async -> Bool {
        guard isAvailable else { return false }
        let outputLanguage = AIPromptSettings.effectiveTranslationLanguage(fallback: targetLang)
        var translated: String?
        var usedModel = ""
        var partial = false   // 分块翻译有块失败保留原文 → 译文不完整，标记到 meta 供 UI/导出判断
        if body.count > Self.maxSingleTranslationChars {
            // 分块：先翻标题（短），正文按段落切块逐块翻
            let titleT = await translateSingle(title, targetLang: outputLanguage) ?? title
            guard let bodyT = await translateChunked(body, targetLang: outputLanguage) else { return false }
            translated = titleT + "\n\n" + bodyT
            partial = bodyT.contains("[第 ") && bodyT.contains(" 段翻译失败，保留原文]")
        } else {
            // 翻译不截断——完整正文进 prompt（截断的 [中段已省略] 会被 LLM 翻译进去）
            // 输出保留原格式的译文（markdown）——阅读器译文/原文两个标签，译文保持原有格式
            let prompt = """
            你是一位专业的翻译。请将以下文章完整翻译成\(outputLanguage)，要求：
            - 保留原文的段落结构、数据、专有名词、图片链接（![alt](url) 格式保留，不翻译 alt 文本）
            - 保留原文的 markdown 格式（## 标题、**加粗**、*斜体*、- 列表、> 引用等）
            - 语言流畅自然，符合\(outputLanguage)表达习惯，不是逐字直译
            - 标题也一并翻译，放在第一行（只输出译文标题，不输出原文标题，不要"标题："前缀）
            - 直接输出译文，不要任何解释或"以下是翻译"之类的话

            \(AIPromptSettings.instructionBlock(for: .translate))

            标题：\(title)

            正文：
            \(body)
            """
            do {
                let (text, model) = try await client.chat(
                    messages: [ChatMessage(role: "user", content: prompt)],
                    maxTokens: 16384)
                guard !Task.isCancelled else { setError("任务已取消"); return false }
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                translated = t.isEmpty ? nil : t
                usedModel = model
            } catch {
                setError(Self.describeError(error))
                return false
            }
        }
        guard let rawFinal = translated, !rawFinal.isEmpty else {
            if lastError == nil { setError("翻译结果为空") }
            return false
        }
        let final = MarkdownImageReconciler.reconcile(
            translation: rawFinal, source: body) ?? rawFinal
        guard !Task.isCancelled else { setError("任务已取消"); return false }
        // 提取译文第一行作为标题译文（llm_title_translated），供阅读栏中文标题展示。
        // prompt 明确要求「标题也一并翻译，放在第一行」，首行即为译文标题。
        let titleLine = final.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
        let titleT = titleLine.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                         .replacingOccurrences(of: "^标题：\\s*", with: "", options: .regularExpression)
                         .trimmingCharacters(in: .whitespaces)
        let ok = db.execute(
            "UPDATE content SET llm_translated_md = ?, llm_title_translated = ?, llm_model = ?, llm_processed_at = datetime('now') WHERE id = ?",
            params: [final, titleT.isEmpty ? nil : titleT, usedModel, contentId])
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

    /// 翻译播客 feed 简介（content_html 剥标签）→ 写 llm_translated_md（播客「译文」标签）。
    /// 与转录稿（llm_transcript_md）分开存——简介译文和转录稿是两个独立内容。
    @discardableResult
    func translateExcerpt(contentId: Int64, title: String, contentHtml: String) async -> Bool {
        guard isAvailable else { return false }
        let outputLanguage = AIPromptSettings.effectiveTranslationLanguage()
        // 剥标签成纯文本
        var text = contentHtml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        // 一次调用翻标题+简介，用固定分隔符拆开分存两字段（标题→llm_title_translated 供中栏/标题栏，
        // 简介→llm_excerpt_translated 供「译文」标签）
        let prompt = """
        你是一位专业的翻译。请将以下播客/视频的标题和简介翻译成\(outputLanguage)，严格按格式输出：
        第一行只输出\(outputLanguage)标题（不要"标题："前缀，不要原文标题），
        第二行只输出四个等号 ==== （作为分隔符），
        第三行起输出简介的\(outputLanguage)译文。
        语言流畅自然，符合\(outputLanguage)表达习惯，不是逐字直译。不要任何解释或"以下是翻译"之类的话。

        \(AIPromptSettings.instructionBlock(for: .translate))

        标题：\(title)

        简介：
        \(text)
        """
        do {
            let (out, _) = try await client.chat(
                messages: [ChatMessage(role: "user", content: prompt)],
                maxTokens: 4096)
            guard !Task.isCancelled else { setError("任务已取消"); return false }
            let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return false }
            // 按 ==== 分隔符拆标题/简介
            let parts = t.components(separatedBy: "\n====\n")
            var titleT = ""
            var excerptT = t
            if parts.count >= 2 {
                titleT = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                excerptT = parts.dropFirst().joined(separator: "\n====\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // 分存：标题译文 + 简介译文（一次事务两次 UPDATE）
            // 018 迁移已将 podcast llm_translated_md ↔ llm_excerpt_translated 互换，
            // 此后简介翻译统一写 llm_translated_md（与全文翻译合并，标签/阅读视图共用）
            var ok = true
            if !titleT.isEmpty {
                ok = db.execute("UPDATE content SET llm_title_translated = ? WHERE id = ?", params: [titleT, contentId]) && ok
            }
            ok = db.execute("UPDATE content SET llm_translated_md = ? WHERE id = ?", params: [excerptT, contentId]) && ok
            return ok
        } catch {
            setError(Self.describeError(error))
            return false
        }
    }
}
