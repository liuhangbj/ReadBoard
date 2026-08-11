import SwiftUI
import ReadBoardContract
import ReadBoardUI

// MARK: - 导出规则管理（后处理板块）

public struct ReadBoardExportRulesSettingsPane: View {
    @State private var rules: [ExportRuleDTO] = []
    @State private var stats: [Int64: ExportRuleStatsDTO] = [:]
    @State private var editing: ExportRuleDTO? = nil
    @State private var showEditor = false
    @State private var runningId: Int64? = nil
    @State private var deletingRule: ExportRuleDTO? = nil
    private let export: any ExportGateway
    private let sourceCatalog: any SourceCatalogGateway
    private let configuration: any ConfigurationGateway
    @State private var platforms = ExportPlatformConfiguration()

    public init(
        export: any ExportGateway,
        sourceCatalog: any SourceCatalogGateway,
        configuration: any ConfigurationGateway
    ) {
        self.export = export
        self.sourceCatalog = sourceCatalog
        self.configuration = configuration
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("导出规则").font(.system(size: ReadBoardDesign.F.pageTitle, weight: .semibold)).foregroundStyle(ReadBoardDesign.C.text)
                if !rules.isEmpty { Text("\(rules.count)").font(.system(size: 13)).foregroundStyle(ReadBoardDesign.C.text3) }
                Spacer()
                Button {
                    editing = ExportRuleDTO()
                    showEditor = true
                } label: { Label("新建规则", systemImage: "plus") }.buttonStyle(ReadBoardPrimaryButtonStyle())
            }.padding(.horizontal, 20).padding(.vertical, 14)
            ReadBoardHairline()
            if rules.isEmpty {
                ContentUnavailableView("还没有导出规则", systemImage: "square.and.arrow.up", description: Text("新建一条规则：按条件把内容自动导出到 Obsidian 或 Webhook。"))
            } else {
                List {
                    ForEach(rules) { rule in ruleRow(rule) }
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            ReadBoardExportRuleEditor(
                rule: editing ?? ExportRuleDTO(),
                export: export,
                sourceCatalog: sourceCatalog,
                platforms: platforms
            ) { saved, _ in
                Task {
                    _ = try? await export.save(rule: saved)
                    showEditor = false
                    await reload()
                }
            }
        }
        .alert("删除导出规则", isPresented: Binding(get: { deletingRule != nil }, set: { if !$0 { deletingRule = nil } })) {
            Button("删除", role: .destructive) {
                guard let rule = deletingRule else { return }
                deletingRule = nil
                Task {
                    try? await export.delete(ruleID: rule.id)
                    await reload()
                }
            }
            Button("取消", role: .cancel) { deletingRule = nil }
        } message: { Text("将删除规则「\(deletingRule?.name ?? "")」。已导出的文件不受影响。") }
        .task { await reload() }
    }

    private func ruleRow(_ rule: ExportRuleDTO) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in
                var updated = rule
                updated.enabled = on
                Task {
                    _ = try? await export.save(rule: updated)
                    await reload()
                }
            })).labelsHidden().controlSize(.small).tint(ReadBoardDesign.C.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name.isEmpty ? "未命名" : rule.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(ReadBoardDesign.C.text)
                Text("\(rule.triggerDisplay) → \(rule.targetDisplay)").font(.callout).foregroundStyle(ReadBoardDesign.C.text2)
                Text(statsText(for: rule.id)).font(.caption2.monospacedDigit()).foregroundStyle(ReadBoardDesign.C.text3)
            }
            Spacer()
            if runningId == rule.id { ProgressView().controlSize(.small) }
            else { Button("立即执行") { runningId = rule.id; Task { _ = try? await export.run(ruleID: rule.id); runningId = nil; await reload() } }.controlSize(.small).disabled(!rule.enabled) }
            Button { editing = rule; showEditor = true } label: { Image(systemName: "pencil") }.buttonStyle(ReadBoardQuietButtonStyle())
            Button(role: .destructive) { deletingRule = rule } label: { Image(systemName: "trash") }.buttonStyle(ReadBoardQuietButtonStyle())
        }.padding(.vertical, 4)
    }
    @MainActor
    private func reload() async {
        let loaded = (try? await export.rules()) ?? []
        var nextStats: [Int64: ExportRuleStatsDTO] = [:]
        for rule in loaded {
            if let value = try? await export.stats(ruleID: rule.id) {
                nextStats[rule.id] = value
            }
        }
        rules = loaded
        stats = nextStats
        if let loadedPlatforms = try? await configuration.snapshot().exportPlatforms {
            platforms = loadedPlatforms
        }
    }

    private func statsText(for ruleID: Int64) -> String {
        let value = stats[ruleID] ?? .init(delivered: 0, failed: 0)
        return "已交付 \(value.delivered) 条" + (value.failed > 0 ? "，失败 \(value.failed)" : "")
    }
}

