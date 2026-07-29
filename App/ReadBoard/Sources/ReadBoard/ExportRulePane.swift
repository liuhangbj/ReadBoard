import SwiftUI
import AppKit

// MARK: - 导出规则管理（后处理板块）

public struct ExportRulePane: View {
    @State private var rules: [ExportRule] = []
    @State private var editing: ExportRule? = nil
    @State private var showEditor = false
    @State private var runningId: Int64? = nil
    @State private var deletingRule: ExportRule? = nil

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("导出规则").font(.system(size: RB.F.pageTitle, weight: .semibold)).foregroundStyle(Color.rbText)
                if !rules.isEmpty { Text("\(rules.count)").font(.system(size: 13)).foregroundStyle(Color.rbText3) }
                Spacer()
                Button {
                    editing = ExportRule(id: 0, name: "", enabled: true, criteria: ExportRule.Criteria(), triggerOn: "manual", target: "obsidian", targetConfig: [:], lastRunAt: nil)
                    showEditor = true
                } label: { Label("新建规则", systemImage: "plus") }.buttonStyle(.primaryCapsule)
            }.padding(.horizontal, 20).padding(.vertical, 14)
            Hairline()
            platformConfigSection.padding(.horizontal, 20).padding(.vertical, 12)
            Hairline()
            if rules.isEmpty {
                ContentUnavailableView("还没有导出规则", systemImage: "square.and.arrow.up", description: Text("新建一条规则：按条件把内容自动导出到 Obsidian 或 Webhook。"))
            } else {
                List {
                    ForEach(rules) { rule in ruleRow(rule) }
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            ExportRuleEditor(rule: editing ?? ExportRule(id: 0, name: "", enabled: true, criteria: ExportRule.Criteria(), triggerOn: "manual", target: "obsidian", targetConfig: [:], lastRunAt: nil)) { saved, isEdit in
                _ = ExportService.shared.saveRule(saved)
                if isEdit { ExportService.shared.resetDelivered(ruleId: saved.id) }
                showEditor = false; reload()
            }
        }
        .alert("删除导出规则", isPresented: Binding(get: { deletingRule != nil }, set: { if !$0 { deletingRule = nil } })) {
            Button("删除", role: .destructive) { if let r = deletingRule { ExportService.shared.deleteRule(id: r.id); reload() }; deletingRule = nil }
            Button("取消", role: .cancel) { deletingRule = nil }
        } message: { Text("将删除规则「\(deletingRule?.name ?? "")」。已导出的文件不受影响。") }
        .onAppear(perform: reload)
    }

    private func ruleRow(_ rule: ExportRule) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in var r = rule; r.enabled = on; _ = ExportService.shared.saveRule(r); reload() })).labelsHidden().controlSize(.small).tint(Color.rbAccent)
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name.isEmpty ? "未命名" : rule.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.rbText)
                Text("\(rule.triggerDisplay) → \(rule.targetDisplay)").font(.caption).foregroundStyle(Color.rbText2)
                Text(statsText(for: rule.id)).font(.caption2.monospacedDigit()).foregroundStyle(Color.rbText3)
            }
            Spacer()
            if runningId == rule.id { ProgressView().controlSize(.small) }
            else { Button("立即执行") { runningId = rule.id; Task { await ExportService.shared.runFor(ruleId: rule.id); runningId = nil; reload() } }.controlSize(.small).disabled(!rule.enabled) }
            Button { editing = rule; showEditor = true } label: { Image(systemName: "pencil") }.buttonStyle(.quiet)
            Button(role: .destructive) { deletingRule = rule } label: { Image(systemName: "trash") }.buttonStyle(.quiet)
        }.padding(.vertical, 4)
    }
    private func reload() { rules = ExportService.shared.listRules() }
    private func statsText(for ruleId: Int64) -> String { let s = ExportService.shared.statsFor(ruleId: ruleId); return "已交付 \(s.delivered) 条" + (s.failed > 0 ? "，失败 \(s.failed)" : "") }
}

// MARK: - 平台配置区

