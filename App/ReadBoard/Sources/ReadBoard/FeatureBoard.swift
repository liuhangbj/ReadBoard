import Foundation

// MARK: - 板块级总开关
// 四大板块各自一个总开关（UserDefaults 持久化），与源级/文件夹级开关取与：
// 板块关 = 该板块下所有功能全停，无论源级怎么开。设置页一关整个板块即停。
//
// 板块划分（对应用户定义）：
//   media     多类型资源获取（podcast / video / social media 的抓取与入队）
//   fulltext  全文抓取（probe + fetch + 回填）
//   ai        AI 板块（打分 / 摘要 / 翻译 / 转录 四条 LLM/whisper 管线）
//   export    后处理板块（按条件导出到 Obsidian / readitlater / webhook）

public enum FeatureBoard: String, CaseIterable, Identifiable {
    case media, fulltext, ai, `export`

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .media: return "多类型资源获取"
        case .fulltext: return "全文抓取"
        case .ai: return "AI 板块"
        case .export: return "后处理板块"
        }
    }

    var subtitle: String {
        switch self {
        case .media: return "podcast · video · social media 的抓取与入队"
        case .fulltext: return "defuddle / CDP 全文抓取与回填"
        case .ai: return "打分 · 摘要 · 翻译 · 转录"
        case .export: return "按条件导出到 Obsidian / readitlater / webhook"
        }
    }

    var icon: String {
        switch self {
        case .media: return "waveform.circle"
        case .fulltext: return "doc.text.magnifyingglass"
        case .ai: return "brain.head.profile"
        case .export: return "square.and.arrow.up"
        }
    }

    /// 子功能项（设置页展示用，仅 AI 板块有可见子开关）
    var subFeatures: [String] {
        switch self {
        case .ai: return ["打分", "摘要", "翻译", "转录"]
        case .media: return ["podcast", "video", "social media"]
        case .fulltext: return ["自动探测 fetch_mode", "失败回填"]
        case .export: return ["Obsidian", "Markdown 目录", "Webhook"]
        }
    }

    private var defaultsKey: String { "board.\(rawValue).enabled" }

    /// 板块总开关（默认全开）。
    /// 读走属性；写必须走静态 set——Swift 不允许对枚举 computed property 的 setter 直接赋值。
    var enabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func setEnabled(_ board: FeatureBoard, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "board.\(board.rawValue).enabled")
    }
}

// MARK: - AI 子管线开关（挂在 ai 板块下，细粒度）
// 与板块总开关两层：board.ai.enabled && aiPipeline(.score) 才真开。

public enum AIPipeline: String, CaseIterable, Identifiable {
    case score, summarize, translate, transcribe
    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .score: return "打分"
        case .summarize: return "摘要"
        case .translate: return "翻译"
        case .transcribe: return "转录"
        }
    }

    private var defaultsKey: String { "ai.\(rawValue).enabled" }

    /// 子管线开关（默认全开；但只有 ai 板块总开关开才生效）。写走静态 set。
    var enabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func setEnabled(_ p: AIPipeline, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "ai.\(p.rawValue).enabled")
    }

    /// 最终生效 = ai 板块总开关 && 子开关
    var effective: Bool { FeatureBoard.ai.enabled && enabled }
}

// MARK: - LLM 配置（三槽 fallback）
// 三个配置槽按次序 fallback：槽1 失败换槽2，再失败换槽3，最后 .env 兜底。
// 每槽允许为空（空槽跳过）。baseURL/model 存 UserDefaults；apiKey 按槽存 Keychain。
// 保留单槽时代的旧 key 做一次性迁移（旧配置 → 槽1）。

public struct LLMSettings {
    var baseURL: String
    var apiKey: String
    var model: String

    /// 常用 provider 预设（baseURL + 默认 model），设置页选中自动填
    struct Preset: Identifiable, Hashable {
        let id: String
        let name: String
        let baseURL: String
        let defaultModel: String
    }

    static let presets: [Preset] = [
        Preset(id: "deepseek", name: "DeepSeek",
               baseURL: "https://api.deepseek.com/v1/chat/completions", defaultModel: "deepseek-chat"),
        Preset(id: "kimi", name: "Kimi (Moonshot)",
               baseURL: "https://api.moonshot.cn/v1/chat/completions", defaultModel: "kimi-k2-0905-preview"),
        Preset(id: "openai", name: "OpenAI",
               baseURL: "https://api.openai.com/v1/chat/completions", defaultModel: "gpt-4o-mini"),
        Preset(id: "custom", name: "自定义 (OpenAI 兼容)", baseURL: "", defaultModel: ""),
    ]

