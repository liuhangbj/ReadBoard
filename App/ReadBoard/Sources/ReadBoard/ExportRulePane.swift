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
            HStack {
                Text("导出规则")
                    .font(.title3.bold())
                Spacer()
                Button {
                    editing = ExportRule(
                        id: 0, name: "", enabled: true,
                        criteria: ExportRule.Criteria(),
                        triggerOn: "manual", target: "mddir",
                        targetConfig: [:], lastRunAt: nil)
                    showEditor = true
                } label: { Label("新建规则", systemImage: "plus") }
                .controlSize(.small)
            }
            .padding()

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

                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.name.isEmpty ? "未命名" : rule.name)
                                    .font(.headline)
                                Text("\(rule.triggerDisplay) → \(rule.targetDisplay)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(statsText(for: rule.id))
                                    .font(.caption2).foregroundStyle(.tertiary)
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
        .navigationTitle("导出规则")
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
                    }
                    Toggle("只导已翻译的", isOn: $rule.criteria.requireTranslated)
                    Toggle("只导已转录的（播客/视频）", isOn: $rule.criteria.requireTranscribed)
                    Toggle("只导有摘要的", isOn: $rule.criteria.requireSummary)
                    Toggle("只导星标内容", isOn: $rule.criteria.starredOnly)
                }

                Section("导出目标") {
                    Picker("目标类型", selection: $rule.target) {
                        Text("Markdown 目录").tag("mddir")
                        Text("Obsidian 仓库").tag("obsidian")
                        Text("Webhook").tag("webhook")
                    }
                    if rule.target == "obsidian" || rule.target == "mddir" {
                        // 目录用系统文件夹选择器（不手填路径）
                        HStack {
                            Text(dir.isEmpty
                                 ? (rule.target == "obsidian" ? "选择 Obsidian 仓库目录" : "选择输出目录")
                                 : dir)
                                .font(.callout)
                                .foregroundStyle(dir.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("选择…") { pickTargetDir() }
                                .controlSize(.small)
                        }
                        Toggle("按来源建子目录", isOn: $bySource)
                            .onChange(of: bySource) { _, v in rule.targetConfig["subdir_by_source"] = v }
                    } else {
                        TextField("Webhook URL（POST JSON）", text: $webhookURL)
                            .onChange(of: webhookURL) { _, v in rule.targetConfig["url"] = v }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    onSave(rule)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(rule.name.isEmpty || !targetValid)
            }
            .padding()
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
