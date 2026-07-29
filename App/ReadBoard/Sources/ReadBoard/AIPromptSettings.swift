import Foundation

enum AIPromptMode: String, CaseIterable {
    case `default`
    case custom
}

struct ScoreWeights: Equatable {
    let depth: Int
    let quality: Int
    let readability: Int

    static let `default` = ScoreWeights(depth: 40, quality: 35, readability: 25)

    init(depth: Int, quality: Int, readability: Int) {
        self.depth = depth
        self.quality = quality
        self.readability = readability
    }

    /// 用户设置的是相对权重；运行时换算成总计 100%，避免 UI 中三个值必须手工凑整。
    init(normalizingDepth depth: Int, quality: Int, readability: Int) {
        let d = max(depth, 1), q = max(quality, 1), r = max(readability, 1)
        let total = Double(d + q + r)
        let normalizedDepth = Int((Double(d) / total * 100).rounded())
        let normalizedQuality = Int((Double(q) / total * 100).rounded())
        self.depth = normalizedDepth
        self.quality = normalizedQuality
        self.readability = max(0, 100 - normalizedDepth - normalizedQuality)
    }
}

/// 四条 AI 管线共用的全局结构化提示词设置。
/// 用户只填写少量字段，程序负责拼成固定句式，避免自由文本覆盖 JSON/Markdown 等机器契约。
enum AIPromptSettings {
    static let scoreDepthWeightKey = "ai.prompt.score.weight.depth"
    static let scoreQualityWeightKey = "ai.prompt.score.weight.quality"
    static let scoreReadabilityWeightKey = "ai.prompt.score.weight.readability"
    static let summaryLengthKey = "ai.prompt.summarize.length"
    static let summaryStyleKey = "ai.prompt.summarize.style"
    static let translationStyleKey = "ai.prompt.translate.style"
    static let translationLanguageKey = "ai.prompt.translate.language"
    static let translationTermsKey = "ai.prompt.translate.terms"
    static let transcriptSpeechStyleKey = "ai.prompt.transcribe.speechStyle"
    static let transcriptTranslateKey = "ai.prompt.transcribe.translate"

    static func modeKey(for pipeline: AIPipeline) -> String {
        "ai.prompt.\(pipeline.rawValue).mode"
    }

    static func mode(for pipeline: AIPipeline) -> AIPromptMode {
        AIPromptMode(rawValue: UserDefaults.standard.string(forKey: modeKey(for: pipeline)) ?? "")
            ?? .default
    }

    static func setMode(_ mode: AIPromptMode, for pipeline: AIPipeline) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey(for: pipeline))
    }

    /// 单行字段清洗：压缩空白并限制长度，避免术语字段重新变成整段自由提示词。
    private static func field(_ key: String) -> String {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return String(raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    }

    private static func integer(_ key: String, default defaultValue: Int) -> Int {
        let value = UserDefaults.standard.integer(forKey: key)
        return value > 0 ? value : defaultValue
    }

    static var scoreWeights: ScoreWeights {
        guard mode(for: .score) == .custom else { return .default }
        return ScoreWeights(
            normalizingDepth: integer(scoreDepthWeightKey, default: 40),
            quality: integer(scoreQualityWeightKey, default: 35),
            readability: integer(scoreReadabilityWeightKey, default: 25))
    }

    static var summaryLength: Int {
        guard mode(for: .summarize) == .custom else { return 150 }
        return min(max(integer(summaryLengthKey, default: 150), 80), 300)
    }

    static func effectiveTranslationLanguage(fallback: String = "中文") -> String {
        guard mode(for: .translate) == .custom else { return fallback }
        switch UserDefaults.standard.string(forKey: translationLanguageKey) {
        case "en": return "英文"
        case "ja": return "日文"
        default: return "中文"
        }
    }

    static var transcriptTranslationEnabled: Bool {
        guard mode(for: .transcribe) == .custom else { return true }
        return UserDefaults.standard.object(forKey: transcriptTranslateKey) as? Bool ?? true
    }

    /// 返回可直接插入 prompt 的受控句式；默认模式不注入任何额外要求。
    static func instructionBlock(for pipeline: AIPipeline) -> String {
        guard mode(for: pipeline) == .custom else { return "" }

        var requirements: [String] = []
        switch pipeline {
        case .score:
            let weights = scoreWeights
            requirements.append(
                "三个评分维度保持原标准，最终总分权重为：内容深度 \(weights.depth)%、信息质量 \(weights.quality)%、可读性 \(weights.readability)%。")
        case .summarize:
            requirements.append("摘要长度控制在 \(summaryLength) 字以内。")
            let style = UserDefaults.standard.string(forKey: summaryStyleKey) ?? "concise"
            switch style {
            case "narrative": requirements.append("使用连贯完整的段落叙述。")
            case "bullets": requirements.append("使用简洁的 Markdown 要点列表输出。")
            default: requirements.append("使用精简直接的段落概括。")
            }
        case .translate:
            requirements.append("输出语言为\(effectiveTranslationLanguage())。")
            let style = UserDefaults.standard.string(forKey: translationStyleKey) ?? "natural"
            switch style {
            case "faithful": requirements.append("翻译以准确忠实为先，避免改写原意。")
            case "concise": requirements.append("译文表达简洁凝练，减少冗余措辞。")
            default: requirements.append("译文自然流畅，符合目标语言的阅读习惯。")
            }
            let terms = field(translationTermsKey)
            if !terms.isEmpty { requirements.append("术语处理要求：\(terms)。") }
        case .transcribe:
            let speechStyle = UserDefaults.standard.string(forKey: transcriptSpeechStyleKey) ?? "standard"
            switch speechStyle {
            case "spoken": requirements.append("尽量保留口语语气和有意义的口头表达，只修复明显断句与识别重复。")
            case "written": requirements.append("整理为偏书面表达，积极合并碎句并重组段落，但不得总结或删减有效信息。")
            default: requirements.append("适度保留口语风格，同时修复断句、标点并按语义整理段落。")
            }
            requirements.append(transcriptTranslationEnabled
                ? "非中文转录稿整理后翻译为\(effectiveTranslationLanguage())，中文稿只整理不翻译。"
                : "所有转录稿只用原语言整理，不执行翻译。")
        }

        return "\n用户偏好：\n- " + requirements.joined(separator: "\n- ")
            + "\n（以上偏好不得改变程序规定的输出格式、字段结构和语言分流。）"
    }
}