    /// 槽位数（三槽按序 fallback）
    static let slotCount = 3

    private enum K {
        // 槽位键（i = 0/1/2）
        static func baseURL(_ i: Int) -> String { "llm.slot\(i).baseURL" }
        static func model(_ i: Int) -> String { "llm.slot\(i).model" }
        static func keychainKey(_ i: Int) -> String { "llm.slot\(i).apiKey" }
        // 旧单槽键（仅迁移用）
        static let legacyBaseURL = "llm.baseURL"
        static let legacyApiKey = "llm.apiKey"
        static let legacyModel = "llm.model"
        static let legacySaved = "llm.savedInApp"
        static let migrated = "llm.slotsMigrated"
    }

    /// 读某槽配置（可能为空槽）
    static func slot(_ i: Int) -> LLMSettings {
        migrateLegacyIfNeeded()
        let d = UserDefaults.standard
        return LLMSettings(
            baseURL: d.string(forKey: K.baseURL(i)) ?? "",
            apiKey: KeychainHelper.load(forKey: K.keychainKey(i)) ?? "",
            model: d.string(forKey: K.model(i)) ?? "")
    }

    /// 所有非空槽按序组成 fallback 链（空槽跳过）
    static func slots() -> [LLMSettings] {
        (0..<slotCount).map { slot($0) }.filter { $0.isValid }
    }

    /// 旧单槽配置一次性迁到槽1（老用户升级不丢配置）
    private static func migrateLegacyIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: K.migrated) else { return }
        defer { d.set(true, forKey: K.migrated) }
        // 老版本明文 apiKey 也在 UserDefaults 的，一并收
        let legacyKey = KeychainHelper.load(forKey: "llm.apiKey")
            ?? d.string(forKey: K.legacyApiKey) ?? ""
        let legacy = LLMSettings(
            baseURL: d.string(forKey: K.legacyBaseURL) ?? "",
            apiKey: legacyKey,
            model: d.string(forKey: K.legacyModel) ?? "")
        guard legacy.isValid else { return }
        // 写入槽1
        d.set(legacy.baseURL, forKey: K.baseURL(0))
        d.set(legacy.model, forKey: K.model(0))
        _ = KeychainHelper.save(legacy.apiKey, forKey: K.keychainKey(0))
        // 清旧 key（含 Keychain 旧 account 和 UserDefaults 明文）
        d.removeObject(forKey: K.legacyBaseURL)
        d.removeObject(forKey: K.legacyModel)
        d.removeObject(forKey: K.legacyApiKey)
        KeychainHelper.delete(forKey: "llm.apiKey")
    }

    /// 当前生效配置：首个非空槽（兼容旧调用方——testConnection 测单条用）
    static func current() -> LLMSettings {
        if let first = slots().first { return first }
        // 全空：回退 .env 探测（旧行为，给设置页填默认值）
        let p = LLMConfig.defaultProviders().first
        return LLMSettings(
            baseURL: p?.endpoint ?? presets[0].baseURL,
            apiKey: p?.apiKey ?? "",
            model: p?.model ?? presets[0].defaultModel)
    }

    /// 保存到指定槽：baseURL/model 进 UserDefaults，apiKey 进 Keychain；全空 = 清槽
    func save(toSlot i: Int) {
        let d = UserDefaults.standard
        d.set(baseURL, forKey: K.baseURL(i))
        d.set(model, forKey: K.model(i))
        if apiKey.isEmpty {
            KeychainHelper.delete(forKey: K.keychainKey(i))
        } else {
            _ = KeychainHelper.save(apiKey, forKey: K.keychainKey(i))
        }
    }

    /// 清空某槽
    static func clear(slot i: Int) {
        let d = UserDefaults.standard
        d.removeObject(forKey: K.baseURL(i))
        d.removeObject(forKey: K.model(i))
        KeychainHelper.delete(forKey: K.keychainKey(i))
    }

    var isValid: Bool { !baseURL.isEmpty && !apiKey.isEmpty && !model.isEmpty }
    var isEmpty: Bool { baseURL.isEmpty && apiKey.isEmpty && model.isEmpty }
}
