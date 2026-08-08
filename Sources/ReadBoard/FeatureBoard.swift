import Foundation

// MARK: - 板块级总开关
// 四大板块各自一个总开关（UserDefaults 持久化），与源级/文件夹级开关取与：
// 板块关 = 该板块下所有功能全停，无论源级怎么开。设置页一关整个板块即停。
//
// 板块划分（对应用户定义）：
//   media     多类型资源获取（podcast / video / social media 的抓取与入队）
//   fulltext  全文提取（probe + fetch + 回填）
//   ai        AI 板块（AI 评分 / AI 摘要 / AI 翻译 / AI 转录 四条 LLM/whisper 管线）
//   export    后处理板块（按条件导出到 Obsidian / readitlater / webhook）

public enum FeatureBoard: String, CaseIterable, Identifiable {
    case media, fulltext, ai, `export`

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .media: return "多平台订阅"
        case .fulltext: return "全文提取"
        case .ai: return "AI 内容处理"
        case .export: return "导出规则"
        }
    }

    var subtitle: String {
        switch self {
        case .media: return "podcast · video · social media 的抓取与入队"
        case .fulltext: return "defuddle / CDP 全文提取与回填"
        case .ai: return "AI 评分 · AI 摘要 · AI 翻译 · AI 转录"
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
        case .ai: return ["AI 评分", "AI 摘要", "AI 翻译", "AI 转录"]
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
        case .score: return "AI 评分"
        case .summarize: return "AI 摘要"
        case .translate: return "AI 翻译"
        case .transcribe: return "AI 转录"
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

// MARK: - LLM 配置（多模型，列表 fallback）
// 配置以「槽位」(slot) 为单位：可按需添加/移除/拖拽排序；按列表从上到下 fallback，空模型跳过。不读 .env。
// 每槽允许为空（空槽跳过）。baseURL/model 存 UserDefaults；apiKey 按槽存 SecretStore（本地 AES-GCM 加密文件，替代 Keychain）。
// 存储键沿用 llm.slotN.*；槽位下标即存储下标。

public struct LLMSettings {
    var baseURL: String
    var apiKey: String
    var model: String
    /// 温度：模型属性。推理模型（kimi-k2 等）强制 1，普通模型 0.3 即可
    var temperature: Double = 0.3
    /// 关闭模型思考：推理模型（deepseek-v4/kimi-k2 等）会把输出预算先耗在 reasoning_content，
    /// max_tokens 偏小或任务较长时正文为空。结构化任务关闭思考更快、更稳、更省钱。
    var disableThinking: Bool = true

    /// 常用 provider 预设（baseURL + 默认 model），设置页选中自动填
    /// modelListURL 非空时，选该预设即**实时拉取**可用模型做成下拉（纯实时，无硬编码清单）。
    /// 下拉的「最小保底选项」= 用户已存的 model 本身（不是厂商清单），仅用于防止 SwiftUI Picker
    /// 在选项为空时退化/跳选；真实模型列表拉到后合并进来。
    struct Preset: Identifiable, Hashable {
        let id: String
        let name: String
        let baseURL: String
        let defaultModel: String
        let modelListURL: String
        let temperature: Double

        init(id: String, name: String, baseURL: String, defaultModel: String,
             modelListURL: String = "", temperature: Double = 0.3) {
            self.id = id; self.name = name; self.baseURL = baseURL; self.defaultModel = defaultModel
            self.modelListURL = modelListURL; self.temperature = temperature
        }
    }

    static let presets: [Preset] = [
        Preset(id: "deepseek", name: "DeepSeek",
               baseURL: "https://api.deepseek.com/v1/chat/completions", defaultModel: "deepseek-chat",
               modelListURL: "https://api.deepseek.com/v1/models"),
        Preset(id: "kimi", name: "Moonshot 开发者 API",
               baseURL: "https://api.moonshot.cn/v1/chat/completions", defaultModel: "kimi-k2",
               modelListURL: "https://api.moonshot.cn/v1/models",
               temperature: 1),
        Preset(id: "kimicoding", name: "Kimi Coding Plan",
               baseURL: "https://api.kimi.com/coding/v1/chat/completions", defaultModel: "kimi-k2",
               modelListURL: "https://api.kimi.com/coding/v1/models",
               temperature: 1),
        Preset(id: "openrouter", name: "OpenRouter",
               baseURL: "https://openrouter.ai/api/v1/chat/completions", defaultModel: "",
               modelListURL: "https://openrouter.ai/api/v1/models"),
        Preset(id: "openai", name: "OpenAI",
               baseURL: "https://api.openai.com/v1/chat/completions", defaultModel: "gpt-4o-mini",
               modelListURL: "https://api.openai.com/v1/models"),
        Preset(id: "custom", name: "自定义 (OpenAI 兼容)", baseURL: "", defaultModel: ""),
    ]

    /// 配置槽位数量（key 持久化；最小 0 个——全新安装无预设模型，点 + 才添加）
    /// 无记录（全新安装）→ 默认 0；已手动保存的值原样保留
    static var slotCount: Int {
        get {
            UserDefaults.standard.integer(forKey: K.slotCount)
        }
        set { UserDefaults.standard.set(max(0, newValue), forKey: K.slotCount) }
    }

    private enum K {
        static let slotCount = "llm.slotCount"
        // 配置槽键（i = 下标）——沿用旧 llm.slotN.* 键名，保持兼容不丢配置
        // （用户若拖拽重排，只是把 N 个槽的值写到不同下标；老配置在对应下标的值原样保留）
        static func baseURL(_ i: Int) -> String { "llm.slot\(i).baseURL" }
        static func model(_ i: Int) -> String { "llm.slot\(i).model" }
        static func temperature(_ i: Int) -> String { "llm.slot\(i).temperature" }
        static func disableThinking(_ i: Int) -> String { "llm.slot\(i).disableThinking" }
        static func secretKey(_ i: Int) -> String { "llm.slot\(i).apiKey" }
        static func keySet(_ i: Int) -> String { "llm.slot\(i).keySet" }
    }

    /// 推理模型预设默认关闭思考；其他 provider（OpenAI/自定义）不带 thinking 参数更稳。
    private static func defaultDisableThinking(baseURL: String) -> Bool {
        baseURL.contains("deepseek.com")
            || baseURL.contains("moonshot.cn")
            || baseURL.contains("api.kimi.com")
    }

    /// 读某档配置（可能为空档）。会读 SecretStore 取真实 Key。
    static func profile(_ i: Int) -> LLMSettings {
        let d = UserDefaults.standard
        let temp = d.object(forKey: K.temperature(i)) == nil ? 0.3 : d.double(forKey: K.temperature(i))
        let baseURL = d.string(forKey: K.baseURL(i)) ?? ""
        let thinking = d.object(forKey: K.disableThinking(i)) == nil
            ? defaultDisableThinking(baseURL: baseURL)
            : d.bool(forKey: K.disableThinking(i))
        return LLMSettings(
            baseURL: baseURL,
            apiKey: SecretStore.load(forKey: K.secretKey(i)) ?? "",
            model: d.string(forKey: K.model(i)) ?? "",
            temperature: temp,
            disableThinking: thinking)
    }

    /// 渲染用元数据：只读 UserDefaults，不读取 SecretStore。
    /// hasKey 由 keySet 位推断（保存 Key 时置位、清空时复位），避免重复解密。
    static func meta(_ i: Int) -> LLMSettings {
        let d = UserDefaults.standard
        let temp = d.object(forKey: K.temperature(i)) == nil ? 0.3 : d.double(forKey: K.temperature(i))
        let baseURL = d.string(forKey: K.baseURL(i)) ?? ""
        let thinking = d.object(forKey: K.disableThinking(i)) == nil
            ? defaultDisableThinking(baseURL: baseURL)
            : d.bool(forKey: K.disableThinking(i))
        return LLMSettings(
            baseURL: baseURL,
            apiKey: d.bool(forKey: K.keySet(i)) ? "••••••••" : "",
            model: d.string(forKey: K.model(i)) ?? "",
            temperature: temp,
            disableThinking: thinking)
    }

    /// 所有非空档按序组成 fallback 链（空档跳过）
    /// 全部非空档按序组成 fallback 链（空档跳过）。
    /// ⚠️ 缓存版（16:37 定案）：原实现每次调用都 3× SecretStore.load（读加密文件+AES 解密），
    /// 而阅读区操作条每次 body 求值都调 isAvailable → profiles()——每篇 ~10 次求值 = 几十次
    /// 文件+解密，叠加重算派生密钥（已修）曾是压垮主线程的组合拳。
    /// 配置只在 save/clear 时变化，缓存命中即可；变更点已全部失效处理。
    /// nonisolated(unsafe)：读多写极少，引用赋值原子，最坏情况并发各算一次（与 Tracer 同模式）。
    private nonisolated(unsafe) static var profilesCache: [LLMSettings]?

    static func profiles() -> [LLMSettings] {
        if let c = profilesCache { return c }
        let v = (0..<slotCount).map { profile($0) }.filter { $0.isValid }
        profilesCache = v
        return v
    }

    /// 配置变更后调用——让 profiles() 缓存失效
    private static func invalidateProfilesCache() { profilesCache = nil }

    /// 当前生效配置：首个非空档（兼容旧调用方——testConnection 测单条用）。
    /// 仅来自 App 内模型配置，不读 .env。
    static func current() -> LLMSettings {
        profiles().first ?? LLMSettings(
            baseURL: presets[0].baseURL,
            apiKey: "",
            model: presets[0].defaultModel)
    }

    /// 保存到指定档：baseURL/model 进 UserDefaults，apiKey 进 SecretStore；全空 = 清档
    /// 返回 true=全部落盘成功；false=SecretStore 写入失败（Key 没存进去）。
    /// ⚠️ 关键：SecretStore 写入失败时【绝不】置位 keySet，
    /// 否则 UI 会显示「已配置」但真实 Key 缺失，误导用户以为存好了。
    @discardableResult
    func save(toProfile i: Int) -> Bool {
        defer { Self.invalidateProfilesCache() }
        let d = UserDefaults.standard
        d.set(baseURL, forKey: K.baseURL(i))
        d.set(model, forKey: K.model(i))
        d.set(temperature, forKey: K.temperature(i))
        d.set(disableThinking, forKey: K.disableThinking(i))
        if apiKey.isEmpty {
            _ = SecretStore.delete(forKey: K.secretKey(i))
            d.set(false, forKey: K.keySet(i))
            return true
        } else {
            let ok = SecretStore.save(apiKey, forKey: K.secretKey(i))
            if ok {
                d.set(true, forKey: K.keySet(i))
            } else {
                // 写入失败：回滚 keySet，避免 UI 假显示「已配置」
                d.set(false, forKey: K.keySet(i))
            }
            return ok
        }
    }

    /// 清空某档
    static func clear(profile i: Int) {
        defer { invalidateProfilesCache() }
        let d = UserDefaults.standard
        d.removeObject(forKey: K.baseURL(i))
        d.removeObject(forKey: K.model(i))
        d.removeObject(forKey: K.disableThinking(i))
        _ = SecretStore.delete(forKey: K.secretKey(i))
        d.set(false, forKey: K.keySet(i))
    }

    /// 追加一个空槽（存储键按下标，新增槽天然为空）
    static func addSlot() {
        slotCount += 1
    }

    /// 删除某槽（0 基下标），其后各槽整体前移，保持下标连续不空洞
    static func removeSlot(at index: Int) {
        let n = slotCount
        guard index >= 0, index < n else { return }
        clear(profile: index)
        for i in (index + 1)..<n {
            let s = profile(i)
            if s.isEmpty {
                clear(profile: i - 1)
            } else {
                s.save(toProfile: i - 1)
            }
        }
        clear(profile: n - 1)
        slotCount = n - 1
    }

    /// 移动槽（拖拽排序），from/to 为 0 基下标
    static func moveSlot(from: Int, to: Int) {
        let n = slotCount
        guard from >= 0, from < n, to >= 0, to < n, from != to else { return }
        let snap = (0..<n).map { i -> (String, String, Double, Bool, String) in
            (UserDefaults.standard.string(forKey: K.baseURL(i)) ?? "",
             UserDefaults.standard.string(forKey: K.model(i)) ?? "",
             UserDefaults.standard.double(forKey: K.temperature(i)),
             UserDefaults.standard.object(forKey: K.disableThinking(i)) == nil
                ? defaultDisableThinking(baseURL: UserDefaults.standard.string(forKey: K.baseURL(i)) ?? "")
                : UserDefaults.standard.bool(forKey: K.disableThinking(i)),
             SecretStore.load(forKey: K.secretKey(i)) ?? "")
        }
        var arr = Array(snap)
        let item = arr.remove(at: from)
        arr.insert(item, at: to)
        for (i, v) in arr.enumerated() {
            UserDefaults.standard.set(v.0, forKey: K.baseURL(i))
            UserDefaults.standard.set(v.1, forKey: K.model(i))
            UserDefaults.standard.set(v.2, forKey: K.temperature(i))
            UserDefaults.standard.set(v.3, forKey: K.disableThinking(i))
            if v.4.isEmpty { _ = SecretStore.delete(forKey: K.secretKey(i)) }
            else { _ = SecretStore.save(v.4, forKey: K.secretKey(i)) }
        }
    }

    var isValid: Bool { !baseURL.isEmpty && !apiKey.isEmpty && !model.isEmpty }
    var isEmpty: Bool { baseURL.isEmpty && apiKey.isEmpty && model.isEmpty }
}
