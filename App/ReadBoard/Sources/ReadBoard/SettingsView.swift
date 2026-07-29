import SwiftUI
import AppKit

// MARK: - 独立设置窗口（⌘, 打开，手写侧栏+详情分页）

public enum SettingsPage: String, CaseIterable, Identifiable {
    case general, reader, llm, deps, boards, sources, fetch, content, export, pipeline, cleanup
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .general:  return "通用"
        case .reader:   return "阅读器"
        case .llm:      return "LLM模型"
        case .deps:     return "依赖"
        case .boards:   return "功能开关"
        case .sources:  return "多平台订阅"
        case .fetch:    return "全文提取"
        case .content:  return "AI内容处理"
        case .export:   return "导出平台"
        case .pipeline: return "导出规则"
        case .cleanup:  return "缓存清理"
        }
    }

    var icon: String {
        switch self {
        case .general:  return "gearshape"
        case .reader:   return "doc.text"
        case .llm:      return "brain.head.profile"
        case .deps:     return "shippingbox"
        case .boards:   return "square.grid.2x2"
        case .sources:  return "antenna.radiowaves.left.and.right"
        case .fetch:    return "doc.viewfinder"
        case .content:  return "text.badge.plus"
        case .export:   return "square.and.arrow.up"
        case .pipeline: return "arrow.triangle.branch"
        case .cleanup:  return "trash"
        }
    }
}

public struct SettingsView: View {
    @State private var selection: SettingsPage? = .general