// MARK: - 平台配置区

// MARK: - 规则编辑表单

public struct ReadBoardExportRuleEditor: View {
    @State var rule: ExportRuleDTO
    let onSave: (ExportRuleDTO, Bool) -> Void
    private let export: any ExportGateway
    private let platforms: ExportPlatformConfiguration
    private let sourceCatalog: any SourceCatalogGateway
    @Environment(\.dismiss) private var dismiss
    @State private var catalog = SourceCatalogSnapshot()

    // 筛选状态
    @State private var minScoreText = ""; @State private var keywordsText = ""; @State private var excludeKeywordsText = ""
    @State private var selectedSourceIds: Set<Int64> = []; @State private var selectedFolderIds: Set<Int64> = []
    @State private var selectedContentTypes: Set<String> = []; @State private var selectedPlatforms: Set<String> = []
    @State private var selectedLanguages: Set<String> = []; @State private var selectedFrontmatterFields: Set<String> = []
    @State private var fieldLabelOverrides: [String: String] = [:]

    // 导出配置
    @State private var subfolder = ""
    @State private var artifactType = "original"; @State private var missingPolicy = "wait"
    @State private var useTranslatedTitle = false; @State private var titleTemplate = "{title}-{id}"
    @State private var writePolicy = "overwrite"; @State private var historyScope = "new_only"
    @State private var historyAfterDate = Date()
    @State private var scheduleInterval = "daily"
    @State private var publishedAfterEnabled = false; @State private var publishedBeforeEnabled = false
    @State private var publishedAfter = Date(); @State private var publishedBefore = Date()

    // 预览
    @State private var preview: ExportRulePreviewDTO?; @State private var showPreview = false; @State private var isPreviewing = false

    private let allFFields = ["title","source","author","url","score","ctype","published","summary","id","language","artifact"]
    private let fLabels: [String:String] = ["title":"标题","source":"来源","author":"作者","url":"原始链接","score":"评分","ctype":"内容类型","published":"发布日期","summary":"摘要","id":"ReadBoard ID","language":"语言","artifact":"文稿类型"]

    private func isPlatformEnabled(_ id: String) -> Bool {
        id == "webhook" ? platforms.webhookEnabled : platforms.obsidianEnabled
    }

