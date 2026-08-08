import SwiftUI
import UniformTypeIdentifiers
import ReadBoardContract

// MARK: - 内容管线统一标签（关键词前缀「AI」——翻译/摘要/转录与 AI 评分对齐，全 App 一处定义）
/// (key, label) 顺序固定：AI 评分 / AI 翻译 / AI 摘要 / AI 转录
private let PIPELINE_DEFS: [(key: String, label: String)] = [
    ("auto_score", "AI 评分"),
    ("auto_translate", "AI 翻译"),
    ("auto_summarize", "AI 摘要"),
    ("auto_transcribe", "AI 转录"),
]

// MARK: - 订阅源管理界面

public struct SourcesView: View {
    @StateObject private var catalog: SourceCatalogStore
    @EnvironmentObject private var appTab: AppTab
    /// 内嵌于设置「多类型源」页时隐藏站点级导航元素（返回阅读 / 大页标题）
    var embeddedInSettings = false
    private let sourceManagement: any SourceManagementGateway
    private let sourceOnboarding: any SourceOnboardingGateway
    private let sourceCatalogGateway: any SourceCatalogGateway
    @State private var showAddSheet = false
    @State private var showAddFolder = false
    @State private var newFolderName = ""
    @State private var opmlMessage = ""
    @State private var showImportSummary = false
    @State private var importPlan: OPMLImportPlan? = nil