    public var body: some View {
        // 手动 HStack 布局替代 NavigationSplitView——后者在 Settings 场景下
        // 会硬塞一个「收起左栏」切换按钮，且 .toolbar(removing:.sidebarToggle) 对它无效。
        // 改手写侧栏+详情，按钮从源头不存在。
        HStack(spacing: 0) {
            List(SettingsPage.allCases, selection: $selection) { page in
                Label(page.title, systemImage: page.icon)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .tint(Color.rbAccent)   // 选中项墨蓝 tint（统一纸墨留白）
            .frame(width: 180)

            Divider()

            Group {
                switch selection ?? .general {
                case .general:  GeneralPane()
                case .reader:   ReaderPane()
                case .llm:      LLMPane()
                case .deps:     DepsPane()
                case .boards:   BoardsPane()
                case .sources:  TypeSwitchPane()
                case .fetch:    FetchPane()
                case .content:  ContentPane()
                case .export:   ExportPlatformPane()
                case .pipeline: ExportRulePane()
                case .cleanup:  CleanupPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
        }
        .frame(minWidth: 720, minHeight: 500)
        // 把 Settings 窗口标题栏设为透明 + 隐藏标题文字，消除场景默认大标题栏留白
        // （系统「设置」风格：保留红绿灯/关闭按钮，内容贴顶）。各 pane 的
        // .toolbar(placement: .principal) 标题会显示在透明栏里，不再空一大截。
        .overlay(SettingsWindowAccessor().frame(width: 0, height: 0))
    }
}

/// 零尺寸 overlay，仅用于在视图加入窗口后拿到 Settings 窗口句柄，
/// 将其标题栏设为透明 + 隐藏标题文字（不碰红绿灯按钮）。
private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let win = v.window else { return }
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - 通用

public struct GeneralPane: View {
    @State private var autoSyncOn: Bool = SourceStore.shared.autoSyncEnabled
    @State private var proxyEnabled: Bool = FeedFetcher.globalProxy != nil
    @State private var proxyInput: String = FeedFetcher.globalProxy ?? ""

    public var body: some View {
        Form {
            Section("订阅源自动刷新") {
                Toggle("自动周期抓取", isOn: $autoSyncOn.animation())
                    .tint(Color.rbAccent)
                    .onChange(of: autoSyncOn) { _, v in
                        SourceStore.shared.autoSyncEnabled = v
                    }
                if autoSyncOn {
                    HStack {
                        Text("抓取间隔")
                            .foregroundStyle(Color.rbText2)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { Int(SourceStore.shared.syncInterval / 60) },
                            set: { SourceStore.shared.setSyncInterval(minutes: $0) }
                        )) {
                            Text("15 分钟").tag(15)
                            Text("30 分钟").tag(30)
                            Text("60 分钟").tag(60)
                            Text("120 分钟").tag(120)
                            Text("360 分钟").tag(360)
                        }
                        .pickerStyle(.menu)
                        .tint(Color.rbAccent)
                        .frame(width: 110)
                    }
                }
            }
            Section("网络代理") {
                Toggle("启用网络代理", isOn: $proxyEnabled.animation())
                    .tint(Color.rbAccent)
                    .onChange(of: proxyEnabled) { _, v in
                        if !v {
                            proxyInput = ""
                            FeedFetcher.globalProxy = nil
                            proxyEnabled = false
                        }
                    }
                if proxyEnabled {
                    HStack {
                        Text("代理地址")
                            .frame(width: 96, alignment: .leading)
                        Spacer()
                        TextField("", text: $proxyInput)
                            .textFieldStyle(.roundedBorder)
                    }
                    .onSubmit {
                            let v = proxyInput.trimmingCharacters(in: .whitespaces)
                            FeedFetcher.globalProxy = v.isEmpty ? nil : v
                        }
                    HStack {
                        Spacer()
                        Button("清除") {
                            proxyInput = ""
                            FeedFetcher.globalProxy = nil
                            proxyEnabled = false
                        }
                        .controlSize(.small)
                        .buttonStyle(.quiet)
                        .tint(Color.rbScoreLow)
                        Button("保存") {
                            let v = proxyInput.trimmingCharacters(in: .whitespaces)
                            FeedFetcher.globalProxy = v.isEmpty ? nil : v
                        }
                        .controlSize(.small)
                        .buttonStyle(.primaryCapsule)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - LLM 模型

public struct LLMPane: View {
    /// slotCount 是 static 存储值，SwiftUI 不会自动重绘；用本地 @State 镜像以驱动 ForEach 刷新
    @State private var count: Int = LLMSettings.slotCount

    public var body: some View {
        VStack(spacing: 0) {
            // 标题 + 单一「+」按钮（点 + 添加一个模型）
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LLM 模型配置")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.rbText)
                    Text("上面的模型优先，失败自动换下一个。空模型跳过。可添加多个、拖拽排序。")
                        .font(.caption).foregroundStyle(Color.rbText3)
                }
                Spacer()
                Button {
                    LLMSettings.addSlot()
                    count = LLMSettings.slotCount
                } label: {
                    Image(systemName: "plus")
                }
                .controlSize(.small)
                .buttonStyle(.primaryCapsule)
                .help("添加一个模型")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            if count == 0 {
                VStack(spacing: 10) {
                    Image(systemName: "cpu")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.rbText3)
                    Text("还没有配置任何 LLM 模型")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.rbText)
                    Text("点击右上角 + 添加，支持 DeepSeek / Kimi / OpenRouter / OpenAI 等。")
                        .font(.caption)
                        .foregroundStyle(Color.rbText3)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 60)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(0..<count, id: \.self) { i in
                            LLMModelCard(slotIndex: i, onMove: { from, to in
                                LLMSettings.moveSlot(from: from, to: to)
                                count = LLMSettings.slotCount
                            }, onRemove: {
                                LLMSettings.removeSlot(at: i)
                                count = LLMSettings.slotCount
                            })
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // 兜底：外部（迁移等）改了 slotCount 时也同步
            count = LLMSettings.slotCount
        }
    }
}

// MARK: - 全文提取

public struct FetchPane: View {

    @State private var showDefuddleAlert = false
    @State private var defuddleMissing: [String] = []

    public var body: some View {
        Form {
            // ── defuddle 本地 ──
            Section {
                HStack {
                    Toggle("启用 defuddle", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "defuddle.enabled") },
                        set: { newValue in
                            if newValue { checkDefuddleDeps() }
                            else { UserDefaults.standard.set(false, forKey: "defuddle.enabled") }
                        }
                    ))
                    .tint(Color.rbAccent)
                    Spacer()
                    Text(UserDefaults.standard.bool(forKey: "defuddle.enabled") ? "已开启" : "已关闭")
                        .font(.caption).foregroundStyle(Color.rbText3)
                }
            } footer: {
                Text("基于 Node.js 的本地网页正文提取引擎，与 Obsidian Web Clipper 效果类似")
                    .font(.caption).foregroundStyle(Color.rbText3)
            }
        }
        .formStyle(.grouped)
        .alert("defuddle 依赖缺失", isPresented: $showDefuddleAlert) {
            Button("重新检测") { checkDefuddleDeps() }
            Button("关闭", role: .cancel) {
                UserDefaults.standard.set(false, forKey: "defuddle.enabled")
            }
        } message: {
            Text("缺少：\(defuddleMissing.joined(separator: "、"))\n\ndefuddle 引擎应随 ReadBoard 一同安装；如果重新检测仍然缺失，请重新安装 App。")
        }
    }

    /// 检测 defuddle 依赖
    private func checkDefuddleDeps() {
        var missing: [String] = []
        // node
        if DependencyPaths.resolve(.node) == nil {
            missing.append("node")
        }
        // defuddle 引擎（fetch_engine.js，随 App 打包在 Contents/Resources/engine）
        if DependencyPaths.resolve(.defuddleEngine) == nil {
            missing.append("defuddle 引擎")
        }
        if missing.isEmpty {
            // 依赖齐全——直接开启
            UserDefaults.standard.set(true, forKey: "defuddle.enabled")
        } else {
            defuddleMissing = missing
            showDefuddleAlert = true
        }
    }

}

// MARK: - 内容处理

public struct ContentPane: View {
    public var body: some View {
        Form {
            Section("AI 内容处理开关") {
                ForEach(AIPipeline.allCases) { p in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(p.displayName, isOn: Binding(
                            get: { p.enabled },
                            set: { AIPipeline.setEnabled(p, $0) }
                        ))
                        .tint(Color.rbAccent)
                        AIPromptEditor(pipeline: p)
                    }
                    .padding(.vertical, 5)
                }
                Text("开关开启后，文件夹/订阅源可单独设定是否开启，对单个条目可手动执行")
                    .font(.caption).foregroundStyle(Color.rbText3)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AIPromptEditor: View {
    let pipeline: AIPipeline
    @AppStorage private var modeRaw: String
    @AppStorage(AIPromptSettings.scoreDepthWeightKey) private var scoreDepthWeight = 40
    @AppStorage(AIPromptSettings.scoreQualityWeightKey) private var scoreQualityWeight = 35
    @AppStorage(AIPromptSettings.scoreReadabilityWeightKey) private var scoreReadabilityWeight = 25
    @AppStorage(AIPromptSettings.summaryLengthKey) private var summaryLength = 150
    @AppStorage(AIPromptSettings.summaryStyleKey) private var summaryStyle = "concise"
    @AppStorage(AIPromptSettings.translationStyleKey) private var translationStyle = "natural"
    @AppStorage(AIPromptSettings.translationLanguageKey) private var translationLanguage = "zh"
    @AppStorage(AIPromptSettings.translationTermsKey) private var translationTerms = ""
    @AppStorage(AIPromptSettings.transcriptSpeechStyleKey) private var transcriptSpeechStyle = "standard"
    @AppStorage(AIPromptSettings.transcriptTranslateKey) private var transcriptTranslate = true

    init(pipeline: AIPipeline) {
        self.pipeline = pipeline
        _modeRaw = AppStorage(wrappedValue: AIPromptMode.default.rawValue,
                              AIPromptSettings.modeKey(for: pipeline))
    }

    private var isCustom: Bool { modeRaw == AIPromptMode.custom.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("提示词")
                    .font(.caption)
                    .foregroundStyle(Color.rbText2)
                Spacer()
                Picker("", selection: $modeRaw) {
                    Text("使用默认").tag(AIPromptMode.default.rawValue)
                    Text("使用自定义").tag(AIPromptMode.custom.rawValue)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
            }

            if isCustom {
                customFields
                Text("程序会把这些字段拼入固定提示词；输出格式和语言分流保持不变。")
                    .font(.caption2)
                    .foregroundStyle(Color.rbText3)
            }
        }
        .padding(.leading, 20)
    }

    @ViewBuilder
    private var customFields: some View {
        switch pipeline {
        case .score:
            weightRow("内容深度", value: $scoreDepthWeight)
            weightRow("信息质量", value: $scoreQualityWeight)
            weightRow("可读性", value: $scoreReadabilityWeight)
            let weights = ScoreWeights(normalizingDepth: scoreDepthWeight,
                                       quality: scoreQualityWeight,
                                       readability: scoreReadabilityWeight)
            Text("实际权重：\(weights.depth)% / \(weights.quality)% / \(weights.readability)%（自动归一化为 100%）")
                .font(.caption2).foregroundStyle(Color.rbText3)
        case .summarize:
            HStack {
                Text("摘要长度").font(.caption).foregroundStyle(Color.rbText2)
                Spacer()
                Picker("", selection: $summaryLength) {
                    Text("100 字").tag(100)
                    Text("150 字").tag(150)
                    Text("200 字").tag(200)
                    Text("300 字").tag(300)
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 110)
            }
            HStack {
                Text("输出风格").font(.caption).foregroundStyle(Color.rbText2)
                Spacer()
                Picker("", selection: $summaryStyle) {
                    Text("精简概括").tag("concise")
                    Text("完整叙述").tag("narrative")
                    Text("要点列表").tag("bullets")
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 120)
            }
        case .translate:
            HStack {
                Text("翻译文风").font(.caption).foregroundStyle(Color.rbText2)
                Spacer()
                Picker("", selection: $translationStyle) {
                    Text("准确忠实").tag("faithful")
                    Text("自然流畅").tag("natural")
                    Text("简洁凝练").tag("concise")
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 120)
            }
            HStack {
                Text("输出语言").font(.caption).foregroundStyle(Color.rbText2)
                Spacer()
                Picker("", selection: $translationLanguage) {
                    Text("中文").tag("zh")
                    Text("英文").tag("en")
                    Text("日文").tag("ja")
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 120)
            }
            fieldRow("术语要求", placeholder: "如：公司名保留英文，首次出现补中文", text: $translationTerms)
        case .transcribe:
            HStack {
                Text("口语程度").font(.caption).foregroundStyle(Color.rbText2)
                Spacer()
                Picker("", selection: $transcriptSpeechStyle) {
                    Text("保留口语").tag("spoken")
                    Text("适度整理").tag("standard")
                    Text("偏书面化").tag("written")
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 110)
            }
            Toggle("翻译非中文转录稿", isOn: $transcriptTranslate)
                .font(.caption)
                .tint(Color.rbAccent)
        }
    }

    private func weightRow(_ label: String, value: Binding<Int>) -> some View {
        Stepper(value: value, in: 5...80, step: 5) {
            HStack {
                Text(label).font(.caption).foregroundStyle(Color.rbText2)
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.rbText)
            }
        }
    }

    private func fieldRow(_ label: String, placeholder: String,
                          text: Binding<String>) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(Color.rbText2)
            Spacer()
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 310)
        }
    }
}

/// 单个 LLM 模型卡片（baseURL + apiKey + model + 预设 + 测试），允许留空（空模型跳过）
/// 可拖拽排序（.onDrag / .dropDestination），名称随下标为「模型 N」。
/// 布局：标题行 = 拖拽手柄 + 「模型 N」+ 预设下拉（右对齐、紧贴删除）+ 删除；
/// 底部一行 = 测试连接（左）+ 清除/保存（右，清除永远在保存左侧）；预设带 modelListURL 时模型字段改下拉选。
public struct LLMModelCard: View {
    let slotIndex: Int

    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var temperature: Double = 0.3
    @State private var presetId = "deepseek"
    @State private var testing = false
    @State private var testResult: String? = nil
    @State private var testOK = false
    @State private var savedHint = false
    @State private var saveError: String? = nil
    /// 显示/隐藏 API Key 明文（默认隐藏；已配置且未改动时点击可临时回读明文）
    @State private var showKey = false
    /// 预设有 modelListURL 时，下拉的可用模型（实时拉取合并；最小保底 = 已存的 model 本身）
    @State private var modelOptions: [String] = []
    /// 实时拉取模型列表的状态：idle / loading / 成功(数量) / 失败(原因)
    @State private var modelLoadState: ModelLoadState = .idle
    enum ModelLoadState: Equatable {
        case idle, loading
        case ok(Int)
        case failed(String)
    }
    /// 是否切到「手动输入」文本框（用户选下拉里的「手动输入…」）
    @State private var modelManual = false