    public init(
        rule: ExportRuleDTO,
        export: any ExportGateway,
        sourceCatalog: any SourceCatalogGateway,
        platforms: ExportPlatformConfiguration,
        onSave: @escaping (ExportRuleDTO, Bool) -> Void
    ) {
        self._rule = State(initialValue: rule)
        self.export = export
        self.sourceCatalog = sourceCatalog
        self.platforms = platforms
        self.onSave = onSave
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Form {
                    Section("基本信息") {
                        TextField("规则名称", text: $rule.name).font(.callout)
                        Picker("目标平台", selection: $rule.target) {
                            Text("Obsidian").tag("obsidian")
                            Text("Webhook").tag("webhook")
                        }.tint(ReadBoardDesign.C.accent)
                        if !isPlatformEnabled(rule.target) {
                            Text("该平台尚未启用；规则会保存，但启用平台前不会执行。")
                                .font(.caption2).foregroundStyle(ReadBoardDesign.C.scoreMid)
                        }
                        Picker("触发时机", selection: $rule.trigger) {
                            Text("内容入库后").tag("ingest"); Text("加工完成后").tag("ready")
                            Text("加星标时").tag("starred"); Text("定时批量导出").tag("scheduled")
                            Text("手动执行").tag("manual")
                        }.tint(ReadBoardDesign.C.accent)
                        if rule.trigger == "scheduled" {
                            Picker("执行频率", selection: $scheduleInterval) {
                                Text("每小时").tag("hourly"); Text("每天").tag("daily"); Text("每周").tag("weekly")
                            }.tint(ReadBoardDesign.C.accent)
                        }
                    }
                    Section("筛选条件（全部满足才导出）") {
                        selectionMenu(title: "订阅源", summary: selectedSourceIds.isEmpty ? "全部" : "已选 \(selectedSourceIds.count) 个", items: catalog.sources.map{($0.id,$0.name)}, selection: $selectedSourceIds)
                        selectionMenu(title: "文件夹", summary: selectedFolderIds.isEmpty ? "全部" : "已选 \(selectedFolderIds.count) 个", items: catalog.folders.map{($0.id,$0.name)}, selection: $selectedFolderIds)
                        stringSelectionMenu(title: "内容类型", summary: ctSummary, items: [("article","文章"),("podcast","播客"),("video","视频")], selection: $selectedContentTypes)
                        stringSelectionMenu(title: "来源平台", summary: plSummary, items: [("rss","RSS"),("podcast","播客"),("youtube","YouTube"),("wechat","公众号")], selection: $selectedPlatforms)
                        HStack { Text("最低评分").font(.callout).foregroundStyle(ReadBoardDesign.C.text2); Spacer(); TextField("不限", text: $minScoreText).textFieldStyle(.roundedBorder).frame(width:80).multilineTextAlignment(.trailing) }
                        stringSelectionMenu(title: "内容语言", summary: langSummary, items: [("zh","中文"),("en","英文"),("ja","日文")], selection: $selectedLanguages)
                        Picker("已读状态", selection: $rule.criteria.readStatus) {
                            Text("全部").tag(nil as String?); Text("未读").tag("unread" as String?); Text("已读").tag("read" as String?)
                        }.tint(ReadBoardDesign.C.accent)
                        VStack(alignment: .leading, spacing:5) { Text("关键词").font(.callout).foregroundStyle(ReadBoardDesign.C.text2); TextField("多个关键词用逗号分隔", text: $keywordsText).textFieldStyle(.roundedBorder) }
                        VStack(alignment: .leading, spacing:5) { Text("排除关键词").font(.callout).foregroundStyle(ReadBoardDesign.C.text2); TextField("多个关键词用逗号分隔", text: $excludeKeywordsText).textFieldStyle(.roundedBorder) }
                        Toggle("限制起始日期", isOn: $publishedAfterEnabled).tint(ReadBoardDesign.C.accent)
                        if publishedAfterEnabled { DatePicker("不早于", selection: $publishedAfter, displayedComponents: .date) }
                        Toggle("限制结束日期", isOn: $publishedBeforeEnabled).tint(ReadBoardDesign.C.accent)
                        if publishedBeforeEnabled { DatePicker("不晚于", selection: $publishedBefore, displayedComponents: .date) }
                    }
                    Section("加工完成条件") {
                        Toggle("评分完成", isOn: $rule.criteria.requireScored).tint(ReadBoardDesign.C.accent)
                        Toggle("摘要完成", isOn: $rule.criteria.requireSummary).tint(ReadBoardDesign.C.accent)
                        Toggle("译文完成", isOn: $rule.criteria.requireTranslated).tint(ReadBoardDesign.C.accent)
                        Toggle("转录完成", isOn: $rule.criteria.requireTranscribed).tint(ReadBoardDesign.C.accent)
                    }
                    Section("导出文稿") {
                        Toggle("标题使用中文译文（若存在）", isOn: $useTranslatedTitle).tint(ReadBoardDesign.C.accent)
                        Picker("文稿类型", selection: $artifactType) {
                            Text("原文").tag("original"); Text("译文").tag("translated")
                            Text("转录稿").tag("transcript"); Text("摘要").tag("summary")
                            Text("摘要＋原文").tag("summary_original"); Text("摘要＋译文").tag("summary_translated")
                            Text("摘要＋转录稿").tag("summary_transcript")
                        }.tint(ReadBoardDesign.C.accent)
                        Picker("内容缺失时", selection: $missingPolicy) {
                            Text("等待生成").tag("wait"); Text("回退到原文").tag("fallback_original")
                            Text("跳过内容").tag("skip")
                        }.tint(ReadBoardDesign.C.accent)
                    }
                    Section(rule.target == "webhook" ? "交付设置" : "目标与文件") {
                        if rule.target == "webhook" {
                            LabeledContent("Webhook URL") {
                                Text(platforms.webhookURL.isEmpty ? "未配置" : platforms.webhookURL)
                                    .foregroundStyle(platforms.webhookURL.isEmpty ? ReadBoardDesign.C.scoreMid : ReadBoardDesign.C.text2)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Text("地址和请求 Header 请在“导出平台”页面统一配置。")
                                .font(.caption2).foregroundStyle(ReadBoardDesign.C.text3)
                        } else {
                            LabeledContent("Obsidian Vault") {
                                Text(platforms.obsidianDirectory.isEmpty ? "未配置" : platforms.obsidianDirectory)
                                    .foregroundStyle(platforms.obsidianDirectory.isEmpty ? ReadBoardDesign.C.scoreMid : ReadBoardDesign.C.text2)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            TextField("子目录模板", text: $subfolder, prompt: Text("{source}/{year}/{month}"))
                            TextField("文件名模板", text: $titleTemplate, prompt: Text("{date} {title}-{id}"))
                            Text("可用占位符：{title} {date} {id} {source} {ctype} {score} {year} {month}").font(.caption2).foregroundStyle(ReadBoardDesign.C.text3)
                            Picker("已有文件", selection: $writePolicy) {
                                Text("内容变化时覆盖").tag("overwrite"); Text("跳过").tag("skip"); Text("生成新版本").tag("versioned")
                            }.tint(ReadBoardDesign.C.accent)
                        }
                        Picker("历史范围", selection: $historyScope) {
                            Text("仅规则创建后的新内容").tag("new_only"); Text("回填所有历史匹配内容").tag("all")
                            Text("指定日期之后").tag("custom_date")
                        }.tint(ReadBoardDesign.C.accent)
                        if historyScope == "custom_date" {
                            DatePicker("起始日期", selection: $historyAfterDate, displayedComponents: .date)
                        }
                    }
                    Section("Frontmatter 字段") {
                        let columns: [GridItem] = [
                            GridItem(.fixed(120), spacing: 8, alignment: .leading),
                            GridItem(.fixed(120), spacing: 8, alignment: .leading),
                            GridItem(.fixed(46), spacing: 50, alignment: .center),
                            GridItem(.fixed(140), spacing: 0, alignment: .leading)
                        ]
                        VStack(spacing: 1) {
                            // 表头
                            LazyVGrid(columns: columns, spacing: 0) {
                                Text("数据项").font(.callout).foregroundStyle(ReadBoardDesign.C.text3)
                                Text("字段名").font(.callout).foregroundStyle(ReadBoardDesign.C.text3)
                                Text("开关").font(.callout).foregroundStyle(ReadBoardDesign.C.text3)
                                Text("导出字段名").font(.callout).foregroundStyle(ReadBoardDesign.C.text3).padding(.leading, 8)
                            }.padding(.horizontal, 4).padding(.vertical, 5)
                            Divider()
                            ForEach(allFFields, id: \.self) { field in
                                LazyVGrid(columns: columns, spacing: 0) {
                                    Text(fLabels[field] ?? field).font(.callout).foregroundStyle(ReadBoardDesign.C.text)
                                    Text(field).font(.caption.monospaced()).foregroundStyle(ReadBoardDesign.C.text3)
                                    Toggle("", isOn: fBind(field)).tint(ReadBoardDesign.C.accent).labelsHidden()
                                    if selectedFrontmatterFields.contains(field) {
                                        TextField("", text: lBind(field),
                                                  prompt: Text(fLabels[field] ?? field))
                                            .textFieldStyle(.plain).font(.callout)
                                            .padding(.horizontal, 8).padding(.vertical, 3)
                                            .background(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                                    } else {
                                        Color.clear.frame(height: 1)
                                    }
                                }.padding(.horizontal, 4).padding(.vertical, 4)
                                Divider()
                            }
                        }
                    }
                    Section("附件") {
                        LabeledContent("图片与附件") { Text("保留远程链接").foregroundStyle(ReadBoardDesign.C.text2) }
                        Text("第一版不会复制图片、音频或视频文件。").font(.caption2).foregroundStyle(ReadBoardDesign.C.text3)
                    }
                }.formStyle(.grouped)
            }
            ReadBoardHairline()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(ReadBoardQuietButtonStyle())
                Spacer()
                Button { previewRule() } label: { if isPreviewing { ProgressView().controlSize(.small) } else { Text("预览") } }
                    .disabled(isPreviewing || rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("保存") { onSave(draftRule(), rule.id > 0) }.keyboardShortcut(.defaultAction)
                    .buttonStyle(ReadBoardPrimaryButtonStyle()).disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 580, idealHeight: 780)
        .navigationTitle(rule.id == 0 ? "新建导出规则" : "编辑导出规则")
        .onAppear { load() }
        .task { await refreshCatalog() }
        .sheet(isPresented: $showPreview) { if let preview { ExportRulePreviewView(preview: preview) } }
    }

    // MARK: helpers
    private func draftRule() -> ExportRuleDTO {
        var r = rule; r.name = r.name.trimmingCharacters(in: .whitespaces)
        r.criteria.minimumScore = Int(minScoreText).flatMap{$0>0 ? $0:nil}
        r.criteria.sourceIDs = selectedSourceIds.isEmpty ? nil : Array(selectedSourceIds).sorted()
        r.criteria.folderIDs = selectedFolderIds.isEmpty ? nil : Array(selectedFolderIds).sorted()
        r.criteria.contentTypes = selectedContentTypes.isEmpty ? nil : Array(selectedContentTypes).sorted()
        r.criteria.platforms = selectedPlatforms.isEmpty ? nil : Array(selectedPlatforms).sorted()
        r.criteria.languages = selectedLanguages.isEmpty ? nil : Array(selectedLanguages).sorted()
        let kw = keywordsText.components(separatedBy: CharacterSet(charactersIn: ",，\n")).map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}
        r.criteria.keywords = kw.isEmpty ? nil : kw
        let ek = excludeKeywordsText.components(separatedBy: CharacterSet(charactersIn: ",，\n")).map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}
        r.criteria.excludedKeywords = ek.isEmpty ? nil : ek
        r.criteria.publishedAfter = publishedAfterEnabled ? fmtDay(publishedAfter) : nil
        // 只保存日期；查询层把结束日转换成“次日零点之前”，兼容空格和 ISO T/Z 时间。
        r.criteria.publishedBefore = publishedBeforeEnabled ? fmtDay(publishedBefore) : nil
        r.target = rule.target == "webhook" ? "webhook" : "obsidian"
        // 平台地址与凭证由“导出平台”页面统一维护，规则不复制这些配置。
        r.subfolderTemplate = subfolder.trimmingCharacters(in:.whitespaces)
        r.artifact = artifactType; r.missingPolicy = missingPolicy; r.writePolicy = writePolicy
        r.historyScope = historyScope; r.historyAfter = historyScope == "custom_date" ? fmtDay(historyAfterDate) : nil
        r.scheduleInterval = scheduleInterval
        r.titleTemplate = titleTemplate.trimmingCharacters(in:.whitespaces).isEmpty ? "{title}-{id}" : titleTemplate.trimmingCharacters(in:.whitespaces)
        r.frontmatterFields = selectedFrontmatterFields.isEmpty ? nil : Array(selectedFrontmatterFields).sorted()
        r.useTranslatedTitle = useTranslatedTitle
        r.frontmatterLabels = fieldLabelOverrides.isEmpty ? nil : fieldLabelOverrides
        return r
    }