    public init(
        services: ReadBoardServices = .live,
        embeddedInSettings: Bool = false
    ) {
        self.sourceManagement = services.sourceManagement
        self.sourceOnboarding = services.sourceOnboarding
        self.sourceCatalogGateway = services.sourceCatalog
        self.embeddedInSettings = embeddedInSettings
        _catalog = StateObject(
            wrappedValue: SourceCatalogStore(gateway: services.sourceCatalog))
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部工具条（统一到 RB token：quiet 按钮、text 三级、墨蓝 tint）
            HStack(spacing: 10) {
                if !embeddedInSettings {
                    // 返回阅读（左栏底部导航切过来的入口）——内嵌设置页时不显示
                    Button { appTab.selection = 0 } label: {
                        Label("阅读", systemImage: "chevron.left")
                    }
                    .buttonStyle(.quiet)
                    .help("返回阅读")
                    Text("订阅源")
                        .font(.system(size: RB.F.pageTitle, weight: .semibold))
                        .foregroundStyle(Color.rbText)
                } else {
                    Text("订阅源管理")
                        .font(.system(size: RB.F.pageTitle, weight: .semibold))
                        .foregroundStyle(Color.rbText)
                }
                Text("\(catalog.sources.count)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.rbText3)
                Spacer()
                Button { Task { _ = try? await sourceManagement.syncAll() } } label: {
                    Label("全部刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.quiet)
                .disabled(catalog.isSyncing)
                Button { showAddFolder = true } label: {
                    Label("文件夹", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.quiet)
                // OPML 导入/导出（NSOpenPanel 挂 mainWindow——fileImporter 在 SourcesView
                // 被 RootView switch 切换时不弹，探针实锤按钮触发但面板不出）
                Button { importOPML() } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.quiet)
                Button { exportOPML() } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.quiet)
                VHairline(height: 14)
                Button { showAddSheet = true } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.primaryCapsule)
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // OPML 导入导出属于本页操作；订阅更新进度已统一移到数据看板。
            if !opmlMessage.isEmpty {
                StatusBanner {
                    Image(systemName: "doc.badge.arrow.up")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.rbAccent)
                    Text(opmlMessage)
                        .font(.caption)
                        .foregroundStyle(Color.rbAccent)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Hairline()

            // 源列表（文件夹 → 源 两级分组；源相对文件夹缩进 20pt）
            List {
                // 各文件夹分组
                ForEach(catalog.folders) { folder in
                    Section {
                        ForEach(sources(in: folder.id)) { src in
                            SourceRow(
                                src: src,
                                folders: catalog.folders,
                                sourceManagement: sourceManagement)
                                .padding(.leading, 20)   // 源相对文件夹缩进
                        }
                    } header: {
                        FolderHeader(
                            folder: folder,
                            sources: catalog.sources(inFolder: folder.id),
                            sourceManagement: sourceManagement)
                    }
                }
                // 未分组
                let ungrouped = sources(in: nil)
                if !ungrouped.isEmpty {
                    Section(catalog.folders.isEmpty ? "全部源" : "未分组") {
                        ForEach(ungrouped) { src in
                            SourceRow(
                                src: src,
                                folders: catalog.folders,
                                sourceManagement: sourceManagement)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .task { await catalog.monitor() }
        .sheet(isPresented: $showAddSheet) {
            AddSourceSheet(
                onboarding: sourceOnboarding,
                sourceCatalog: sourceCatalogGateway,
                sourceManagement: sourceManagement)
                .onDisappear { Task { await catalog.refresh() } }
        }
        .sheet(isPresented: $showImportSummary) {
            if let plan = importPlan {
                OPMLImportSummary(
                    plan: plan,
                    onboarding: sourceOnboarding,
                    sourceCatalog: sourceCatalogGateway)
                    .onDisappear { Task { await catalog.refresh() } }
            }
        }
        .alert("新建文件夹", isPresented: $showAddFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") {
                if !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty {
                    let name = newFolderName.trimmingCharacters(in: .whitespaces)
                    Task { _ = try? await sourceManagement.createFolder(name: name) }
                }
                newFolderName = ""
            }
        }
    }

    /// 某文件夹下的源(nil = 未分组)
    private func sources(in folderId: Int64?) -> [SourceCatalogItem] {
        catalog.sources.filter { $0.folderId == folderId }
    }

    // MARK: OPML 导入/导出（NSOpenPanel 挂 mainWindow）

    /// 导入 OPML：NSOpenPanel 挂到 mainWindow（fileImporter 在 SourcesView 被
    /// RootView switch 切换时不弹，探针实锤按钮触发但面板不出）
    private func importOPML() {
        let panel = NSOpenPanel()
        // 不过滤文件类型——opml 是未注册动态 UTI，用 .xml 过滤会把它排除（灰掉选不了）。
        // 让用户自己选，反正知道要选 .opml/.xml。
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要导入的 OPML 文件（.opml 或 .xml）"
        // 激活 App + 挂 mainWindow——确保面板弹到前台可见
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.mainWindow else {
            opmlMessage = "无法打开文件选择器（无活动窗口）"
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            // 沙箱下需 startAccessingSecurityScopedResource 才能读用户选的文件
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let xml = try? String(contentsOf: url, encoding: .utf8) else {
                DispatchQueue.main.async { opmlMessage = "读取文件失败：\(url.lastPathComponent)" }
                return
            }
            // 解析放后台线程（XML 解析 + 库去重查询），不写库；解析结果回主线程弹汇总页。
            DispatchQueue.main.async { opmlMessage = "解析中…" }
            DispatchQueue.global(qos: .userInitiated).async {
                let plan = OPMLService.shared.parseOPML(xml)
                DispatchQueue.main.async {
                    opmlMessage = ""
                    if let err = plan.parseError {
                        opmlMessage = "导入失败：\(err)"
                        return
                    }
                    if plan.outlines.isEmpty {
                        opmlMessage = "未从文件中解析到任何订阅源"
                        return
                    }
                    showImportSummary = true
                    importPlan = plan
                }
            }
        }
    }

    /// 导出 OPML：NSSavePanel 挂 mainWindow
    private func exportOPML() {
        let panel = NSSavePanel()
        // 不过滤——NSSavePanel 的 allowedContentTypes 会限制保存类型，去掉让用户自由命名
        panel.nameFieldStringValue = "readboard-subscriptions.opml"
        panel.message = "导出订阅为 OPML"
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.mainWindow else {
            opmlMessage = "无法打开保存面板（无活动窗口）"
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                let xml = await sourceOnboarding.exportOPML()
                do {
                    try xml.write(to: url, atomically: true, encoding: .utf8)
                    opmlMessage = "已导出 \(catalog.sources.count) 源到 \(url.lastPathComponent)"
                } catch {
                    opmlMessage = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: 文件夹分组头（含文件夹级管线总开关）

public struct FolderHeader: View {
    let folder: SourceFolderItem
    let sources: [SourceCatalogItem]
    let sourceManagement: any SourceManagementGateway
    @State private var showDeleteConfirm = false
    /// 开总开关后弹"处理历史数据"选项
    @State private var pendingBackfillKey: String? = nil

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.rbText3)
            Text(folder.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.rbText)
                .tracking(0.3)
            Spacer()
            // 文件夹级开关（状态显示组内一致性：全开=on，其余=off；切换=批量设全部源）
            ForEach(PIPELINE_DEFS, id: \.key) { def in
                folderToggle(def.label, key: def.key)
            }
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.rbText3)
            }
            .buttonStyle(.quiet)
        }
        .textCase(nil)
        .alert("删除文件夹「\(folder.name)」？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task {
                    _ = try? await sourceManagement.remove(
                        scope: SourceScope(kind: .folder, id: folder.id))
                }
            }
        } message: {
            Text("文件夹内的源不会被删除，只是移出分组（folder_id 置空）。")
        }
        .alert("处理历史数据？", isPresented: Binding(
            get: { pendingBackfillKey != nil },
            set: { if !$0 { pendingBackfillKey = nil } }
        )) {
            Button("处理所有历史内容") {
                if let rawKey = pendingBackfillKey,
                   let key = SourcePolicyKey(rawValue: rawKey) {
                    Task {
                        _ = try? await sourceManagement.backfillProcessing(
                            scope: SourceScope(kind: .folder, id: folder.id),
                            key: key)
                    }
                }
                pendingBackfillKey = nil
            }
            Button("只处理新增", role: .cancel) { pendingBackfillKey = nil }
        } message: {
            Text("「\(folder.name)」整组的\(pendingBackfillLabel)已开启。\n\n• 处理历史：组内所有源的存量内容补做相应处理（耗时很长，按量计费）\n• 只处理新增：历史不动，新抓的自动进入内容处理引擎")
        }
    }

    /// 文件夹内所有源某管线键是否全一致；一致返回该值，不一致返回 nil
    private func folderUniformPolicy(_ key: String) -> Bool? {
        let vals = sources.map { src -> Bool in
            let p = src.policy
            switch key {
            case "auto_score": return p.autoScore
            case "auto_translate": return p.autoTranslate
            case "auto_summarize": return p.autoSummarize
            case "auto_transcribe": return p.autoTranscribe
            default: return false
            }
        }
        guard let first = vals.first else { return nil }
        return vals.allSatisfy { $0 == first } ? first : nil
    }

    private func folderToggle(_ label: String, key: String) -> some View {
        let uniform = folderUniformPolicy(key)
        let inconsistent = uniform == nil
        return Toggle(label, isOn: Binding(
            get: { uniform ?? false },
            set: { newValue in
                if let policyKey = SourcePolicyKey(rawValue: key) {
                    Task {
                        try? await sourceManagement.setPolicy(
                            scope: SourceScope(kind: .folder, id: folder.id),
                            key: policyKey,
                            enabled: newValue)
                    }
                }
                if newValue { pendingBackfillKey = key }
            }
        ))
        .toggleStyle(.checkbox)
        .font(.caption)
        .controlSize(.small)
        .tint(Color.rbAccent)
        // 组内不一致时标灰提示（点击仍会批量统一成全开/全关）
        .foregroundStyle(inconsistent ? Color.rbText3 : Color.rbText)
        .help(inconsistent ? "组内源设置不一致（点击统一）" : "")
    }

    private var pendingBackfillLabel: String {
        guard let key = pendingBackfillKey else { return "" }
        return PIPELINE_DEFS.first(where: { $0.key == key })?.label ?? key
    }
}

// MARK: 单行

public struct SourceRow: View {
    let src: SourceCatalogItem
    let folders: [SourceFolderItem]
    let sourceManagement: any SourceManagementGateway
    @State private var showDeleteConfirm = false
    /// 开管线后弹"处理历史数据"选项（key = 刚打开的管线）
    @State private var pendingBackfillKey: String? = nil

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // ── 左：图标 + 名称/地址（固定列宽，各行对齐）──
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.rbText2)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(src.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.rbText)
                    .lineLimit(1)
                Text(src.identifier)
                    .font(.caption)
                    .foregroundStyle(Color.rbText3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 280, alignment: .leading)

            // ── 中：每个选项固定列宽（条件项用占位保持对齐）──
            // 全文模式（固定列；非 rss 占位保持对齐）——加宽到 88 容纳 defuddle
            Group {
                if !src.availableFetchModes.isEmpty {
                    fetchModeMenu
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: 88, alignment: .leading)

            // 更新频率（固定列）——加宽到 88 容纳「15 分钟」
            intervalMenu
                .frame(width: 88, alignment: .leading)

            // 最多保留条数（固定列）——播客源限制保留量
            maxKeepMenu
                .frame(width: 72, alignment: .leading)

            // 上次抓取（固定列；无值占位）
            Group {
                if let t = src.lastFetchedAt {
                    Text("上次 \(String(t.prefix(10)))")
                        .font(.caption)
                        .foregroundStyle(Color.rbText3)
                        .lineLimit(1)
                } else if let err = src.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Color.rbScoreLow)
                        .lineLimit(1)
                } else {
                    Text(" ")
                        .font(.caption)
                }
            }
            .frame(width: 96, alignment: .leading)

            // 管线开关（每项固定列宽，对齐）——on 显示生效状态（文件夹覆盖后的）
            pipelineToggle("AI 评分", key: "auto_score", on: effectivePolicy.autoScore, inherited: fp.autoScore)
                .frame(width: 52, alignment: .leading)
            pipelineToggle("翻译", key: "auto_translate", on: effectivePolicy.autoTranslate, inherited: fp.autoTranslate)
                .frame(width: 52, alignment: .leading)
            pipelineToggle("摘要", key: "auto_summarize", on: effectivePolicy.autoSummarize, inherited: fp.autoSummarize)
                .frame(width: 52, alignment: .leading)
            // 转录（固定列；非媒体占位保持对齐）
            Group {
                if src.transcribable {
                    pipelineToggle("转录", key: "auto_transcribe", on: effectivePolicy.autoTranscribe, inherited: fp.autoTranscribe)
                }
            }
            .frame(width: 52, alignment: .leading)

            Spacer(minLength: 8)

            // ── 右：启用 + 指派文件夹 + 删除（固定操作区，各行对齐）──
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { src.enabled },
                    set: { enabled in
                        Task {
                            try? await sourceManagement.setEnabled(
                                sourceID: src.id, enabled: enabled)
                        }
                    }
                ))
                .labelsHidden()
                .tint(Color.rbAccent)
                folderAssignMenu
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.rbText3)
                        .frame(width: 20)
                }
                .buttonStyle(.quiet)
                .alert("删除订阅源？", isPresented: $showDeleteConfirm) {
                    Button("取消", role: .cancel) {}
                    Button("永久删除", role: .destructive) {
                        Task {
                            _ = try? await sourceManagement.remove(
                                scope: SourceScope(kind: .source, id: src.id))
                        }
                    }
                } message: {
                    Text("将永久删除「\(src.name)」及其全部文章、AI 处理结果和应用内导出记录。此操作无法撤销；已经写入 Obsidian 的文件不会删除。")
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// 全文模式选择菜单——自动检测 / 五层级 / 重新检测
    private var fetchModeMenu: some View {
        Menu {
            Button {
                Task {
                    try? await sourceManagement.setFetchMode(
                        scope: SourceScope(kind: .source, id: src.id),
                        mode: .automatic)
                }
            } label: {
                if src.fetchModeAuto {
                    HStack { Image(systemName: "checkmark"); Text("自动检测") }
                } else {
                    HStack { Image(systemName: "arrow.triangle.2.circlepath"); Text("自动检测（当前: \(fulltextDisplayName())）") }
                }
            }
            Divider()
            ForEach(fetchModesForSource, id: \.rawValue) { fm in
                Button {
                    guard let mode = SourceFetchMode(rawValue: fm.rawValue) else { return }
                    Task {
                        try? await sourceManagement.setFetchMode(
                            scope: SourceScope(kind: .source, id: src.id), mode: mode)
                    }
                } label: {
                    if !src.fetchModeAuto && src.localFetchMode == fm {
                        HStack { Image(systemName: "checkmark"); Text(fulltextDisplayName(mode: fm)) }
                    } else {
                        Text(fulltextDisplayName(mode: fm))
                    }
                }
            }
            Divider()
            Button("重新检测") {
                Task {
                    try? await sourceManagement.redetectFetchMode(
                        scope: SourceScope(kind: .source, id: src.id))
                }
            }
        } label: {
            Text(src.fetchModeAuto ? "自动（\(fulltextDisplayName())）" : fulltextDisplayName())
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(fetchModeColor.opacity(0.10))
                .foregroundStyle(fetchModeColor)
                .clipShape(RoundedRectangle(cornerRadius: RB.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: RB.Radius.sm)
                        .strokeBorder(fetchModeColor.opacity(0.22), lineWidth: RB.Line.hair)
                )
        }
        .menuStyle(.borderlessButton)
        .help("全文提取方式（点击可修改）")
    }

    /// 抓取频率选择菜单
    private var intervalMenu: some View {
        Menu {
            ForEach([5, 15, 30, 60, 360, 720], id: \.self) { m in
                Button {
                    Task {
                        try? await sourceManagement.setFetchInterval(
                            scope: SourceScope(kind: .source, id: src.id), minutes: m)
                    }
                } label: {
                    let label = m < 60 ? "\(m) 分钟" : "\(m/60) 小时"
                    if src.fetchIntervalMin == m { Label(label, systemImage: "checkmark") }
                    else { Text(label) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                Text(intervalLabel(src.fetchIntervalMin))
            }
            .font(.caption)
            .foregroundStyle(Color.rbText3)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.rbSurface)
            .clipShape(RoundedRectangle(cornerRadius: RB.Radius.sm))
        }
        .menuStyle(.borderlessButton)
        .help("自动抓取间隔（点击可修改）")
    }

    /// 最多保留条数菜单（播客源几百上千条，限制保留量）
    private var maxKeepMenu: some View {
        Menu {
            ForEach([0, 50, 100, 200, 500], id: \.self) { n in
                Button {
                    Task {
                        try? await sourceManagement.setMaximumRetainedContent(
                            sourceID: src.id, count: n)
                    }
                } label: {
                    let label = n == 0 ? "不限制" : "\(n) 条"
                    if src.maxKeep == n { Label(label, systemImage: "checkmark") }
                    else { Text(label) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "tray.full")
                    .font(.system(size: 9))
                Text(src.maxKeep == 0 ? "不限制" : "\(src.maxKeep) 条")
            }
            .font(.caption)
            .foregroundStyle(Color.rbText3)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.rbSurface)
            .clipShape(RoundedRectangle(cornerRadius: RB.Radius.sm))
        }
        .menuStyle(.borderlessButton)
        .help("最多保留条数（超出后最旧内容自动移出列表）")
    }

    /// 指派到文件夹菜单
    private var folderAssignMenu: some View {
        Menu {
            Button("未分组") {
                Task { try? await sourceManagement.assignSource(sourceID: src.id, folderID: nil) }
            }
            Divider()
            ForEach(folders) { f in
                Button {
                    Task { try? await sourceManagement.assignSource(sourceID: src.id, folderID: f.id) }
                } label: {
                    if src.folderId == f.id { Label(f.name, systemImage: "checkmark") }
                    else { Text(f.name) }
                }
            }
        } label: {
            Image(systemName: "folder")
                .foregroundStyle(Color.rbText3)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
    }

    /// 生效策略 = 源自己的设置（管线纯按源处理，文件夹仅作批量设置入口，不影响生效）
    private var effectivePolicy: SourcePolicySnapshot { src.policy }

    /// 已废弃：文件夹不再强制覆盖管线，无「已继承」概念
    private var fp: SourcePolicySnapshot { SourcePolicySnapshot() }

    /// 已废弃：文件夹不再覆盖源级开关
    private func isOverridden(key: String) -> Bool { false }

    /// 单个管线开关（AI 评分/翻译/转录）。inherited=true 表示文件夹层已开，标蓝提示。
    /// 打开时弹选项：处理所有历史数据 / 只处理新增。
    private func pipelineToggle(_ label: String, key: String, on: Bool, inherited: Bool) -> some View {
        Toggle(label, isOn: Binding(
            get: { on },
            set: { newValue in
                if let policyKey = SourcePolicyKey(rawValue: key) {
                    Task {
                        try? await sourceManagement.setPolicy(
                            scope: SourceScope(kind: .source, id: src.id),
                            key: policyKey,
                            enabled: newValue)
                    }
                }
                // 关→开 才弹（关掉不需要回填）； inherited 已生效的也不弹（本就有效）
                if newValue && !inherited { pendingBackfillKey = key }
            }
        ))
        .toggleStyle(.checkbox)
        .font(.caption)
        .controlSize(.small)
        .tint(Color.rbAccent)
        .foregroundStyle(inherited ? Color.rbAccent : Color.rbText)
        .help(inherited ? "文件夹层已开启此项，对本源生效" : "")
        .alert("处理历史数据？", isPresented: Binding(
            get: { pendingBackfillKey != nil },
            set: { if !$0 { pendingBackfillKey = nil } }
        )) {
            Button("处理所有历史内容") {
                if let rawKey = pendingBackfillKey,
                   let key = SourcePolicyKey(rawValue: rawKey) {
                    Task {
                        _ = try? await sourceManagement.backfillProcessing(
                            scope: SourceScope(kind: .source, id: src.id), key: key)
                    }
                }
                pendingBackfillKey = nil
            }
            Button("只处理新增", role: .cancel) {
                // setPolicy 开启时已经把现有条目固定为 0；新入库条目继承源配置 1。
                pendingBackfillKey = nil
            }
        } message: {
            Text("「\(src.name)」的\(label)已开启。\n\n• 处理历史：存量内容补做相应处理（耗时较长，按量计费）\n• 只处理新增：历史不动，新抓的自动进入内容处理引擎")
        }
    }

    private var fetchModesForSource: [FetchMode] {
        src.localAvailableFetchModes
    }

    private func fulltextDisplayName(mode: FetchMode? = nil) -> String {
        src.localFetchModeDisplayName(mode)
    }

    /// 源类型图标（SF Symbol，替代 emoji——纸墨系不用彩色符号）
    private var icon: String {
        switch src.stype {
        case "podcast": return "mic"
        case "youtube": return "play.rectangle"
        case "bilibili": return "play.tv"
        case "wechat": return "bubble.left.and.bubble.right"
        default: return "newspaper"
        }
    }

    private var fetchModeColor: Color {
        switch src.localFetchMode {
        case .feedFull: return .rbScoreHigh
        case .defuddle: return .rbAccent
        case .externalFulltext: return .rbScoreHigh
        case .youtubeSubtitle, .bilibiliSubtitle: return .rbAccent
        case .summary: return .rbScoreNone
        }
    }

    private func intervalLabel(_ m: Int) -> String {
        m < 60 ? "\(m)分钟" : "\(m/60)小时"
    }
}

// MARK: 添加源

public struct AddSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog: SourceCatalogStore
    private let onboarding: any SourceOnboardingGateway
    private let sourceManagement: any SourceManagementGateway

    // 类型下拉的合法值与展示
    @State private var sourceTypes: [SourceTypeDescriptor] = []

    @State private var name = ""
    @State private var identifier = ""          // 唯一的地址栏
    @State private var stype = "article"        // 检测后自动填入，下拉可改
    @State private var selectedFolderId: Int64? = nil   // 检测后可选文件夹，默认未分组
    @State private var autoScore = false
    @State private var autoTranslate = false
    @State private var autoSummarize = false
    @State private var autoTranscribe = false
    @State private var refreshAfterAdd: Bool = true      // 添加后立即抓取首批（可勾选关闭）
    @State private var testing = false
    @State private var testResult = ""
    @State private var resolvedFeedURL: String? = nil   // 检测成功后定稿的 feed URL（自动发现可能改写）
    @State private var resolvedSourceType: String? = nil // 外部连接器识别出的 stype
    @State private var testedOK = false                  // 检测通过才能添加
    @State private var detectedMode: SourceFetchMode = .summary
    @State private var historyScope: SourceHistoryScope = .recent30Days

    public init(
        onboarding: any SourceOnboardingGateway,
        sourceCatalog: any SourceCatalogGateway,
        sourceManagement: any SourceManagementGateway
    ) {
        self.onboarding = onboarding
        self.sourceManagement = sourceManagement
        _catalog = StateObject(
            wrappedValue: SourceCatalogStore(gateway: sourceCatalog))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加订阅源")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.rbText)

            // 唯一的地址栏
            VStack(alignment: .leading, spacing: 8) {
                Text("订阅地址")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.rbText3)
                    .tracking(RB.Track.section)
                TextField("Feed 地址 / 网站主页 / YouTube 频道 URL", text: $identifier)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: identifier) { _, _ in
                        // 地址变了必须重新检测
                        testedOK = false
                        resolvedFeedURL = nil
                        resolvedSourceType = nil
                        testResult = ""
                    }
            }

            // 检测通过后才解锁：名称（文本框，可改）+ 类型（下拉，可改）
            VStack(alignment: .leading, spacing: 8) {
                Text("名称")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.rbText3)
                    .tracking(RB.Track.section)
                TextField("自动从 feed 获取，可修改", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!testedOK)
                Text("类型")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.rbText3)
                    .tracking(RB.Track.section)
                    .padding(.top, 4)
                Picker("", selection: $stype) {
                    ForEach(sourceTypes) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.rbAccent)
                .labelsHidden()
                .disabled(!testedOK)

                // 文件夹：检测通过后解锁，下拉选已有分组，默认未分组（下拉位置与「类型」一致）
                Text("文件夹")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.rbText3)
                    .tracking(RB.Track.section)
                    .padding(.top, 4)
                Menu {
                    Button("未分组") { selectedFolderId = nil }
                    ForEach(catalog.folders) { folder in
                        Button(folder.name) { selectedFolderId = folder.id }
                    }
                } label: {
                    Text(catalog.folders.first(where: { $0.id == selectedFolderId })?.name
                         ?? (selectedFolderId == nil ? "未分组" : "未知"))
                        .frame(minWidth: 80, alignment: .leading)
                }
                .tint(Color.rbAccent)
                .menuStyle(.borderlessButton)
                .disabled(!testedOK)
            }
            .opacity(testedOK ? 1 : 0.45)

            if testedOK {
                Text("AI 内容处理")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.rbText3)
                    .tracking(RB.Track.section)
                    .padding(.top, 4)
                HStack(spacing: 16) {
                    Toggle("AI 评分", isOn: $autoScore)
                    Toggle("AI 翻译", isOn: $autoTranslate)
                    Toggle("AI 摘要", isOn: $autoSummarize)
                    Toggle("AI 转录", isOn: $autoTranscribe)
                }

                // B站专属：历史回溯范围选择
                if stype == "bilibili" {
                    Text("历史回溯范围")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.rbText3)
                        .tracking(RB.Track.section)
                        .padding(.top, 4)
                    Picker("", selection: $historyScope) {
                        ForEach(SourceHistoryScope.allCases, id: \.self) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(Color.rbAccent)
                    .labelsHidden()
                }
            }

            if !testResult.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    let isOK = testResult.hasPrefix("✓")
                    let isDup = testResult.hasPrefix("该源已存在")
                    Image(systemName: isOK ? "checkmark.circle.fill"
                                       : (isDup ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill"))
                        .foregroundStyle(isOK ? Color.rbScoreHigh
                                        : (isDup ? Color.rbScoreMid : Color.rbScoreLow))
                        .font(.system(size: 12))
                        .padding(.top, 1)
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(isOK ? Color.rbScoreHigh
                                        : (isDup ? Color.rbScoreMid : Color.rbScoreLow))
                        .textSelection(.enabled)
                }
            }

            HStack {
                Text("添加后立即刷新")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.rbText2)
                Spacer()
                Toggle("", isOn: $refreshAfterAdd)
                    .labelsHidden()
                    .tint(Color.rbAccent)
            }
            HStack {
                Button(testing ? "检测中…" : "检测") { testFeed() }
                    .disabled(identifier.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.quiet)
                Button("添加") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.primaryCapsule)
                    .disabled(!testedOK || testing)
            }

            Text("先「检测」：自动抓取并识别类型，再确认添加，避免加入死源。")
                .font(.caption2).foregroundStyle(Color.rbText3)
        }
        .padding(24)
        .frame(width: 480)
        .task {
            sourceTypes = await onboarding.supportedSourceTypes()
            await catalog.refresh()
        }
    }

    private func testFeed() {
        testing = true
        testResult = ""
        testedOK = false
        resolvedFeedURL = nil
        Task {
            do {
                let input = identifier.trimmingCharacters(in: .whitespaces)
                let result = try await onboarding.discover(
                    identifier: input,
                    suggestedType: stype)
                let kindLabel = sourceTypes.first(where: { $0.id == result.sourceType })?.displayName
                    ?? result.sourceType
                var message = "✓ \(result.suggestedName)：\(result.previewItemCount) 条，识别为 \(kindLabel)，全文 \(result.fetchModeDisplayName)"
                if result.canonicalIdentifier != input {
                    message += "\n（已解析为: \(result.canonicalIdentifier)）"
                }
                await MainActor.run {
                    if result.existingSourceID != nil {
                        testResult = "该源已存在于订阅源列表，无需重复添加"
                        testedOK = false
                    } else {
                        testResult = message
                        resolvedFeedURL = result.canonicalIdentifier
                        resolvedSourceType = result.sourceType
                        testedOK = true
                        stype = result.sourceType
                        detectedMode = result.fetchMode
                        if name.isEmpty { name = result.suggestedName }
                    }
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testResult = "地址不通：\(error.localizedDescription)"
                    testing = false
                }
            }
        }
    }

    private func add() {
        guard let url = resolvedFeedURL else {
            testResult = "✗ 请先检测"
            return
        }
        // 检测结果会预填类型，但用户在下拉中手动修改后应以当前选择为准。
        let sourceType = stype
        let finalName = name.isEmpty ? identifier : name
        testing = true
        testResult = ""
        Task {
            do {
                let result = try await onboarding.create(request: SourceCreationRequest(
                    identifier: url,
                    name: finalName,
                    sourceType: sourceType,
                    folderID: selectedFolderId,
                    policy: SourcePolicySnapshot(
                        autoScore: autoScore,
                        autoTranslate: autoTranslate,
                        autoTranscribe: autoTranscribe,
                        autoSummarize: autoSummarize),
                    fetchMode: detectedMode,
                    historyScope: sourceType == "bilibili" ? historyScope : nil,
                    refreshAfterCreation: false))
                await MainActor.run { dismiss() }
                if refreshAfterAdd {
                    _ = try? await sourceManagement.sync(
                        scope: SourceScope(kind: .source, id: result.sourceID))
                }
            } catch {
                await MainActor.run {
                    testing = false
                    testResult = "✗ \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - OPML 导入汇总确认页
/// 解析后不立即写库——先弹出此页，列出每条的（名称/类型/全文模式/文件夹/内容管线勾选），
/// 用户可单个移除，确认后才落库。与「添加订阅源」同源的检测逻辑。

public struct OPMLImportSummary: View {
    @Environment(\.dismiss) private var dismiss
    let plan: OPMLImportPlan
    private let onboarding: any SourceOnboardingGateway
    @StateObject private var catalog: SourceCatalogStore

    // 类型下拉合法值（article 显示名 RSS 文章，落库映射回 rss）
    private static let stypeOptions: [(value: String, label: String)] = [
        ("article", "RSS 文章"),
        ("podcast", "播客"),
        ("youtube", "YouTube"),
    ]

    @State private var items: [OPMLImportItem] = []
    @State private var policies: [String: PipelinePolicy] = [:]   // 按 url 索引
    @State private var refreshAfterAdd: Bool = true
    @State private var committing = false
    @State private var committedMsg: String? = nil

    public init(
        plan: OPMLImportPlan,
        onboarding: any SourceOnboardingGateway,
        sourceCatalog: any SourceCatalogGateway
    ) {
        self.plan = plan
        self.onboarding = onboarding
        _catalog = StateObject(
            wrappedValue: SourceCatalogStore(gateway: sourceCatalog))
    }

    /// 待添加数 = 非库 且 状态正常(pending) 的项（红/黄已标的不计、不提交）
    private var pendingCount: Int { items.filter { !$0.inLibrary && $0.status == .pending }.count }
    /// 已在库（地址与现有订阅源重复）的项数
    private var inLibCount: Int { items.filter { $0.inLibrary }.count }
    /// 本次导入重复 / 地址不通（任一需跳过的非常规项）的项数
    private var skipCount: Int { items.filter { !$0.inLibrary && $0.status != .pending }.count }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部标题 + 统计
            HStack(alignment: .bottom, spacing: 12) {
                Text("导入预览")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.rbText)
                Text("共 \(plan.outlines.count) 项")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.rbText3)
                if inLibCount > 0 {
                    Text("\(inLibCount) 项已在列表（跳过）")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.rbText3)
                }
                if skipCount > 0 {
                    Text("\(skipCount) 项重复/不通（跳过）")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.rbScoreMid)
                }
                Spacer()
            }
            .padding(.bottom, 10)

            Divider().padding(.bottom, 8)

            // 明细列表（类似订阅管理页的源行）
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach($items) { $item in
                        importRow(item: $item)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 360)

            Divider().padding(.vertical, 8)

            // 底部：添加后自动刷新 开关 + 添加/取消
            HStack {
                Text("添加后自动刷新")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.rbText2)
                Spacer()
                Toggle("", isOn: $refreshAfterAdd)
                    .labelsHidden()
                    .tint(Color.rbAccent)
            }
            .padding(.bottom, 12)

            HStack {
                if let msg = committedMsg {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(Color.rbText3)
                        .lineLimit(1)
                    Spacer()
                } else {
                    Spacer()
                }
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.quiet)
                Button(committing ? "添加中…" : "添加 \(pendingCount) 项") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.primaryCapsule)
                    .disabled(committing || pendingCount == 0)
            }
        }
        .padding(24)
        .frame(width: 600)
        .task { await detectAll() }
    }

    // 单行：名称 / 类型下拉 / 全文模式 / 文件夹 / 管道勾选 / 移除
    private func importRow(item: Binding<OPMLImportItem>) -> some View {
        let url = item.wrappedValue.url
        let inLib = item.wrappedValue.inLibrary
        let status = item.wrappedValue.status
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // 行首状态图标：已存在/重复(黄三角) / 地址不通(红圆叹号)
                // 无论是「已在订阅库」还是「本次导入列表内重复」，对用户都是"重复、将跳过"，
                // 统一用黄色感叹号；本页不再使用任何勾选图标，避免被误读为"已选/会添加"。
                if status == .unreachable {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Color.rbScoreLow)
                        .help("地址不通：无法抓取，提交时将被跳过")
                } else if inLib || status == .duplicate {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.rbScoreMid)
                        .help(inLib ? "已在订阅源列表（与已有源重复），确认时将被跳过" : "列表内重复：提交时将被跳过（可移除多余项）")
                }
                TextField("名称", text: item.name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(inLib || status != .pending)
                // 类型下拉（内容探测结果，可改）
                Picker("", selection: item.stype) {
                    ForEach(Self.stypeOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.rbAccent)
                .labelsHidden()
                .frame(width: 110)
                .disabled(inLib || status != .pending)
                // 移除按钮
                Button { remove(item.wrappedValue.id) } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(Color.rbScoreLow)
                }
                .buttonStyle(.plain)
                .help("从导入列表移除")
                .disabled(inLib)   // 已在库的不可移除（确认时本就跳过）
            }
            // 状态提示行（所有"将跳过"的项都显式说明：已在库/重复 / 地址不通）
            if inLib || status != .pending {
                HStack(spacing: 6) {
                    let msg: String = status == .unreachable
                        ? "地址不通，无法抓取，将跳过"
                        : (inLib ? "与已有订阅源重复，将跳过（不会重复添加）"
                                 : "列表内存在重复地址，将跳过（可点减号移除）")
                    let col: Color = status == .unreachable ? Color.rbScoreLow : Color.rbScoreMid
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(col)
                    Spacer()
                }
            }
            HStack(spacing: 10) {
                // 全文模式标签（检测所得；"检测中"态显示占位）
                Text(item.wrappedValue.detecting ? "检测中…" : (FetchMode(rawValue: item.wrappedValue.fetchModeRaw)?.displayName ?? "—"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.rbText3)
                    .frame(width: 150, alignment: .leading)
                // 文件夹下拉（标签右移、紧贴选单）
                HStack(spacing: 6) {
                    Spacer()
                    Text("文件夹")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.rbText3)
                    Menu {
                        Button("未分组") { item.folderName.wrappedValue = nil }
                        ForEach(catalog.folders) { folder in
                            Button(folder.name) { item.folderName.wrappedValue = folder.name }
                        }
                    } label: {
                        Text(item.wrappedValue.folderName ?? "未分组")
                            .font(.system(size: 11))
                            .frame(minWidth: 60, alignment: .trailing)
                    }
                    .tint(Color.rbAccent)
                    .disabled(inLib || status != .pending)
                }
                .frame(maxWidth: .infinity)
            }
            // 内容管线 4 勾选（标签可见——不再 labelsHidden，独占一行避免拥挤）
            // 识别为「RSS 文章」(article) 的源没有转录——按类型收起 AI 转录
            pipelineToggles(url: url, disabled: inLib || status != .pending, stype: item.wrappedValue.stype)
        }
        .padding(8)
        .background((inLib || status == .duplicate) ? Color.rbScoreMid.opacity(0.06)
                     : (status == .unreachable ? Color.rbScoreLow.opacity(0.06) : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((inLib || status == .duplicate) ? Color.rbScoreMid.opacity(0.30)
                        : (status == .unreachable ? Color.rbScoreLow.opacity(0.30)
                           : Color.rbText3.opacity(0.12)), lineWidth: 1)
        )
    }

    // 内容管线勾选（与 PIPELINE_DEFS 一致：AI 评分/AI 翻译/AI 摘要/AI 转录）
    // 识别为 RSS 文章(article) 的源不提供 AI 转录（没有音视频可转）——按 stype 收起。
    private func pipelineToggles(url: String, disabled: Bool, stype: String) -> some View {
        let flags: [(flag: WritableKeyPath<PipelinePolicy, Bool>, label: String)] = {
            var list = [
                (\PipelinePolicy.autoScore, "AI 评分"),
                (\PipelinePolicy.autoTranslate, "AI 翻译"),
                (\PipelinePolicy.autoSummarize, "AI 摘要"),
            ]
            if stype != "article" {
                list.append((\PipelinePolicy.autoTranscribe, "AI 转录"))
            }
            return list
        }()
        return HStack(spacing: 10) {
            ForEach(flags, id: \.label) { k in
                Toggle(k.label, isOn: Binding(
                    get: { policies[url]?[keyPath: k.flag] ?? false },
                    set: { val in
                        var p = policies[url] ?? PipelinePolicy()
                        p[keyPath: k.flag] = val
                        policies[url] = p
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .controlSize(.small)
                .tint(Color.rbAccent)
                .foregroundStyle(Color.rbText2)
                .help(k.label)
                .disabled(disabled)
            }
        }
    }

    private func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        // 重算列表内重复：移除后若某 url 不再重复，状态由 .duplicate 恢复 .pending
        var urlCounts: [String: Int] = [:]
        for it in items where !it.inLibrary && it.status != .unreachable {
            urlCounts[it.url, default: 0] += 1
        }
        for i in items.indices where !items[i].inLibrary && items[i].status != .unreachable {
            items[i].status = (urlCounts[items[i].url] ?? 0) > 1 ? .duplicate : .pending
        }
    }

    // 后台批量检测：对每条跑一次 discoverAndFetch（同时得出类型 + 全文模式），
    // 与手动添加同源；已存在的项只标记 inLibrary、不检测。
    private func detectAll() async {
        await catalog.refresh()
        var built: [OPMLImportItem] = []
        for o in plan.outlines {
            let inLib = catalog.sources.contains { $0.identifier == o.url }
            built.append(OPMLImportItem(
                name: o.title, url: o.url, stype: mapStype(o.stypeGuess),
                fetchModeRaw: "summary", folderName: o.folderName, inLibrary: inLib,
                detecting: !inLib
            ))
        }
        // 列表内重复检测：非库项里 url 出现 >1 次的，标 .duplicate（黄色叹号，确认时跳过）
        var urlCounts: [String: Int] = [:]
        for it in built where !it.inLibrary { urlCounts[it.url, default: 0] += 1 }
        for i in built.indices where !built[i].inLibrary && (urlCounts[built[i].url] ?? 0) > 1 {
            built[i].status = .duplicate
        }
        await MainActor.run { items = built }

        await withTaskGroup(of: Void.self) { group in
            for i in built.indices where !built[i].inLibrary && built[i].status == .pending {
                let url = built[i].url
                let guess = built[i].stype
                group.addTask {
                    let result = try? await onboarding.discover(
                        identifier: url,
                        suggestedType: guess)
                    await MainActor.run {
                        if let idx = items.firstIndex(where: { $0.url == url && !$0.inLibrary }) {
                            if let result {
                                items[idx].url = result.canonicalIdentifier
                                items[idx].stype = result.sourceType
                                items[idx].fetchModeRaw = result.fetchMode.rawValue
                                items[idx].inLibrary = result.existingSourceID != nil
                                if items[idx].name.isEmpty { items[idx].name = result.suggestedName }
                            } else {
                                // 地址不通：红色叹号，确认时跳过（不静默落库）
                                items[idx].status = .unreachable
                            }
                            items[idx].detecting = false
                        }
                    }
                }
            }
        }
        await MainActor.run {
            let grouped = Dictionary(grouping: items.indices, by: { items[$0].url })
            for indices in grouped.values where indices.count > 1 {
                for index in indices where !items[index].inLibrary {
                    items[index].status = .duplicate
                }
            }
        }
    }

    private func mapStype(_ raw: String) -> String {
        switch raw {
        case "podcast": return "podcast"
        case "youtube", "video": return "youtube"
        default: return "article"
        }
    }

    private func commit() {
        committing = true
        committedMsg = nil
        // 只添加：非库 + 状态正常(pending) 的项；重复/不通已被标红黄并跳过
        let toAdd = items.filter { !$0.inLibrary && $0.status == .pending }
        let skipped = items.filter { !$0.inLibrary && $0.status != .pending }.count
        Task {
            do {
                let requests = toAdd.map { item in
                    let policy = policies[item.url] ?? PipelinePolicy()
                    return SourceBatchImportItem(
                        id: item.id.uuidString,
                        name: item.name,
                        identifier: item.url,
                        sourceType: item.stype,
                        folderName: item.folderName,
                        policy: SourcePolicySnapshot(
                            autoScore: policy.autoScore,
                            autoTranslate: policy.autoTranslate,
                            autoTranscribe: policy.autoTranscribe,
                            autoSummarize: policy.autoSummarize),
                        fetchMode: SourceFetchMode(rawValue: item.fetchModeRaw) ?? .summary)
                }
                let result = try await onboarding.importSources(
                    items: requests,
                    refreshAfterCreation: refreshAfterAdd)
                await MainActor.run {
                    committing = false
                    var msg = result.message
                    let totalSkipped = skipped + result.skippedCount
                    if totalSkipped > 0 { msg += "（\(totalSkipped) 项重复/不通已跳过）" }
                    committedMsg = msg
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + (refreshAfterAdd ? 1.2 : 1.0)) { dismiss() }
                }
            } catch {
                await MainActor.run {
                    committing = false
                    committedMsg = "导入失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