    /// 由父级（LLMPane）注入，用于统一处理拖拽交换下标 / 删除后刷新
    var onMove: ((Int, Int) -> Void)? = nil
    var onRemove: (() -> Void)? = nil

    private var modelLabel: String { "模型 \(slotIndex + 1)" }
    private var filled: Bool { !baseURL.isEmpty || !apiKey.isEmpty || !model.isEmpty }
    private var currentPreset: LLMSettings.Preset? {
        LLMSettings.presets.first(where: { $0.id == presetId })
    }
    /// 套用预设模板（仅用户主动从下拉选择时调用）。
    /// 把 baseURL/temperature 填成预设默认值并**实时拉取**模型列表；model 由用户从下拉选（保留已填值）。
    /// onAppear 不会调用本函数——否则会把已存的自定义 model 顶回默认值。
    private func applyPreset(_ newId: String) {
        guard let p = LLMSettings.presets.first(where: { $0.id == newId }),
              !p.baseURL.isEmpty else { return }
        baseURL = p.baseURL
        temperature = p.temperature
        modelManual = false
        // 选预设即触发实时拉取（纯实时，无硬编码清单）；拉到前用已存的 model 做最小保底选项
        var base: [String] = []
        if !model.isEmpty { base.append(model) }
        modelOptions = base
        if !p.modelListURL.isEmpty { Task { await loadModels(from: p.modelListURL) } }
    }

    /// 合并下拉选项：已存 model（最小保底）+ 实时拉到的列表，去重，并把已存 model 置顶
    private func mergeModelOptions(_ fetched: [String], base: [String]) {
        var set = base
        for m in fetched where !set.contains(m) { set.append(m) }
        if !model.isEmpty, let idx = set.firstIndex(of: model) { set.remove(at: idx); set.insert(model, at: 0) }
        modelOptions = set
    }
    /// 解析真实 Key：展示态占位是 "••••••••"（表示已配置但 UI 不回显）。
    /// 用户未改动该字段 → 回读 SecretStore 还原真实 Key（写库时通常不会清空）。
    /// 用户手动清空/填入 → 直接用输入框的值。
    private func resolvedKey() -> String {
        if apiKey == "••••••••" {
            return SecretStore.load(forKey: "llm.slot\(slotIndex).apiKey") ?? ""
        }
        return apiKey
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题行：拖拽手柄 + 名称 + 预设下拉（右对齐，紧贴删除）+ 删除
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(Color.rbText3)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                    .contentShape(Rectangle())
                    .onDrag { NSItemProvider(object: NSString(string: "\(slotIndex)")) }
                Text(modelLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.rbText)
                Spacer()
                // 预设下拉（靠右、紧贴删除）
                // ⚠️ 关键修复：预设「应用模板」只在【用户主动选择】时触发。
                // 之前用 .onChange(of: presetId)，会在 onAppear 程序化赋值 presetId 时也触发，
                // 把你手填的自定义 model 重新顶回预设默认值（切回页面即变回 k2）。
                Picker("", selection: Binding(
                    get: { presetId },
                    set: { newId in
                        presetId = newId
                        applyPreset(newId)   // 仅用户手动选择才套用模板
                    }
                )) {
                    ForEach(LLMSettings.presets) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .labelsHidden()
                .tint(Color.rbAccent)
                .controlSize(.small)
                .frame(width: 180)
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Color.rbScoreLow)
                }
                .buttonStyle(.plain)
                .help("删除该模型")
            }

