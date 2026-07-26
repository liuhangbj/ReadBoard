import SwiftUI
import AppKit

// MARK: - 导出规则管理（后处理板块）
// 规则列表 + 新建/编辑表单。手动"立即执行"对匹配内容全量补跑（幂等，已交付的跳过）。

public struct ExportRulePane: View {
    @State private var rules: [ExportRule] = []
    @State private var editing: ExportRule? = nil
    @State private var showEditor = false
    @State private var runningId: Int64? = nil
    @State private var deletingRule: ExportRule? = nil

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 页头：标题 + 计数 + 新建（主行动）
            HStack(spacing: 8) {
                Text("导出规则")
                    .font(.system(size: RB.F.pageTitle, weight: .semibold))
                    .foregroundStyle(Color.rbText)
                if !rules.isEmpty {
                    Text("\(rules.count)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.rbText3)
                }
                Spacer()
                Button {
                    editing = ExportRule(
                        id: 0, name: "", enabled: true,
                        criteria: ExportRule.Criteria(),
                        triggerOn: "manual", target: "mddir",
                        targetConfig: [:], lastRunAt: nil)
                    showEditor = true
                } label: { Label("新建规则", systemImage: "plus") }
                .buttonStyle(.primaryCapsule)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Hairline()

            // ── 上区：7 平台登录选项和预设位置 ──
            platformConfigSection
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            Hairline()

            if rules.isEmpty {
                ContentUnavailableView(
                    "还没有导出规则",
                    systemImage: "square.and.arrow.up",
                    description: Text("新建一条规则：按评分/来源/是否已翻译等条件，把内容自动导出到 Obsidian、Markdown 目录或 Webhook。"))
            } else {
                List {
                    ForEach(rules) { rule in
                        HStack(spacing: 12) {
                            Toggle("", isOn: Binding(
                                get: { rule.enabled },
                                set: { on in
                                    var r = rule
                                    r.enabled = on
                                    _ = ExportService.shared.saveRule(r)
                                    reload()
                                }
                            ))
                            .labelsHidden()
                            .controlSize(.small)
                            .tint(Color.rbAccent)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.name.isEmpty ? "未命名" : rule.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.rbText)
                                Text("\(rule.triggerDisplay) → \(rule.targetDisplay)")
                                    .font(.caption).foregroundStyle(Color.rbText2)
                                Text(statsText(for: rule.id))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Color.rbText3)
                            }
                            Spacer()

                            if runningId == rule.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("立即执行") {
                                    runningId = rule.id
                                    Task {
                                        await ExportService.shared.runFor(ruleId: rule.id)
                                        runningId = nil
                                        reload()
                                    }
                                }
                                .controlSize(.small)
                                .disabled(!rule.enabled)
                            }

                            Button {
                                editing = rule
                                showEditor = true
                            } label: { Image(systemName: "pencil") }
                            .buttonStyle(.quiet)

                            Button(role: .destructive) {
                                deletingRule = rule
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.quiet)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("导出规则")
                    .font(.headline)
                    .foregroundStyle(Color.rbText)
            }
        }
        .sheet(isPresented: $showEditor) {
            ExportRuleEditor(rule: editing ?? ExportRule(
                id: 0, name: "", enabled: true, criteria: ExportRule.Criteria(),
                triggerOn: "manual", target: "mddir", targetConfig: [:], lastRunAt: nil)
            ) { saved in
                let isEdit = saved.id != 0
                _ = ExportService.shared.saveRule(saved)
                // 编辑已有规则（改了配置）→ 清除已交付记录，下次「立即执行」全量重导
                // 修 P1-11：否则改配置后已交付的永不重导，看似没反应
                if isEdit { ExportService.shared.resetDelivered(ruleId: saved.id) }
                showEditor = false
                reload()
            }
        }
        .alert("删除导出规则", isPresented: Binding(
            get: { deletingRule != nil },
            set: { if !$0 { deletingRule = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let r = deletingRule {
                    ExportService.shared.deleteRule(id: r.id)
                    reload()
                }
                deletingRule = nil
            }
            Button("取消", role: .cancel) { deletingRule = nil }
        } message: {
            Text("将删除规则「\(deletingRule?.name ?? "")」。已导出的文件不受影响，但导出记录会一并清除。")
        }
        .onAppear(perform: reload)
    }

    // MARK: - 平台配置区（7 平台登录/预设位置）

    private var platformConfigSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导出平台配置")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.rbText)

            // 笔记软件
            VStack(alignment: .leading, spacing: 8) {
                Text("笔记软件")
                    .font(.caption)
                    .foregroundStyle(Color.rbText3)
                HStack(spacing: 16) {
                    // Obsidian
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Obsidian")
                            .font(.system(size: 12, weight: .medium))
                        HStack {
                            Text(ExportPlatformConfig.shared.obsidianDir.isEmpty ? "未设置目录" : ExportPlatformConfig.shared.obsidianDir)
                                .font(.caption)
                                .foregroundStyle(Color.rbText3)
                                .lineLimit(1)
                            Button("选择…") { pickObsidianDir() }
                                .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Notion
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notion")
                            .font(.system(size: 12, weight: .medium))
                        TextField("Integration Token", text: Binding(
                            get: { ExportPlatformConfig.shared.notionToken },
                            set: { ExportPlatformConfig.shared.notionToken = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        TextField("Database ID", text: Binding(
                            get: { ExportPlatformConfig.shared.notionDatabaseId },
                            set: { ExportPlatformConfig.shared.notionDatabaseId = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // NotebookLM
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NotebookLM")
                            .font(.system(size: 12, weight: .medium))
                        Text("API 待 Google 开放")
                            .font(.caption)
                            .foregroundStyle(Color.rbText3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // 稍后读
            VStack(alignment: .leading, spacing: 8) {
                Text("稍后读")
                    .font(.caption)
                    .foregroundStyle(Color.rbText3)
                HStack(spacing: 16) {
                    // Cubox
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cubox")
                            .font(.system(size: 12, weight: .medium))
                        TextField("API Token", text: Binding(
                            get: { ExportPlatformConfig.shared.cuboxToken },
                            set: { ExportPlatformConfig.shared.cuboxToken = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Instapaper
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Instapaper")
                            .font(.system(size: 12, weight: .medium))
                        TextField("用户名", text: Binding(
                            get: { ExportPlatformConfig.shared.instapaperUser },
                            set: { ExportPlatformConfig.shared.instapaperUser = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        SecureField("密码", text: Binding(
                            get: { ExportPlatformConfig.shared.instapaperPass },
                            set: { ExportPlatformConfig.shared.instapaperPass = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Readwise
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Readwise")
                            .font(.system(size: 12, weight: .medium))
                        TextField("API Token", text: Binding(
                            get: { ExportPlatformConfig.shared.readwiseToken },
                            set: { ExportPlatformConfig.shared.readwiseToken = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Webhook
            VStack(alignment: .leading, spacing: 8) {
                Text("通用")
                    .font(.caption)
                    .foregroundStyle(Color.rbText3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Webhook")
                        .font(.system(size: 12, weight: .medium))
                    TextField("Webhook URL（POST JSON）", text: Binding(
                        get: { ExportPlatformConfig.shared.webhookURL },
                        set: { ExportPlatformConfig.shared.webhookURL = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                }
            }
        }
        .padding(12)
        .background(Color.rbSurface)
        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
    }

    private func pickObsidianDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择 Obsidian 仓库目录"
        if panel.runModal() == .OK, let url = panel.url {
            ExportPlatformConfig.shared.obsidianDir = url.path
        }
    }

    private func reload() {
        rules = ExportService.shared.listRules()
    }

    private func statsText(for ruleId: Int64) -> String {
        let s = ExportService.shared.statsFor(ruleId: ruleId)
        return "已交付 \(s.delivered) 条" + (s.failed > 0 ? "，失败 \(s.failed)" : "")
    }
}

// MARK: - 规则编辑表单

public struct ExportRuleEditor: View {
    @State var rule: ExportRule
    let onSave: (ExportRule) -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var sourceStore = SourceStore.shared
    @State private var minScoreText = ""
    @State private var dir = ""
    @State private var bySource = false
    @State private var webhookURL = ""
    @State private var selectedSourceIds: Set<Int64> = []
    // 各平台 token 配置
    @State private var cuboxToken = ""
    @State private var instapaperUser = ""
    @State private var instapaperPass = ""
    @State private var readwiseToken = ""
    @State private var notebooklmToken = ""
    @State private var notionToken = ""
    @State private var notionDatabaseId = ""
    // 规则组合筛选
    @State private var selectedFolderIds: Set<Int64> = []
    @State private var keywordsText = ""
    @State private var selectedContentTypes: Set<String> = []
    @State private var selectedLanguages: Set<String> = []

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("基本信息") {
                    TextField("规则名称", text: $rule.name)
                    Picker("触发时机", selection: $rule.triggerOn) {
                        Text("手动执行").tag("manual")
                        Text("打分完成后").tag("score")
                        Text("翻译完成后").tag("translate")
                        Text("转录完成后").tag("transcribe")
                    }
                    .tint(Color.rbAccent)
                }

                Section("筛选条件（全部满足才导出）") {
                    HStack {
                        Text("最低评分")
                        TextField("不限", text: $minScoreText)
                            .frame(width: 60)
                            .onChange(of: minScoreText) { _, v in
                                rule.criteria.minScore = Int(v)
                            }
                    }
                    // 限定文件夹（多选 OR）
                    HStack {
                        Text("限定文件夹")
                        Spacer()
                        Menu {
                            ForEach(sourceStore.folders) { folder in
                                Button {
                                    if selectedFolderIds.contains(folder.id) {
                                        selectedFolderIds.remove(folder.id)
                                    } else {
                                        selectedFolderIds.insert(folder.id)
                                    }
                                    rule.criteria.folderIds = selectedFolderIds.isEmpty ? nil : Array(selectedFolderIds)
                                } label: {
                                    HStack {
                                        Text(folder.name)
                                        if selectedFolderIds.contains(folder.id) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                            if !selectedFolderIds.isEmpty {
                                Divider()
                                Button("清除全部") {
                                    selectedFolderIds.removeAll()
                                    rule.criteria.folderIds = nil
                                }
                            }
                        } label: {
                            Text(selectedFolderIds.isEmpty
                                 ? "全部文件夹"
                                 : "已选 \(selectedFolderIds.count) 个文件夹")
                        }
                        .menuStyle(.borderlessButton)
                        .tint(Color.rbAccent)
                    }
                    // 限定来源（不选 = 全部源）
                    HStack {
                        Text("限定来源")
                        Spacer()
                        Menu {
                            ForEach(sourceStore.sources) { src in
                                Button {
                                    if selectedSourceIds.contains(src.id) {
                                        selectedSourceIds.remove(src.id)
                                    } else {
                                        selectedSourceIds.insert(src.id)
                                    }
                                    rule.criteria.sourceIds = selectedSourceIds.isEmpty ? nil : Array(selectedSourceIds)
                                } label: {
                                    HStack {
                                        Text(src.name)
                                        if selectedSourceIds.contains(src.id) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                            if !selectedSourceIds.isEmpty {
                                Divider()
                                Button("清除全部") {
                                    selectedSourceIds.removeAll()
                                    rule.criteria.sourceIds = nil
                                }
                            }
                        } label: {
                            Text(selectedSourceIds.isEmpty
                                 ? "全部源"
                                 : "已选 \(selectedSourceIds.count) 个源")
                        }
                        .menuStyle(.borderlessButton)
                        .tint(Color.rbAccent)
                    }
                    // 已读状态
                    Picker("已读状态", selection: $rule.criteria.readStatus) {
                        Text("全部").tag(nil as String?)
                        Text("仅已读").tag("read" as String?)
                        Text("仅未读").tag("unread" as String?)
                    }
                    .tint(Color.rbAccent)
                    // 关键词
                    HStack {
                        Text("关键词")
                        TextField("标题/正文包含（逗号分隔多个）", text: $keywordsText)
                            .onChange(of: keywordsText) { _, v in
                                let kws = v.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                rule.criteria.keywords = kws.isEmpty ? nil : kws
                            }
                    }
                    // 内容类型
                    HStack {
                        Text("内容类型")
                        Spacer()
                        Menu {
                            ForEach(["article", "podcast", "video"], id: \.self) { ct in
                                Button {
                                    if selectedContentTypes.contains(ct) {
                                        selectedContentTypes.remove(ct)
                                    } else {
                                        selectedContentTypes.insert(ct)
                                    }
                                    rule.criteria.contentTypes = selectedContentTypes.isEmpty ? nil : Array(selectedContentTypes)
                                } label: {
                                    HStack {
                                        Text(ct == "article" ? "文章" : ct == "podcast" ? "播客" : "视频")
                                        if selectedContentTypes.contains(ct) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(selectedContentTypes.isEmpty
                                 ? "全部类型"
                                 : "已选 \(selectedContentTypes.count) 类")
                        }
                        .menuStyle(.borderlessButton)
                        .tint(Color.rbAccent)
                    }
                    // 语言
                    HStack {
                        Text("语言")
                        Spacer()
                        Menu {
                            ForEach(["zh", "en"], id: \.self) { lang in
                                Button {
                                    if selectedLanguages.contains(lang) {
                                        selectedLanguages.remove(lang)
                                    } else {
                                        selectedLanguages.insert(lang)
                                    }
                                    rule.criteria.languages = selectedLanguages.isEmpty ? nil : Array(selectedLanguages)
                                } label: {
                                    HStack {
                                        Text(lang == "zh" ? "中文" : "英文")
                                        if selectedLanguages.contains(lang) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(selectedLanguages.isEmpty
                                 ? "全部语言"
                                 : "已选 \(selectedLanguages.count) 种")
                        }
                        .menuStyle(.borderlessButton)
                        .tint(Color.rbAccent)
                    }
                    Toggle("只导已翻译的", isOn: $rule.criteria.requireTranslated)
                        .tint(Color.rbAccent)
                    Toggle("只导已转录的（播客/视频）", isOn: $rule.criteria.requireTranscribed)
                        .tint(Color.rbAccent)
                    Toggle("只导有摘要的", isOn: $rule.criteria.requireSummary)
                        .tint(Color.rbAccent)
                    Toggle("只导星标内容", isOn: $rule.criteria.starredOnly)
                        .tint(Color.rbAccent)
                }

                Section("导出目标") {
                    Picker("目标类型", selection: $rule.target) {
                        Text("Markdown 目录").tag("mddir")
                        Text("Obsidian 仓库").tag("obsidian")
                        Text("Webhook").tag("webhook")
                        Divider()
                        Text("Cubox").tag("cubox")
                        Text("Instapaper").tag("instapaper")
                        Text("Readwise").tag("readwise")
                        Text("NotebookLM").tag("notebooklm")
                        Text("Notion").tag("notion")
                    }
                    .tint(Color.rbAccent)
                    // 本地目录（mddir/obsidian）
                    if rule.target == "obsidian" || rule.target == "mddir" {
                        HStack {
                            Text(dir.isEmpty
                                 ? (rule.target == "obsidian" ? "选择 Obsidian 仓库目录" : "选择输出目录")
                                 : dir)
                                .font(.callout)
                                .foregroundStyle(dir.isEmpty ? Color.rbText3 : Color.rbText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("选择…") { pickTargetDir() }
                                .controlSize(.small)
                        }
                        Toggle("按来源建子目录", isOn: $bySource)
                            .tint(Color.rbAccent)
                            .onChange(of: bySource) { _, v in rule.targetConfig["subdir_by_source"] = v }
                        // 覆盖选项：覆盖原文件（重入库更新）vs 生成新文件（保留历史版本）
                        Picker("重入库时", selection: $rule.overwrite) {
                            Text("覆盖原文件").tag(true)
                            Text("生成新文件（保留历史）").tag(false)
                        }
                        .tint(Color.rbAccent)
                    }
                    // Webhook
                    else if rule.target == "webhook" {
                        TextField("Webhook URL（POST JSON）", text: $webhookURL)
                            .onChange(of: webhookURL) { _, v in rule.targetConfig["url"] = v }
                    }
                    // Cubox
                    else if rule.target == "cubox" {
                        TextField("Cubox API Token", text: $cuboxToken)
                            .onChange(of: cuboxToken) { _, v in rule.targetConfig["token"] = v }
                    }
                    // Instapaper
                    else if rule.target == "instapaper" {
                        TextField("Instapaper 用户名", text: $instapaperUser)
                            .onChange(of: instapaperUser) { _, v in rule.targetConfig["username"] = v }
                        SecureField("Instapaper 密码", text: $instapaperPass)
                            .onChange(of: instapaperPass) { _, v in rule.targetConfig["password"] = v }
                    }
                    // Readwise
                    else if rule.target == "readwise" {
                        TextField("Readwise API Token", text: $readwiseToken)
                            .onChange(of: readwiseToken) { _, v in rule.targetConfig["token"] = v }
                    }
                    // NotebookLM
                    else if rule.target == "notebooklm" {
                        TextField("Google OAuth Token", text: $notebooklmToken)
                            .onChange(of: notebooklmToken) { _, v in rule.targetConfig["token"] = v }
                        Text("NotebookLM API 暂未开放稳定端点，待 Google 官方支持")
                            .font(.caption)
                            .foregroundStyle(Color.rbText3)
                    }
                    // Notion
                    else if rule.target == "notion" {
                        TextField("Notion Integration Token", text: $notionToken)
                            .onChange(of: notionToken) { _, v in rule.targetConfig["token"] = v }
                        TextField("Notion Database ID", text: $notionDatabaseId)
                            .onChange(of: notionDatabaseId) { _, v in rule.targetConfig["database_id"] = v }
                    }
                }
            }
            .formStyle(.grouped)

            Hairline()
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.quiet)
                Spacer()
                Button("保存") {
                    onSave(rule)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.primaryCapsule)
                .disabled(rule.name.isEmpty || !targetValid)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 600)
        .navigationTitle(rule.id == 0 ? "新建导出规则" : "编辑导出规则")
        .onAppear {
            minScoreText = rule.criteria.minScore.map { String($0) } ?? ""
            dir = rule.targetConfig["dir"] as? String ?? ""
            bySource = rule.targetConfig["subdir_by_source"] as? Bool ?? false
            webhookURL = rule.targetConfig["url"] as? String ?? ""
            selectedSourceIds = Set(rule.criteria.sourceIds ?? [])
            if sourceStore.sources.isEmpty { sourceStore.reload() }
        }
    }

    /// 系统文件夹选择器选导出目录（Markdown 目录 / Obsidian 仓库）
    private func pickTargetDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = rule.target == "obsidian" ? "选择 Obsidian 仓库目录" : "选择 Markdown 输出目录"
        if panel.runModal() == .OK, let url = panel.url {
            dir = url.path
            rule.targetConfig["dir"] = url.path
        }
    }

    private var targetValid: Bool {
        switch rule.target {
        case "obsidian", "mddir": return !dir.isEmpty
        case "webhook": return webhookURL.hasPrefix("http")
        default: return false
        }
    }
}