private var platformConfigSection: some View {
    VStack(alignment: .leading, spacing: 12) {
        Text("导出平台配置").font(.system(size: 14, weight: .semibold))
        HStack { Text("Obsidian Vault").frame(width: 120, alignment: .leading); Text(ExportPlatformConfig.shared.obsidianDir.isEmpty ? "未设置目录" : ExportPlatformConfig.shared.obsidianDir).font(.caption).foregroundStyle(Color.rbText3).lineLimit(1).truncationMode(.middle); Spacer(); Button("选择…") { pickObsidianDir() }.controlSize(.small) }
        HStack { Text("Webhook URL").frame(width: 120, alignment: .leading); TextField("https://...", text: Binding(get: { ExportPlatformConfig.shared.webhookURL }, set: { ExportPlatformConfig.shared.webhookURL = $0 })).textFieldStyle(.roundedBorder).font(.caption) }
    }
}

private func pickObsidianDir() {
    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { ExportPlatformConfig.shared.obsidianDir = url.path }
}

// MARK: - 规则编辑表单

public struct ExportRuleEditor: View {
    @State var rule: ExportRule
    let onSave: (ExportRule, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sourceStore = SourceStore.shared

    // 筛选状态
    @State private var minScoreText = ""; @State private var keywordsText = ""; @State private var excludeKeywordsText = ""
    @State private var selectedSourceIds: Set<Int64> = []; @State private var selectedFolderIds: Set<Int64> = []
    @State private var selectedContentTypes: Set<String> = []; @State private var selectedPlatforms: Set<String> = []
    @State private var selectedLanguages: Set<String> = []; @State private var selectedFrontmatterFields: Set<String> = []
    @State private var fieldLabelOverrides: [String: String] = [:]

    // 导出配置
    @State private var dir = ""; @State private var subfolder = ""
    @State private var artifactType = "original"; @State private var missingPolicy = "wait"
    @State private var useTranslatedTitle = false; @State private var titleTemplate = "{title}-{id}"
    @State private var writePolicy = "overwrite"; @State private var historyScope = "new_only"
    @State private var scheduleInterval = "daily"
    @State private var publishedAfterEnabled = false; @State private var publishedBeforeEnabled = false
    @State private var publishedAfter = Date(); @State private var publishedBefore = Date()
    @State private var requireFulltext = false

    // 预览
    @State private var preview: ExportRulePreview?; @State private var showPreview = false; @State private var isPreviewing = false

    private let allFFields = ["title","source","author","url","score","ctype","published","summary","id","language","artifact"]
    private let fLabels: [String:String] = ["title":"标题","source":"来源","author":"作者","url":"原始链接","score":"评分","ctype":"内容类型","published":"发布日期","summary":"摘要","id":"ReadBoard ID","language":"语言","artifact":"文稿类型"]

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Form {
                    Section("基本信息") {
                        TextField("规则名称", text: $rule.name).font(.callout)
                        Picker("触发时机", selection: $rule.triggerOn) {
                            Text("内容入库后").tag("ingest"); Text("加工完成后").tag("ready")
                            Text("加星标时").tag("starred"); Text("定时批量导出").tag("scheduled")
                            Text("手动执行").tag("manual")
                        }.tint(Color.rbAccent)
                        if rule.triggerOn == "scheduled" {
                            Picker("执行频率", selection: $scheduleInterval) {
                                Text("每小时").tag("hourly"); Text("每天").tag("daily"); Text("每周").tag("weekly")
                            }.tint(Color.rbAccent)
                        }
                    }
                    Section("筛选条件（全部满足才导出）") {
                        selectionMenu(title: "订阅源", summary: selectedSourceIds.isEmpty ? "全部" : "已选 \(selectedSourceIds.count) 个", items: sourceStore.sources.map{($0.id,$0.name)}, selection: $selectedSourceIds)
                        selectionMenu(title: "文件夹", summary: selectedFolderIds.isEmpty ? "全部" : "已选 \(selectedFolderIds.count) 个", items: sourceStore.folders.map{($0.id,$0.name)}, selection: $selectedFolderIds)
                        stringSelectionMenu(title: "内容类型", summary: ctSummary, items: [("article","文章"),("podcast","播客"),("video","视频")], selection: $selectedContentTypes)
                        stringSelectionMenu(title: "来源平台", summary: plSummary, items: [("rss","RSS"),("podcast","播客"),("youtube","YouTube"),("wechat","公众号")], selection: $selectedPlatforms)
                        HStack { Text("最低评分").font(.callout).foregroundStyle(Color.rbText2); Spacer(); TextField("不限", text: $minScoreText).textFieldStyle(.roundedBorder).frame(width:80).multilineTextAlignment(.trailing) }
                        stringSelectionMenu(title: "内容语言", summary: langSummary, items: [("zh","中文"),("en","英文"),("ja","日文")], selection: $selectedLanguages)
                        Picker("已读状态", selection: $rule.criteria.readStatus) {
                            Text("全部").tag(nil as String?); Text("未读").tag("unread" as String?); Text("已读").tag("read" as String?)
                        }.tint(Color.rbAccent)
                        VStack(alignment: .leading, spacing:5) { Text("关键词").font(.callout).foregroundStyle(Color.rbText2); TextField("多个关键词用逗号分隔", text: $keywordsText).textFieldStyle(.roundedBorder) }
                        VStack(alignment: .leading, spacing:5) { Text("排除关键词").font(.callout).foregroundStyle(Color.rbText2); TextField("多个关键词用逗号分隔", text: $excludeKeywordsText).textFieldStyle(.roundedBorder) }
                        Toggle("限制起始日期", isOn: $publishedAfterEnabled).tint(Color.rbAccent)
                        if publishedAfterEnabled { DatePicker("不早于", selection: $publishedAfter, displayedComponents: .date) }
                        Toggle("限制结束日期", isOn: $publishedBeforeEnabled).tint(Color.rbAccent)
                        if publishedBeforeEnabled { DatePicker("不晚于", selection: $publishedBefore, displayedComponents: .date) }
                    }
                    Section("加工完成条件") {
                        Toggle("全文提取完成", isOn: $requireFulltext).tint(Color.rbAccent)
                        Toggle("评分完成", isOn: $rule.criteria.requireScored).tint(Color.rbAccent)
                        Toggle("摘要完成", isOn: $rule.criteria.requireSummary).tint(Color.rbAccent)
                        Toggle("译文完成", isOn: $rule.criteria.requireTranslated).tint(Color.rbAccent)
                        Toggle("转录完成", isOn: $rule.criteria.requireTranscribed).tint(Color.rbAccent)
                    }
                    Section("导出文稿") {
                        Toggle("标题使用中文译文（若存在）", isOn: $useTranslatedTitle).tint(Color.rbAccent)
                        Picker("文稿类型", selection: $artifactType) {
                            Text("原文").tag("original"); Text("译文").tag("translated")
                            Text("转录稿").tag("transcript"); Text("摘要").tag("summary")
                            Text("摘要＋原文").tag("summary_original"); Text("摘要＋译文").tag("summary_translated")
                            Text("摘要＋转录稿").tag("summary_transcript")
                        }.tint(Color.rbAccent)
                        Picker("内容缺失时", selection: $missingPolicy) {
                            Text("等待生成").tag("wait"); Text("回退到原文").tag("fallback_original")
                            Text("跳过内容").tag("skip")
                        }.tint(Color.rbAccent)
                    }
                    Section("目标与文件") {
                        HStack {
                            Text(dir.isEmpty ? "选择 Obsidian Vault 目录" : dir).font(.callout)
                                .foregroundStyle(dir.isEmpty ? Color.rbText3 : Color.rbText).lineLimit(1).truncationMode(.middle)
                            Spacer(); Button("选择…") { pickTargetDir() }.controlSize(.small)
                        }
                        TextField("子目录模板", text: $subfolder, prompt: Text("{source}/{year}/{month}"))
                        TextField("文件名模板", text: $titleTemplate, prompt: Text("{date} {title}-{id}"))
                        Text("可用占位符：{title} {date} {id} {source} {ctype} {score} {year} {month}").font(.caption2).foregroundStyle(Color.rbText3)
                        Picker("已有文件", selection: $writePolicy) {
                            Text("内容变化时覆盖").tag("overwrite"); Text("跳过").tag("skip"); Text("生成新版本").tag("versioned")
                        }.tint(Color.rbAccent)
                        Picker("历史范围", selection: $historyScope) {
                            Text("仅规则创建后的新内容").tag("new_only"); Text("回填所有历史匹配内容").tag("all")
                        }.tint(Color.rbAccent)
                    }
                    Section("Frontmatter 字段") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(allFFields, id: \.self) { field in
                                HStack(spacing: 8) {
                                    Toggle(fLabels[field] ?? field, isOn: fBind(field)).tint(Color.rbAccent).font(.caption).frame(width: 130, alignment: .leading)
                                    if selectedFrontmatterFields.contains(field) {
                                        TextField("字段名", text: lBind(field)).textFieldStyle(.roundedBorder).font(.caption).frame(width: 100)
                                    }
                                }
                            }
                        }
                    }
                    Section("附件") {
                        LabeledContent("图片与附件") { Text("保留远程链接").foregroundStyle(Color.rbText2) }
                        Text("第一版不会把图片、音频或视频复制进 Vault。").font(.caption2).foregroundStyle(Color.rbText3)
                    }
                }.formStyle(.grouped)
            }
            Hairline()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.quiet)
                Spacer()
                Button { previewRule() } label: { if isPreviewing { ProgressView().controlSize(.small) } else { Text("预览") } }
                    .disabled(isPreviewing || rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("保存") { onSave(draftRule(), rule.id > 0) }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.primaryCapsule).disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 580, idealHeight: 780)
        .navigationTitle(rule.id == 0 ? "新建导出规则" : "编辑导出规则")
        .onAppear { load() }
        .sheet(isPresented: $showPreview) { if let preview { ExportRulePreviewView(preview: preview) } }
    }

    // MARK: helpers
    private func draftRule() -> ExportRule {
        var r = rule; r.name = r.name.trimmingCharacters(in: .whitespaces)
        r.criteria.minScore = Int(minScoreText).flatMap{$0>0 ? $0:nil}
        r.criteria.sourceIds = selectedSourceIds.isEmpty ? nil : Array(selectedSourceIds).sorted()
        r.criteria.folderIds = selectedFolderIds.isEmpty ? nil : Array(selectedFolderIds).sorted()
        r.criteria.contentTypes = selectedContentTypes.isEmpty ? nil : Array(selectedContentTypes).sorted()
        r.criteria.platforms = selectedPlatforms.isEmpty ? nil : Array(selectedPlatforms).sorted()
        r.criteria.languages = selectedLanguages.isEmpty ? nil : Array(selectedLanguages).sorted()
        let kw = keywordsText.components(separatedBy: CharacterSet(charactersIn: ",，\n")).map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}
        r.criteria.keywords = kw.isEmpty ? nil : kw
        let ek = excludeKeywordsText.components(separatedBy: CharacterSet(charactersIn: ",，\n")).map{$0.trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty}
        r.criteria.excludedKeywords = ek.isEmpty ? nil : ek
        r.criteria.publishedAfter = publishedAfterEnabled ? fmtDay(publishedAfter) : nil
        r.criteria.publishedBefore = publishedBeforeEnabled ? fmtDay(publishedBefore)+" 23:59:59" : nil
        r.target = "obsidian"; r.targetConfig["dir"] = ExportPlatformConfig.shared.obsidianDir.isEmpty ? dir : ExportPlatformConfig.shared.obsidianDir
        r.subfolderTemplate = subfolder.trimmingCharacters(in:.whitespaces)
        r.targetConfig["subfolder"] = r.subfolderTemplate; r.targetConfig["view"] = artifactType
        r.targetConfig["missing_policy"] = missingPolicy; r.targetConfig["write_policy"] = writePolicy
        r.targetConfig["history_scope"] = historyScope; r.targetConfig["schedule_interval"] = scheduleInterval
        r.artifact = artifactType; r.missingPolicy = missingPolicy; r.writePolicy = writePolicy
        r.historyScope = historyScope; r.overwrite = writePolicy == "overwrite"
        r.titleTemplate = titleTemplate.trimmingCharacters(in:.whitespaces).isEmpty ? "{title}-{id}" : titleTemplate.trimmingCharacters(in:.whitespaces)
        r.frontmatterFields = selectedFrontmatterFields.isEmpty ? nil : Array(selectedFrontmatterFields).sorted()
        r.useTranslatedTitle = useTranslatedTitle
        r.frontmatterLabels = fieldLabelOverrides.isEmpty ? nil : fieldLabelOverrides
        r.targetConfig["use_translated_title"] = r.useTranslatedTitle
        if let l = r.frontmatterLabels { r.targetConfig["frontmatter_labels"] = l }
        return r
    }

    private func load() {
        minScoreText = rule.criteria.minScore.map(String.init) ?? ""
        keywordsText = (rule.criteria.keywords ?? []).joined(separator: "，")
        excludeKeywordsText = (rule.criteria.excludedKeywords ?? []).joined(separator: "，")
        dir = rule.targetConfig["dir"] as? String ?? ExportPlatformConfig.shared.obsidianDir
        subfolder = rule.effectiveSubfolderTemplate; artifactType = rule.effectiveArtifact
        missingPolicy = rule.missingPolicy; writePolicy = rule.effectiveWritePolicy; historyScope = rule.historyScope
        scheduleInterval = (rule.targetConfig["schedule_interval"] as? String) ?? "daily"
        useTranslatedTitle = rule.useTranslatedTitle; fieldLabelOverrides = rule.frontmatterLabels ?? [:]
        titleTemplate = rule.titleTemplate
        selectedSourceIds = Set(rule.criteria.sourceIds ?? []); selectedFolderIds = Set(rule.criteria.folderIds ?? [])
        selectedContentTypes = Set(rule.criteria.contentTypes ?? []); selectedPlatforms = Set(rule.criteria.platforms ?? [])
        selectedLanguages = Set(rule.criteria.languages ?? [])
        selectedFrontmatterFields = Set(rule.frontmatterFields ?? ["title","source","author","url","score","published","id"])
        if let v = rule.criteria.publishedAfter, let d = parseDay(v) { publishedAfterEnabled = true; publishedAfter = d }
        if let v = rule.criteria.publishedBefore, let d = parseDay(v) { publishedBeforeEnabled = true; publishedBefore = d }
        if sourceStore.sources.isEmpty { sourceStore.reload() }
    }

    private func previewRule() { let d = draftRule(); isPreviewing = true; Task { let r = await Task.detached(priority:.userInitiated){ ExportService.shared.preview(rule:d) }.value; preview = r; isPreviewing = false; showPreview = true } }

    private func pickTargetDir() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { dir = url.path }
    }

    private func fBind(_ f: String) -> Binding<Bool> { Binding(get:{selectedFrontmatterFields.contains(f)}, set:{if $0{selectedFrontmatterFields.insert(f)}else{selectedFrontmatterFields.remove(f)}}) }
    private func lBind(_ f: String) -> Binding<String> { Binding(get:{fieldLabelOverrides[f] ?? ""}, set:{v in let t=v.trimmingCharacters(in:.whitespaces); if t.isEmpty{fieldLabelOverrides.removeValue(forKey:f)}else{fieldLabelOverrides[f]=t}}) }

    private func selectionMenu(title: String, summary: String, items: [(Int64,String)], selection: Binding<Set<Int64>>) -> some View {
        HStack { Text(title).font(.callout).foregroundStyle(Color.rbText2); Spacer(); Menu(summary) { Button("全部"){selection.wrappedValue.removeAll()}; Divider(); ForEach(items,id:\.0){item in Button{if selection.wrappedValue.contains(item.0){selection.wrappedValue.remove(item.0)}else{selection.wrappedValue.insert(item.0)}} label:{Label(item.1, systemImage:selection.wrappedValue.contains(item.0) ? "checkmark":"circle")}} }.menuStyle(.borderlessButton).fixedSize() }
    }
    private func stringSelectionMenu(title: String, summary: String, items: [(String,String)], selection: Binding<Set<String>>) -> some View {
        HStack { Text(title).font(.callout).foregroundStyle(Color.rbText2); Spacer(); Menu(summary) { Button("全部"){selection.wrappedValue.removeAll()}; Divider(); ForEach(items,id:\.0){item in Button{if selection.wrappedValue.contains(item.0){selection.wrappedValue.remove(item.0)}else{selection.wrappedValue.insert(item.0)}} label:{Label(item.1, systemImage:selection.wrappedValue.contains(item.0) ? "checkmark":"circle")}} }.menuStyle(.borderlessButton).fixedSize() }
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
    let preview: ExportRulePreview; @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading, spacing:14) {
            HStack{Text("导出预览").font(.headline);Spacer();Button("完成"){dismiss()}.keyboardShortcut(.defaultAction)}
            Text("共匹配 \(preview.matchingCount) 条，预览不写文件。").foregroundStyle(Color.rbText2)
            if preview.samples.isEmpty { ContentUnavailableView("没有匹配内容", systemImage: "doc.text.magnifyingglass") }
            else { List(preview.samples, id:\.contentId){s in VStack(alignment:.leading, spacing:5){Text(s.title).font(.system(size:13,weight:.semibold)); if let i=s.issue{Text(i).font(.caption).foregroundStyle(Color.rbScoreLow)} else if let d=s.destination{Text(d).font(.caption.monospaced()).foregroundStyle(Color.rbText3).lineLimit(2).truncationMode(.middle)}; if let m=s.markdown{Text(String(m.prefix(400))).font(.caption).foregroundStyle(Color.rbText2).lineLimit(6)}}.padding(.vertical,4)} }
        }.padding(20).frame(width:620,height:480)
    }
}