            // 字段（Placeholder 即 label，保持 label 左/输入右 的整齐感）
            TextField("Base URL", text: $baseURL)
                .textFieldStyle(.roundedBorder)
            // API Key 字段：默认掩码；点击右侧眼睛图标切换明文（已配置时临时回读真实 Key）
            HStack(spacing: 6) {
                if showKey {
                    TextField("API Key（明文）", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .textSelection(.enabled)
                } else {
                    SecureField(apiKey == "••••••••" ? "已配置 · 留空则保持不变" : "API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                Button {
                    showKey.toggle()
                    // 进入显示态且当前是占位符 → 回读真实明文填入，方便核对
                    if showKey && apiKey == "••••••••" {
                        apiKey = SecretStore.load(forKey: "llm.slot\(slotIndex).apiKey") ?? ""
                    }
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .foregroundStyle(Color.rbAccent)
                }
                .buttonStyle(.plain)
                .help(showKey ? "隐藏 Key" : "显示 Key")
            }
            // 模型字段：带实时列表的预设【永远渲染下拉选单】，组件类型不依赖拉取是否成功——
            // 下拉里没有的自定义模型（如 k2p6）用右侧「✎」切文本框手填，再点「📋」回到下拉。
            if modelManual {
                HStack(spacing: 6) {
                    TextField("模型（如 k2p6 / 任意自定义 id）", text: $model)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        if let p = currentPreset, !p.modelListURL.isEmpty {
                            var opts: [String] = []
                            if !model.isEmpty { opts.append(model) }
                            modelOptions = opts
                            modelManual = false
                            Task { await loadModels(from: p.modelListURL) }
                        } else {
                            modelManual = false
                        }
                    } label: {
                        Image(systemName: "list.bullet").foregroundStyle(Color.rbAccent)
                    }
                    .buttonStyle(.plain).help("从列表选择")
                }
            } else if currentPreset?.modelListURL.isEmpty == false {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Picker("模型", selection: $model) {
                            ForEach(modelOptions, id: \.self) { m in
                                Text(m).tag(m)
                            }
                        }
                        .labelsHidden()
                        .tint(Color.rbAccent)
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(Color.rbSurface)
                        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.md))
                        .overlay(RoundedRectangle(cornerRadius: RB.Radius.md).strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair))
                        Button {
                            if let u = currentPreset?.modelListURL, !u.isEmpty { Task { await loadModels(from: u) } }
                        } label: {
                            Image(systemName: "arrow.clockwise").foregroundStyle(Color.rbAccent)
                        }
                        .buttonStyle(.plain).help("刷新模型列表")
                        Button {
                            modelManual = true
                            model = ""
                        } label: {
                            Image(systemName: "pencil").foregroundStyle(Color.rbAccent)
                        }
                        .buttonStyle(.plain).help("手动输入模型名")
                    }
                    // 实时拉取状态小字：让你一眼看出下拉是"拉到了"还是"没拉到、为什么"
                    switch modelLoadState {
                    case .idle:
                        Text("未拉取模型列表").font(.system(size: 11)).foregroundStyle(Color.rbText3)
                    case .loading:
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("正在拉取可用模型…").font(.system(size: 11)).foregroundStyle(Color.rbText3)
                        }
                    case .ok(let n):
                        Text("已列出 \(n) 个可用模型（实时）").font(.system(size: 11)).foregroundStyle(Color.rbScoreHigh)
                    case .failed(let msg):
                        Text(msg).font(.system(size: 11)).foregroundStyle(Color.rbScoreLow).textSelection(.enabled)
                    }
                }
            } else {
                // 自定义（无实时列表）：文本框
                TextField("模型（如 k2p6 / 任意自定义 id）", text: $model)
                    .textFieldStyle(.roundedBorder)
            }

            // 温度（模型属性：推理模型强制 1，普通 0.3）
            HStack(spacing: 8) {
                Text("温度")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.rbText3)
                    .frame(width: 36, alignment: .leading)
                Stepper(value: $temperature, in: 0...2, step: 0.1) {
                    Text(String(format: "%.1f", temperature))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.rbText)
                        .frame(minWidth: 32, alignment: .leading)
                }
                .controlSize(.small)
                Spacer()
                if temperature != 1 && temperature != 0.3 {
                    Button { temperature = 1 } label: { Text("推理").font(.system(size: 11)) }
                        .controlSize(.small).buttonStyle(.quiet)
                    Button { temperature = 0.3 } label: { Text("常规").font(.system(size: 11)) }
                        .controlSize(.small).buttonStyle(.quiet)
                }
            }

            // 底部一行：测试连接（左） + 清除/保存（右，清除永远在保存左侧）
            HStack(spacing: 8) {
                Button(testing ? "测试中…" : "测试连接") {
                    testing = true
                    testResult = nil
                    Task {
                        let s = LLMSettings(baseURL: baseURL, apiKey: resolvedKey(), model: model, temperature: temperature)
                        let (ok, msg) = await LLMClient().testConnection(s)
                        testOK = ok
                        testResult = msg
                        testing = false
                    }
                }
                .controlSize(.small)
                .disabled(testing || baseURL.isEmpty || model.isEmpty || resolvedKey().isEmpty)
                if let r = testResult {
                    Text(r)
                        .font(.caption)
                        .foregroundStyle(testOK ? Color.rbScoreHigh : Color.rbScoreLow)
                        .textSelection(.enabled)
                }
                Spacer()
                if savedHint {
                    Text("已保存").font(.caption).foregroundStyle(Color.rbScoreHigh)
                }
                if let e = saveError {
                    Text(e).font(.caption).foregroundStyle(Color.rbScoreLow).textSelection(.enabled)
                }
                Button("清除") {
                    baseURL = ""; apiKey = ""; model = ""; temperature = 0.3
                    modelOptions = []
                    LLMSettings.clear(profile: slotIndex)
                }
                .controlSize(.small)
                .buttonStyle(.quiet)
                .tint(Color.rbScoreLow)
                .disabled(!filled)
                Button("保存") {
                    let ok = LLMSettings(baseURL: baseURL, apiKey: resolvedKey(), model: model, temperature: temperature)
                        .save(toProfile: slotIndex)
                    if ok {
                        savedHint = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedHint = false }
                    } else {
                        // 写入失败（本地加密存储异常）：明确告知，不假装成功
                        savedHint = false
                        saveError = "保存失败：本地密钥存储写入异常（Key 未写入）"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { saveError = nil }
                    }
                }
                .controlSize(.small)
                .buttonStyle(.primaryCapsule)
                .disabled(baseURL.isEmpty || model.isEmpty || resolvedKey().isEmpty)
            }
        }
        .padding(14)
        .background(Color.rbSurface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: RB.Radius.lg)
                .strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
        )
        // 拖拽放置：把别的卡片放到本卡片位置 → 交换下标
        .dropDestination(for: String.self) { items, _ in
            guard let srcStr = items.first,
                  let from = Int(srcStr), from != slotIndex else { return false }
            onMove?(from, slotIndex)
            return true
        }
        .onAppear {
            let s = LLMSettings.meta(slotIndex)
            baseURL = s.baseURL
            apiKey = s.apiKey
            model = s.model
            temperature = s.temperature
            presetId = LLMSettings.presets.first(where: { $0.baseURL == s.baseURL })?.id ?? "custom"
            // 进入页面立即用「已存的 model 本身」做最小保底选项（防止 Picker 在选项为空时退化/跳选），
            // 随后后台**实时拉取**真实模型列表合并进来。不再使用任何硬编码厂商清单。
            if let p = currentPreset {
                var opts: [String] = []
                if !s.model.isEmpty { opts.append(s.model) }
                modelOptions = opts
                modelManual = false
                if !p.modelListURL.isEmpty { Task { await loadModels(from: p.modelListURL) } }
            } else {
                modelOptions = s.model.isEmpty ? [] : [s.model]
                modelManual = !s.model.isEmpty
            }
        }
    }

    /// 拉取预设提供的模型列表（OpenAI / OpenRouter 的 /models 或 /v1/models，统一 {data:[{id}]} 格式）
    /// ⚠️ 必须用真实 Key：onAppear 阶段 apiKey 是占位符 "••••••••"，须经 resolvedKey() 还原真实值，
    /// 否则拿占位符当 Bearer 发 /models 会 401，已配置 key 的用户回页面下拉仍拉不到。
    /// 实时拉取预设提供的模型列表（OpenAI 兼容的 /v1/models，返回 {data:[{id}]}）。
    /// 成功即合并进下拉；失败(端点未暴露/Key无权限/网络)时保留「已存 model」作最小保底，不退回文本框。
    private func loadModels(from urlStr: String) async {
        await MainActor.run { modelLoadState = .loading }
        guard let url = URL(string: urlStr) else {
            await MainActor.run { modelLoadState = .failed("URL 无效") }; return
        }
        let key = resolvedKey()   // 占位态回读 SecretStore 真实 Key，未配置则空
        let base = modelOptions   // 最小保底（onAppear/applyPreset 已填入已存 model）
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["data"] as? [[String: Any]] else {
                // 返回的不是 {data:[...]}（可能是 {error:{...}} 或 401）
                await MainActor.run { modelLoadState = .failed("HTTP \(status)：端点未返回模型列表（多半 Key 无效或该端点不暴露）") }
                return
            }
            let ids = arr.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
            await MainActor.run {
                mergeModelOptions(ids, base: base)   // 合并实时 + 已存 model 保底
                modelLoadState = .ok(ids.count)
            }
        } catch {
            await MainActor.run { modelLoadState = .failed("请求失败：\(error.localizedDescription)") }
        }
    }
}

// MARK: - 依赖

public struct DepsPane: View {
    @State private var groups: [DependencyGroup] = []
    @ObservedObject private var downloader = ModelDownloader.shared
    @State private var copiedId: String? = nil
    @State private var installingId: String? = nil
    /// 检查更新状态：nil=未查, true=有更新(值为最新版本), false=已是最新
    @State private var updateAvailable: [String: String?] = [:]
    @State private var checkingIds: Set<String> = []

