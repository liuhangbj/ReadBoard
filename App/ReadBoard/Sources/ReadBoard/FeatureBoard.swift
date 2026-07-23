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

enum FeatureBoard: String, CaseIterable, Identifiable {
    case media, fulltext, ai, `export`

    var id: String { rawValue }

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

    /// 板块总开关（默认全开）
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

// MARK: - AI 子管线开关（挂在 ai 板块下，细粒度）
// 与板块总开关两层：board.ai.enabled && aiPipeline(.score) 才真开。

enum AIPipeline: String, CaseIterable, Identifiable {
    case score, summarize, translate, transcribe
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .score: return "打分"
        case .summarize: return "摘要"
        case .translate: return "翻译"
        case .transcribe: return "转录"
        }
    }

    private var defaultsKey: String { "ai.\(rawValue).enabled" }

    /// 子管线开关（默认全开；但只有 ai 板块总开关开才生效）
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// 最终生效 = ai 板块总开关 && 子开关
    var effective: Bool { FeatureBoard.ai.enabled && enabled }
}

// MARK: - LLM 配置（baseURL/model 存 UserDefaults；apiKey 存 Keychain）
// 保留 .env 作为首次启动的默认值填充；一旦设置页保存过，以 App 内配置为准。
// apiKey 不落 plist——明文可被其他进程读取，也会进备份/同步，统一走 Keychain。

struct LLMSettings {
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

    private enum K {
        static let baseURL = "llm.baseURL"
        static let apiKey = "llm.apiKey"          // UserDefaults 中的旧明文 key（仅迁移用，迁完即清）
        static let model = "llm.model"
        static let saved = "llm.savedInApp"       // 用户是否在 App 内保存过（保存过则以 App 为准，忽略 .env）
        static let keychainKey = "llm.apiKey"     // Keychain account
    }

    /// 当前生效配置：App 内保存过 → 用 App 的；否则回退 .env 探测（旧行为）
    static func current() -> LLMSettings {
        let d = UserDefaults.standard
        if d.bool(forKey: K.saved) {
            // 一次性迁移：老版本把 apiKey 明文存在 UserDefaults，迁入 Keychain 后清除
            if let legacy = d.string(forKey: K.apiKey), !legacy.isEmpty {
                _ = KeychainHelper.save(legacy, forKey: K.keychainKey)
                d.removeObject(forKey: K.apiKey)
            }
            return LLMSettings(
                baseURL: d.string(forKey: K.baseURL) ?? "",
                apiKey: KeychainHelper.load(forKey: K.keychainKey) ?? "",
                model: d.string(forKey: K.model) ?? "")
        }
        // 首次：从 .env 探测填充默认值（不写 saved 标记）
        let p = LLMConfig.defaultProviders().first
        return LLMSettings(
            baseURL: p?.endpoint ?? presets[0].baseURL,
            apiKey: p?.apiKey ?? "",
            model: p?.model ?? presets[0].defaultModel)
    }

    /// 保存：baseURL/model 进 UserDefaults，apiKey 进 Keychain，并标记"App 内管理"
    func save() {
        let d = UserDefaults.standard
        d.set(baseURL, forKey: K.baseURL)
        if apiKey.isEmpty {
            KeychainHelper.delete(forKey: K.keychainKey)
        } else {
            _ = KeychainHelper.save(apiKey, forKey: K.keychainKey)
        }
        d.removeObject(forKey: K.apiKey)  // 确保无明文残留
        d.set(model, forKey: K.model)
        d.set(true, forKey: K.saved)
    }

    var isValid: Bool { !baseURL.isEmpty && !apiKey.isEmpty && !model.isEmpty }
}