    private func load() {
        minScoreText = rule.criteria.minimumScore.map(String.init) ?? ""
        keywordsText = (rule.criteria.keywords ?? []).joined(separator: "，")
        excludeKeywordsText = (rule.criteria.excludedKeywords ?? []).joined(separator: "，")
        if rule.target != "obsidian" && rule.target != "webhook" { rule.target = "obsidian" }
        subfolder = rule.subfolderTemplate; artifactType = rule.artifact
        missingPolicy = rule.missingPolicy; writePolicy = rule.writePolicy; historyScope = rule.historyScope
        if let ha = rule.historyAfter, let d = parseDay(ha) { historyAfterDate = d }
        scheduleInterval = rule.scheduleInterval
        useTranslatedTitle = rule.useTranslatedTitle; fieldLabelOverrides = rule.frontmatterLabels ?? [:]
        titleTemplate = rule.titleTemplate
        selectedSourceIds = Set(rule.criteria.sourceIDs ?? []); selectedFolderIds = Set(rule.criteria.folderIDs ?? [])
        selectedContentTypes = Set(rule.criteria.contentTypes ?? []); selectedPlatforms = Set(rule.criteria.platforms ?? [])
        selectedLanguages = Set(rule.criteria.languages ?? [])
        selectedFrontmatterFields = Set(rule.frontmatterFields ?? ["title","source","author","url","score","published","id"])
        if let v = rule.criteria.publishedAfter, let d = parseDay(v) { publishedAfterEnabled = true; publishedAfter = d }
        if let v = rule.criteria.publishedBefore, let d = parseDay(v) { publishedBeforeEnabled = true; publishedBefore = d }
    }