    public var body: some View {
        Form {
            ForEach($groups) { $group in
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: group.ready ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                            .foregroundStyle(group.ready ? Color.rbScoreHigh : Color.rbScoreMid)
                            .font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.rbText)
                            Text(group.ready ? "✅ 该功能可用" : "⛔ 该功能不可用——完成下方缺失依赖")
                                .font(.caption)
                                .foregroundStyle(group.ready ? Color.rbScoreHigh : Color.rbScoreMid)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)

                    Text(group.description)
                        .font(.caption).foregroundStyle(Color.rbText3).padding(.bottom, 4)

                    ForEach($group.items) { $item in
                        VStack(alignment: .leading, spacing: 6) {
                            // 缩进视觉层级
                            HStack(spacing: 10) {
                                Image(systemName: item.installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(item.installed ? Color.rbScoreHigh : Color.rbScoreLow)
                                    .font(.system(size: 16))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.rbText)
                                    if item.installed {
                                        HStack(spacing: 4) {
                                            if let v = item.version, !v.isEmpty {
                                                Text(v).font(.caption).foregroundStyle(Color.rbText2)
                                            }
                                            if let upd = updateAvailable[item.id], let latest = upd {
                                                Text("→ 可更新至 \(latest)").font(.caption).foregroundStyle(Color.rbScoreMid)
                                            } else if updateAvailable.keys.contains(item.id) {
                                                Text("已是最新").font(.caption).foregroundStyle(Color.rbScoreHigh)
                                            }
                                        }
                                    }
                                    Text(item.installed ? item.path : item.installHint)
                                        .font(.caption)
                                        .foregroundStyle(item.installed ? Color.rbText3 : Color.rbText3)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                // whisper 模型：统一下拉选单（已下载=切换，未下载=开始下载）
                                if item.id == DependencyPaths.Kind.whisperModel.rawValue {
                                    Menu {
                                        ForEach(ModelDownloader.availableModels, id: \.name) { model in
                                            let (exists, size) = ModelDownloader.modelExists(name: model.name)
                                            if exists {
                                                Button {
                                                    DependencyPaths.setCustom(.whisperModel, ModelDownloader.modelPath(for: model.name))
                                                    redetect()
                                                } label: {
                                                    Label("ggml-\(model.name)（已下载，\(ModelDownloader.formatSize(size))）", systemImage: "checkmark")
                                                }
                                            } else {
                                                Button {
                                                    Task { await downloader.download(modelName: model.name) }
                                                } label: {
                                                    Label("ggml-\(model.name)（~\(model.approxSize)）", systemImage: "arrow.down.circle")
                                                }
                                                .disabled(downloader.isDownloading)
                                            }
                                        }
                                    } label: {
                                        let curName: String = {
                                            if let p = DependencyPaths.resolve(.whisperModel) {
                                                return (p as NSString).lastPathComponent
                                            }
                                            return "选择模型"
                                        }()
                                        if downloader.isDownloading {
                                            Label("下载中…", systemImage: "arrow.down.circle")
                                        } else {
                                            Label(curName, systemImage: "cpu")
                                        }
                                    }
                                    .menuStyle(.borderlessButton)
                                    .controlSize(.small)
                                    .fixedSize()
                                } else if let cmd = item.installCommand {
                                    Button(copiedId == item.id ? "已复制" : "复制命令") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(cmd, forType: .string)
                                        copiedId = item.id
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            if copiedId == item.id { copiedId = nil }
                                        }
                                    }
                                    .controlSize(.small)
                                }
                            }

                            HStack(spacing: 8) {
                                Button { redetect() } label: {
                                    Label("自动检测", systemImage: "magnifyingglass")
                                }
                                .controlSize(.small)

                                // 一键安装（未安装可用，已安装灰掉）
                                if let cmd = item.installCommand {
                                    Button {
                                        if cmd.hasPrefix("readboard:") {
                                            handleSpecialInstall(cmd, id: item.id)
                                        } else {
                                            installDependency(cmd, id: item.id)
                                        }
                                    } label: {
                                        Label(item.installed ? "已安装" : "一键安装",
                                              systemImage: item.installed ? "checkmark" : "arrow.down.to.line")
                                    }
                                    .controlSize(.small)
                                    .disabled(item.installed || installingId == item.id)
                                }

                                // 检查更新 / 立即更新（已安装且有升级命令时显示）
                                if item.installed, let ucmd = item.upgradeCommand {
                                    let updState = updateAvailable[item.id] ?? nil
                                    let isInstalling = installingId == item.id + "-upgrade"
                                    if isInstalling {
                                        HStack(spacing: 4) {
                                            ProgressView().scaleEffect(0.5)
                                            Text("更新中…").font(.caption2).foregroundStyle(Color.rbText3)
                                        }
                                    } else if updState != nil {
                                        // 有更新 → 「立即更新」
                                        Button {
                                            if ucmd.hasPrefix("readboard:") {
                                                handleSpecialInstall(ucmd, id: item.id + "-upgrade")
                                            } else {
                                                installDependency(ucmd, id: item.id + "-upgrade")
                                            }
                                        } label: {
                                            Label("立即更新", systemImage: "arrow.triangle.2.circlepath")
                                        }
                                        .controlSize(.small)
                                        .disabled(installingId == item.id + "-upgrade")
                                    } else if updState == nil && updateAvailable.keys.contains(item.id) {
                                        // 已检查，无更新——不显示额外文字，版本行已有「已是最新」
                                    } else {
                                        // 未检查
                                        Button {
                                            checkForUpdate(item: item)
                                        } label: {
                                            Label(checkingIds.contains(item.id) ? "检查中…" : "检查更新",
                                                  systemImage: "arrow.triangle.2.circlepath")
                                        }
                                        .controlSize(.small)
                                        .disabled(checkingIds.contains(item.id))
                                    }
                                }

                                Button {
                                    pickDependencyPath(DependencyPaths.Kind(rawValue: item.id) ?? .node)
                                } label: {
                                    Label("自定义", systemImage: "slider.horizontal.3")
                                }
                                .controlSize(.small)

                                Spacer()
                                Text(item.installed ? "通过" : "未找到")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(item.installed ? Color.rbScoreHigh : Color.rbScoreLow)
                            }
                        }
                        .padding(.leading, 16)
                        .padding(.bottom, 4)
                    }

                    if group.id == "transcribe",
                       downloader.isDownloading || !downloader.statusText.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if downloader.progress >= 0 {
                                ProgressView(value: downloader.progress).tint(Color.rbAccent)
                            } else {
                                ProgressView()
                            }
                            Text(downloader.statusText).font(.caption).foregroundStyle(Color.rbText3)
                            if let err = downloader.errorMessage {
                                Text(err).font(.caption).foregroundStyle(Color.rbScoreLow)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { redetect() }
    }

    /// 强制重检测所有依赖（清除缓存重新 resolve）
    /// 检查依赖是否有可用的更新版本
    private func checkForUpdate(item: DependencyItem) {
        guard !checkingIds.contains(item.id) else { return }
        checkingIds.insert(item.id)
        Task {
            let latest: String?
            if item.installCommand?.hasPrefix("brew install") == true {
                latest = await brewLatestVersion(pkg: item.id)
            } else if item.installCommand?.hasPrefix("npm install") == true {
                latest = await npmLatestVersion(pkg: item.id)
            } else if item.id == DependencyPaths.Kind.whisperModel.rawValue {
                latest = await modelUpdateAvailable()
            } else {
                latest = nil
            }
            await MainActor.run {
                updateAvailable[item.id] = latest
                checkingIds.remove(item.id)
            }
        }
    }

    private func brewLatestVersion(pkg rawId: String) async -> String? {
        let pkg: String
        switch rawId {
        case DependencyPaths.Kind.whisperCLI.rawValue: pkg = "whisper-cpp"
        case DependencyPaths.Kind.ytdlp.rawValue: pkg = "yt-dlp"
        default: pkg = rawId
        }
        let proc = Process()
        let brewBin = DependencyPaths.resolve(.node)?.replacingOccurrences(of: "/node", with: "/brew") ?? "/opt/homebrew/bin/brew"
        proc.executableURL = URL(fileURLWithPath: brewBin)
        proc.arguments = ["info", "--json", pkg]
        let pipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = json.first else { return nil }
        let installed = (first["installed"] as? [[String: Any]])?.first?["version"] as? String ?? ""
        let latest: String
        if let versions = first["versions"] as? [String: Any],
           let stable = versions["stable"] as? String, !stable.isEmpty {
            latest = stable
        } else {
            latest = first["version"] as? String ?? ""
        }
        // 标准化后比较
        let k = DependencyPaths.Kind(rawValue: rawId) ?? .ffmpeg
        let iv = DependencyChecker.extractVersion(installed, kind: k) ?? installed
        let lv = DependencyChecker.extractVersion(latest, kind: k) ?? latest
        if iv == lv { return nil }
        return lv
    }

    private func npmLatestVersion(pkg rawId: String) async -> String? {
        // defuddle 等 npm 包
        let pkg = rawId == DependencyPaths.Kind.defuddleEngine.rawValue ? "defuddle" : rawId
        let proc = Process()
        let nodeBin = DependencyPaths.resolve(.node) ?? "/opt/homebrew/bin/node"
        proc.executableURL = URL(fileURLWithPath: nodeBin)
        proc.arguments = ["-e", "const e=require('child_process');e.exec('npm view \(pkg) version',(_,o)=>console.log((o||'').trim()))"]
        let pipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let ver = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ver.isEmpty ? nil : ver
    }

    /// 检查当前使用的 whisper 模型是否有新版本（比较远程文件大小）
    private func modelUpdateAvailable() async -> String? {
        guard let modelPath = DependencyPaths.resolve(.whisperModel),
              FileManager.default.fileExists(atPath: modelPath) else { return nil }
        let modelName = (modelPath as NSString).lastPathComponent.replacingOccurrences(of: "ggml-", with: "").replacingOccurrences(of: ".bin", with: "")
        guard let url = ModelDownloader.modelURL(for: modelName) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              let remoteLen = http.allHeaderFields["Content-Length"] as? String,
              let remoteSize = Int64(remoteLen) else { return nil }
        let localAttrs = try? FileManager.default.attributesOfItem(atPath: modelPath)
        let localSize = (localAttrs?[.size] as? Int64) ?? 0
        if localSize == remoteSize { return nil }
        return ModelDownloader.formatSize(remoteSize)
    }

    private func redetect() {
        groups = DependencyChecker.shared.checkAllGroups()
    }

    /// 处理特殊安装命令（模型下载、重下载等）

    /// 处理特殊安装命令（模型下载等）
    private func handleSpecialInstall(_ cmd: String, id: String) {
        if cmd == "readboard:model-download" || cmd == "readboard:model-redownload" {
            installingId = id
            Task {
                await downloader.download()
                await MainActor.run {
                    installingId = nil
                    updateAvailable.removeValue(forKey: id.replacingOccurrences(of: "-upgrade", with: ""))
                    redetect()
                }
            }
        }
    }

    /// 一键安装/更新：跑 brew/npm 命令，完成后刷新版本
    private func installDependency(_ cmd: String, id: String) {
        installingId = id
        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-l", "-c", cmd]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            await MainActor.run {
                installingId = nil
                updateAvailable.removeValue(forKey: id.replacingOccurrences(of: "-upgrade", with: ""))
                redetect()
            }
        }
    }

    private func pickDependencyPath(_ kind: DependencyPaths.Kind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择 \(kind.displayName)（留空则自动探测）"
        if panel.runModal() == .OK, let url = panel.url {
            DependencyPaths.setCustom(kind, url.path)
            redetect()
        }
    }
}

// MARK: - 功能板块

public struct BoardsPane: View {
    @State private var states: [String: Bool] = [:]

    public var body: some View {
        Form {
            Section {
                ForEach(FeatureBoard.allCases) { board in
                    HStack(spacing: 12) {
                        Image(systemName: board.icon)
                            .font(.system(size: 16))
                            .frame(width: 24)
                            .foregroundStyle(Color.rbAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(board.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.rbText)
                            Text(board.subtitle)
                                .font(.caption).foregroundStyle(Color.rbText2)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { states[board.rawValue] ?? board.enabled },
                            set: { states[board.rawValue] = $0; FeatureBoard.setEnabled(board, $0) }
                        ))
                        .labelsHidden()
                        .tint(Color.rbAccent)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("功能开关")
            } footer: {
                Text("关闭板块 = 该板块下所有功能不可用")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            for b in FeatureBoard.allCases { states[b.rawValue] = b.enabled }
        }
    }
}

// MARK: - 缓存清理

public struct CleanupPane: View {
    @ObservedObject private var cleanup = CacheCleanupService.shared
    @State private var deleteDays = 90
    @State private var keepCount = 5
    @State private var deleteEnabled = true
    @State private var backupKeepEnabled = true
    @State private var cleanHtml = true
    @State private var cleanHtmlDays = 7
    @State private var showCleanConfirm = false

    /// 清理策略行：开关（可关闭）+ 天数自填（关闭时天数输入禁用）
    private func cleanupDayRow(title: String, unit: String,
                               enabled: Binding<Bool>, days: Binding<Int>,
                               onEnable: @escaping (Bool) -> Void,
                               onDays: @escaping (Int) -> Void) -> some View {
        HStack {
            Toggle(title, isOn: enabled)
                .tint(Color.rbAccent)
                .onChange(of: enabled.wrappedValue) { _, v in onEnable(v) }
            Spacer()
            TextField("", value: days, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .disabled(!enabled.wrappedValue)
                .onChange(of: days.wrappedValue) { _, v in
                    if v > 0 { onDays(v) }
                }
            Text(unit)
                .font(.callout)
                .foregroundStyle(enabled.wrappedValue ? Color.rbText2 : Color.rbText3)
                .frame(width: 58, alignment: .center)
        }
    }

    public var body: some View {
        Form {
            Section("当前占用") {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("数据库").foregroundStyle(Color.rbText3)
                        Spacer()
                        Text(CacheCleanupService.humanBytes(cleanup.dbBytes))
                            .monospacedDigit()
                            .foregroundStyle(Color.rbText)
                    }
                    HStack {
                        Text("本地备份（\(cleanup.backupCount) 份）").foregroundStyle(Color.rbText3)
                        Spacer()
                        Text(CacheCleanupService.humanBytes(cleanup.backupBytes))
                            .monospacedDigit()
                            .foregroundStyle(Color.rbText)
                    }
                    HStack {
                        Text("临时文件（\(cleanup.tempCount) 项）").foregroundStyle(Color.rbText3)
                        Spacer()
                        Text(CacheCleanupService.humanBytes(cleanup.tempBytes))
                            .monospacedDigit()
                            .foregroundStyle(Color.rbText)
                    }
                    HStack {
                        Text("可清理全文 HTML").foregroundStyle(Color.rbText3)
                        Spacer()
                        Text("\(cleanup.contentHtmlCount) 条")
                            .monospacedDigit()
                            .foregroundStyle(Color.rbText)
                    }
                }
                .font(.callout)
                HStack {
                    Spacer()
                    Button(action: { cleanup.refreshStats() }) {
                        Text("刷新占用")
                    }
                    .controlSize(.small)
                }
            }

            Section("清理策略") {
                // 每项：开关（可关闭）+ 天数自填（TextField 数字）
                cleanupDayRow(
                    title: "已读自动删除", unit: "天后删除",
                    enabled: $deleteEnabled, days: $deleteDays,
                    onEnable: { cleanup.deleteEnabled = $0 },
                    onDays: { cleanup.deleteAfterDays = $0 }
                )
                cleanupDayRow(
                    title: "备份滚动保留", unit: "份",
                    enabled: $backupKeepEnabled, days: $keepCount,
                    onEnable: { cleanup.backupKeepEnabled = $0 },
                    onDays: { cleanup.backupKeepCount = $0 }
                )
                cleanupDayRow(
                    title: "清理已提取内容的全文 HTML", unit: "天后清理",
                    enabled: $cleanHtml, days: $cleanHtmlDays,
                    onEnable: { cleanup.cleanContentHtml = $0 },
                    onDays: { cleanup.cleanHtmlAfterDays = $0 }
                )
            }

            Section {
                HStack {
                    Spacer()
                    Button(cleanup.isRunning ? "清理中…" : "立即清理") {
                        showCleanConfirm = true
                    }
                    .buttonStyle(.primaryCapsule)
                    .disabled(cleanup.isRunning)
                    if cleanup.isRunning { ProgressView().controlSize(.small) }
                }
                .alert("立即清理？", isPresented: $showCleanConfirm) {
                    Button("取消", role: .cancel) {}
                    Button("开始清理") { Task { await cleanup.runAll() } }
                } message: {
                    Text("将按上方策略删除超期已读内容，并清理 HTML 和临时文件。\n星标和带标签的内容不会自动删除。")
                }
                if !cleanup.lastRunSummary.isEmpty {
                    Text(cleanup.lastRunSummary)
                        .font(.caption).foregroundStyle(Color.rbScoreHigh)
                }
                Text("自动删除会先写入 JSONL 回收站，再清除数据库中的正文和 AI 结果；仅保留防重复抓取所需的最小元数据。备份失败时不会删除。星标和带标签的内容不动。")
                    .font(.caption).foregroundStyle(Color.rbText3)
            }

            Section("数据库备份 / 恢复") {
                BackupRestoreView()
            }

            Section("回收站（删除的内容备份）") {
                TrashRestoreView()
            }

            Section("内容处理失败任务") {
                FailedTaskView()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            deleteDays = cleanup.deleteAfterDays
            keepCount = cleanup.backupKeepCount
            deleteEnabled = cleanup.deleteEnabled
            backupKeepEnabled = cleanup.backupKeepEnabled
            cleanHtml = cleanup.cleanContentHtml
            cleanHtmlDays = cleanup.cleanHtmlAfterDays
            cleanup.refreshStats()
        }
    }
}

// MARK: - 备份/恢复（嵌进缓存清理页底部）

public struct BackupRestoreView: View {
    @State private var backups: [BackupInfo] = []
    @State private var selectedBackup: BackupInfo? = nil
    @State private var showRestoreConfirm = false
    @State private var message: String = ""
    @State private var busy = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(busy ? "备份中…" : "立即备份") {
                    busy = true
                    message = ""
                    Task {
                        await BackupService.shared.backupNow()
                        await MainActor.run {
                            message = BackupService.shared.lastBackupError == nil
                                ? "✅ 已备份：\(BackupService.shared.lastBackupAt ?? "")"
                                : "❌ 备份失败：\(BackupService.shared.lastBackupError ?? "")"
                            busy = false
                            reload()
                        }
                    }
                }
                .controlSize(.small)
                .disabled(busy)
                Spacer()
            }

            if backups.isEmpty {
                Text("暂无本地备份")
                    .font(.caption).foregroundStyle(Color.rbText3)
            } else {
                Picker("选择备份", selection: $selectedBackup) {
                    Text("未选择").tag(nil as BackupInfo?)
                    ForEach(backups) { b in
                        Text(b.displayName).tag(b as BackupInfo?)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(Color.rbAccent)
                .font(.caption)

                Button("恢复所选备份…") {
                    showRestoreConfirm = true
                }
                .controlSize(.small)
                .disabled(selectedBackup == nil)
                .foregroundStyle(Color.rbScoreLow)
            }

            if !message.isEmpty {
                Text(message).font(.caption)
            }
            Text("恢复前会自动给当前库做一次安全备份。恢复完成后需重启 App。")
                .font(.caption2).foregroundStyle(Color.rbText3)
        }
        .onAppear(perform: reload)
        .alert("确认恢复？", isPresented: $showRestoreConfirm) {
            Button("取消", role: .cancel) {}
            Button("恢复并退出 App", role: .destructive) {
                guard let b = selectedBackup else { return }
                do {
                    try BackupService.shared.restore(from: b.path)
                    // 恢复后连接句柄已失效，直接退出让用户重开
                    NSApp.terminate(nil)
                } catch {
                    message = "❌ 恢复失败：\(error.localizedDescription)"
                }
            }
        } message: {
            Text("将用 \(selectedBackup?.displayName ?? "") 替换当前数据库。\n当前库会先自动备份，可随时再换回来。")
        }
    }

    private func reload() {
        backups = BackupService.shared.listBackups()
    }
}

// MARK: - 回收站恢复（清理删除的内容可找回）

public struct TrashRestoreView: View {
    @State private var batches: [CacheCleanupService.TrashBatch] = []
    @State private var message = ""
    @State private var showClearConfirm = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if batches.isEmpty {
                Text("回收站为空——清理删除的内容会备份到这里。")
                    .font(.caption).foregroundStyle(Color.rbText3)
            } else {
                ForEach(batches) { b in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(b.date) · \(b.itemCount) 条")
                                .font(.callout)
                                .foregroundStyle(Color.rbText)
                            Text(CacheCleanupService.humanBytes(b.sizeBytes))
                                .font(.caption2).foregroundStyle(Color.rbText3)
                        }
                        Spacer()
                        Button("恢复") {
                            let r = CacheCleanupService.shared.restoreTrash(batch: b)
                            // 全部条目都已在库里（恢复成功 + 本就存在）→ 备份文件已无价值，删掉防残留
                            if r.restored + r.skipped > 0 {
                                CacheCleanupService.shared.deleteTrash(batch: b)
                            }
                            message = "✅ 恢复 \(r.restored) 条（跳过已存在 \(r.skipped)），已放回文章列表，备份文件已清理"
                            reload()
                        }
                        .controlSize(.small)
                        Button(role: .destructive) {
                            CacheCleanupService.shared.deleteTrash(batch: b)
                            reload()
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.quiet)
                        .controlSize(.small)
                    }
                }
                HStack {
                    if !message.isEmpty {
                        Text(message).font(.caption).foregroundStyle(Color.rbScoreHigh)
                    }
                    Spacer()
                    Button("清空回收站…", role: .destructive) { showClearConfirm = true }
                        .controlSize(.small)
                }
            }
            Text("恢复后内容会重新出现在普通文章列表中。")
                .font(.caption2).foregroundStyle(Color.rbText3)
        }
        .onAppear(perform: reload)
        .alert("清空回收站？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("全部删除", role: .destructive) {
                CacheCleanupService.shared.clearAllTrash()
                reload()
            }
        } message: {
            Text("回收站里 \(batches.reduce(0) { $0 + $1.itemCount }) 条备份将永久删除，不可找回。")
        }
    }

    private func reload() {
        batches = CacheCleanupService.shared.listTrash()
    }
}