    private func previewRule() {
        let draft = draftRule()
        isPreviewing = true
        Task {
            preview = try? await export.preview(rule: draft)
            isPreviewing = false
            showPreview = preview != nil
        }
    }

    @MainActor
    private func refreshCatalog() async {
        if let loaded = try? await sourceCatalog.snapshot() {
            catalog = loaded
        }
    }

    private func fBind(_ f: String) -> Binding<Bool> { Binding(get:{selectedFrontmatterFields.contains(f)}, set:{if $0{selectedFrontmatterFields.insert(f)}else{selectedFrontmatterFields.remove(f)}}) }
    private func lBind(_ f: String) -> Binding<String> { Binding(get:{fieldLabelOverrides[f] ?? ""}, set:{v in let t=v.trimmingCharacters(in:.whitespaces); if t.isEmpty{fieldLabelOverrides.removeValue(forKey:f)}else{fieldLabelOverrides[f]=t}}) }

    private func selectionMenu(title: String, summary: String, items: [(Int64,String)], selection: Binding<Set<Int64>>) -> some View {
        HStack { Text(title).font(.callout).foregroundStyle(ReadBoardDesign.C.text2); Spacer(); Menu(summary) { Button("全部"){selection.wrappedValue.removeAll()}; Divider(); ForEach(items,id:\.0){item in Button{if selection.wrappedValue.contains(item.0){selection.wrappedValue.remove(item.0)}else{selection.wrappedValue.insert(item.0)}} label:{Label(item.1, systemImage:selection.wrappedValue.contains(item.0) ? "checkmark":"circle")}} }.menuStyle(.borderlessButton).fixedSize() }
    }
    private func stringSelectionMenu(title: String, summary: String, items: [(String,String)], selection: Binding<Set<String>>) -> some View {
        HStack { Text(title).font(.callout).foregroundStyle(ReadBoardDesign.C.text2); Spacer(); Menu(summary) { Button("全部"){selection.wrappedValue.removeAll()}; Divider(); ForEach(items,id:\.0){item in Button{if selection.wrappedValue.contains(item.0){selection.wrappedValue.remove(item.0)}else{selection.wrappedValue.insert(item.0)}} label:{Label(item.1, systemImage:selection.wrappedValue.contains(item.0) ? "checkmark":"circle")}} }.menuStyle(.borderlessButton).fixedSize() }
    }
    private var ctSummary: String { selSummary(selectedContentTypes, ["article":"文章","podcast":"播客","video":"视频"]) }
    private var plSummary: String { selSummary(selectedPlatforms, ["rss":"RSS","podcast":"播客","youtube":"YouTube","wechat":"公众号"]) }
    private var langSummary: String { selSummary(selectedLanguages, ["zh":"中文","en":"英文","ja":"日文"]) }
    private func selSummary(_ s: Set<String>, _ m: [String:String]) -> String { s.isEmpty ? "全部" : s.sorted().compactMap{m[$0]}.joined(separator:"、") }
    private func fmtDay(_ d: Date) -> String { let f=DateFormatter(); f.dateFormat="yyyy-MM-dd"; return f.string(from:d) }
    private func parseDay(_ v: String) -> Date? { let f=DateFormatter(); f.dateFormat="yyyy-MM-dd"; return f.date(from: String(v.prefix(10))) }
}