// MARK: - 失败任务管理（连续失败 >=3 后暂停处理）

public struct FailedTaskView: View {
    @StateObject private var worker = PipelineWorker.shared
    @State private var showFailureList = false

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: worker.deadLetterCount > 0
                  ? "exclamationmark.triangle.fill"
                  : "checkmark.circle.fill")
                .foregroundStyle(worker.deadLetterCount > 0 ? Color.rbScoreLow : Color.rbScoreHigh)
            VStack(alignment: .leading, spacing: 2) {
                Text(worker.deadLetterCount > 0
                     ? "\(worker.deadLetterCount) 个失败任务已暂停"
                     : "没有失败任务")
                    .font(.callout)
                    .foregroundStyle(Color.rbText)
                Text("连续失败 3 次后暂停，避免重复调用和费用失控。")
                    .font(.caption2)
                    .foregroundStyle(Color.rbText3)
            }
            Spacer()
            Button("查看失败任务") { showFailureList = true }
                .controlSize(.small)
                .disabled(worker.deadLetterCount == 0)
        }
        .onAppear { worker.requestPendingRefresh() }
        .sheet(isPresented: $showFailureList, onDismiss: {
            worker.requestPendingRefresh()
        }) {
            ContentFailureListSheet()
        }
    }
}

// MARK: - 阅读器（版面 + 文章列表外观 + 阅读行为）

public struct ReaderPane: View {
    // 版面（阅读区）
    @AppStorage("reading.theme") private var themeRaw: String = "claude"
    @AppStorage("reading.themeMode") private var themeModeRaw: String = ReadingTheme.Mode.system.rawValue
    @AppStorage("reading.font") private var fontRaw: String = "system"
    @AppStorage("reading.fontSize") private var fontSize: Double = 16
    @AppStorage("reading.titleFontSize") private var titleFontSize: Double = 24
    @AppStorage("reading.metaFontSize") private var metaFontSize: Double = 12
    @AppStorage("reading.summaryFontSize") private var summaryFontSize: Double = 14
    @AppStorage("reading.lineSpacing") private var lineSpacing: Double = 6
    @AppStorage("reading.contentWidth") private var contentWidth: Double = 720
    @AppStorage("reading.uiFontScale") private var uiFontScale: Double = 1.0

    // 文章列表外观
    @AppStorage("list.density") private var density: String = "comfortable"
    @AppStorage("list.showSource") private var showSource: Bool = true
    @AppStorage("list.showDate") private var showDate: Bool = true
    @AppStorage("list.unreadBold") private var unreadBold: Bool = true
    @AppStorage("list.dateFormat") private var dateFormat: String = "absolute"

    public var body: some View {
        Form {
            // ── 阅读区版面 ──
            Section("阅读区版面") {
                Picker("主题", selection: $themeRaw) {
                    ForEach(ReadingTheme.allCases) { t in
                        Text(t.displayName).tag(t.rawValue)
                    }
                }
                .tint(Color.rbAccent)
                Picker("亮暗", selection: $themeModeRaw) {
                    ForEach(ReadingTheme.Mode.allCases) { m in
                        Text(m.displayName).tag(m.rawValue)
                    }
                }
                .tint(Color.rbAccent)
                Picker("正文/标题字体", selection: $fontRaw) {
                    ForEach(ReadingFont.presets, id: \.self) { f in
                        Text(f.displayName).tag(fontKey(f))
                    }
                    Divider()
                    ForEach(ReadingFont.availableFontFamilies, id: \.self) { family in
                        Text(family).font(.custom(family, size: 13)).tag("custom:\(family)")
                    }
                }
                .tint(Color.rbAccent)
                HStack {
                    Text("正文字号 \(Int(fontSize))")
                        .frame(width: 96, alignment: .leading)
                    Slider(value: $fontSize, in: 12...32, step: 1)
                        .tint(Color.rbAccent)
                }
                HStack {
                    Text("标题字号 \(Int(titleFontSize))")
                        .frame(width: 96, alignment: .leading)
                    Slider(value: $titleFontSize, in: 16...36, step: 1)
                        .tint(Color.rbAccent)
                }
                HStack {
                    Text("信息字号 \(Int(metaFontSize))")
                        .frame(width: 96, alignment: .leading)
                    Slider(value: $metaFontSize, in: 8...28, step: 1)
                        .tint(Color.rbAccent)
                }
                HStack {
                    Text("摘要字号 \(Int(summaryFontSize))")
                        .frame(width: 96, alignment: .leading)
                    Slider(value: $summaryFontSize, in: 8...28, step: 1)
                        .tint(Color.rbAccent)
                }
                HStack {
                    Text("行距 \(Int(lineSpacing))")
                        .frame(width: 96, alignment: .leading)
                    Slider(value: $lineSpacing, in: 0...20, step: 1)
                        .tint(Color.rbAccent)
                }
                HStack {
                    Text("内容宽度 \(Int(contentWidth))")
                        .frame(width: 96, alignment: .leading)
                    Slider(value: $contentWidth, in: 600...1200, step: 50)
                        .tint(Color.rbAccent)
                }
                HStack {
                    Text("界面缩放 \(Int(uiFontScale * 100))%")
                        .frame(width: 96, alignment: .leading)
                    Slider(value: $uiFontScale, in: 0.8...1.6, step: 0.05)
                        .tint(Color.rbAccent)
                }
            }

            // ── 文章列表外观 ──
            Section("文章列表") {
                Picker("列表密度", selection: $density) {
                    Text("舒适").tag("comfortable")
                    Text("紧凑").tag("compact")
                }
                .tint(Color.rbAccent)
                Toggle("显示来源名", isOn: $showSource)
                    .tint(Color.rbAccent)
                Toggle("显示日期", isOn: $showDate)
                    .tint(Color.rbAccent)
                if showDate {
                    Picker("日期格式", selection: $dateFormat) {
                        Text("绝对（2026-07-25）").tag("absolute")
                        Text("相对（3 小时前）").tag("relative")
                    }
                    .tint(Color.rbAccent)
                }
                Toggle("未读文章标题加粗", isOn: $unreadBold)
                    .tint(Color.rbAccent)
            }
        }
        .formStyle(.grouped)
    }

    /// ReadingFont → 持久化 key（和 ReadingFont.current 的存储格式一致）
    private func fontKey(_ f: ReadingFont) -> String {
        switch f {
        case .system: return "system"
        case .heiti: return "heiti"
        case .kaiti: return "kaiti"
        case .fangsong: return "fangsong"
        case .custom(let name): return "custom:\(name)"
        }
    }
}

// MARK: - 多平台订阅

/// 设置「多类型源」页：四大内容类型的总开关（文章/RSS、播客、视频、微信）。
/// 当前仅 UI 与计数，开关持久化于 UserDefaults；拦截接入见下方 footer 说明。
public struct TypeSwitchPane: View {
    @State private var counts: [ContentType: Int] = [:]
    @State private var enabled: [ContentType: Bool] = [:]

    public var body: some View {
        Form {
            Section {
                ForEach(ContentType.allCases.filter { $0 != .wechat }) { t in
                    HStack(spacing: 12) {
                        Image(systemName: t.icon)
                            .font(.system(size: 16))
                            .frame(width: 24)
                            .foregroundStyle(Color.rbAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.rbText)
                            Text(t.subtitle)
                                .font(.caption)
                                .foregroundStyle(Color.rbText2)
                            Text("当前 \(counts[t] ?? 0) 个源")
                                .font(.caption2)
                                .foregroundStyle(Color.rbText3)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { enabled[t] ?? true },
                            set: { enabled[t] = $0; ContentType.setEnabled(t, $0) }
                        ))
                        .labelsHidden()
                        .tint(Color.rbAccent)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("订阅平台开关")
            } footer: {
                Text("关闭某平台订阅 = ReadBoard 不再识别 / 刷新该类型的订阅内容")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let srcs = SourceStore.shared.sources
            for t in ContentType.allCases where t != .wechat {
                enabled[t] = t.enabled
                counts[t] = srcs.filter { $0.stype == t.sourceStype }.count
            }
        }
    }
}

/// 内容类型：设置页类型总开关枚举（与 content_source.stype 映射）。
public enum ContentType: String, CaseIterable, Identifiable {
    case article, podcast, youtube, wechat
    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .article: return "文章 / RSS"
        case .podcast: return "播客"
        case .youtube: return "视频 / YouTube"
        case .wechat:  return "微信公众号"
        }
    }

    var subtitle: String {
        switch self {
        case .article: return "常规 RSS 文章订阅"
        case .podcast: return "音频节目（可转录）"
        case .youtube: return "视频 / 视频播客（可转录）"
        case .wechat:  return "公众号转 RSS"
        }
    }

    var icon: String {
        switch self {
        case .article: return "doc.text"
        case .podcast: return "waveform"
        case .youtube: return "play.rectangle"
        case .wechat:  return "message.fill"
        }
    }

    /// content_source.stype 字段值（wechat 当前与 rss 同走普通抓取，待 #21 换引擎）
    var sourceStype: String {
        switch self {
        case .article: return "rss"
        case .podcast: return "podcast"
        case .youtube: return "youtube"
        case .wechat:  return "wechat"
        }
    }

    private var defaultsKey: String { "type.\(rawValue).enabled" }

    var enabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func setEnabled(_ t: ContentType, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "type.\(t.rawValue).enabled")
    }
}