// MARK: - 预览面板

private struct ExportRulePreviewView: View {
    let preview: ExportRulePreviewDTO; @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading, spacing:14) {
            HStack{Text("导出预览").font(.headline);Spacer();Button("完成"){dismiss()}.keyboardShortcut(.defaultAction)}
            Text("共匹配 \(preview.matchingCount) 条，预览不写文件。").foregroundStyle(ReadBoardDesign.C.text2)
            if preview.samples.isEmpty { ContentUnavailableView("没有匹配内容", systemImage: "doc.text.magnifyingglass") }
            else { List(preview.samples, id:\.contentID){s in VStack(alignment:.leading, spacing:5){Text(s.title).font(.system(size:13,weight:.semibold)); if let i=s.issue{Text(i).font(.callout).foregroundStyle(ReadBoardDesign.C.scoreLow)} else if let d=s.destination{Text(d).font(.caption.monospaced()).foregroundStyle(ReadBoardDesign.C.text3).lineLimit(2).truncationMode(.middle)}; if let m=s.markdown{Text(String(m.prefix(400))).font(.callout).foregroundStyle(ReadBoardDesign.C.text2).lineLimit(6)}}.padding(.vertical,4)} }
        }.padding(20).frame(width:620,height:480)
    }
}

private extension ExportRuleDTO {
    var triggerDisplay: String {
        switch trigger {
        case "ingest": return "内容入库后"
        case "ready": return "加工完成后"
        case "starred": return "加星标时"
        case "scheduled": return "定时执行"
        default: return "手动执行"
        }
    }

    var targetDisplay: String {
        target == "webhook" ? "Webhook" : "Obsidian"
    }
}
