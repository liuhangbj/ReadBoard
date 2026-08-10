import SwiftUI
import WebKit
import QuartzCore
import ReadBoardContract
import ReadBoardFeatures

public struct ContentView: View {
    private let services: ReadBoardServices
    @StateObject private var vm: ContentViewModel
    @StateObject private var sourceCatalog: SourceCatalogStore
    @EnvironmentObject private var appTab: AppTab
    @Environment(\.openSettings) private var openSettings
    @State private var issueCenter: ReadBoardIssueCenterModel
    @State private var showIssueCenter = false
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool
    /// 界面缩放（@AppStorage 直接绑 UserDefaults——改值视图自动重建，静态读取不会触发刷新）
    @AppStorage("reading.uiFontScale") private var uiFontScale: Double = 1.0
    // 列表外观只由父视图订阅一次，避免 300 个 ArticleRow 各建一组 AppStorage 观察者。
    @AppStorage("list.density") private var listDensity: String = "comfortable"
    @AppStorage("list.showSource") private var listShowSource: Bool = true
    @AppStorage("list.showDate") private var listShowDate: Bool = true
    @AppStorage("list.unreadBold") private var listUnreadBold: Bool = true
    @AppStorage("list.dateFormat") private var listDateFormat: String = "absolute"

    public init(services: ReadBoardServices = .live) {
        self.services = services
        _vm = StateObject(wrappedValue: ContentViewModel(library: services.library))
        _sourceCatalog = StateObject(
            wrappedValue: SourceCatalogStore(gateway: services.sourceCatalog))
        _issueCenter = State(initialValue: ReadBoardIssueCenterModel(
            environment: services.featureEnvironment))
    }

    public var body: some View {
        NavigationSplitView {
            // ── 左栏：源列表 ──
            sourceSidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
        } content: {
            // ── 中栏：文章列表 ──
            articleList
                .navigationSplitViewColumnWidth(min: 280, ideal: 380, max: 640)
        } detail: {
            // ── 右栏：阅读区 ──
            readingPane
        }
        .navigationTitle("ReadBoard")
        .onAppear { vm.loadAll() }
        .background(shortcutHandlers)
        // 轻提示（列表操作反馈）
        .overlay(alignment: .bottom) {
            if let toast = vm.toastMessage {
                Text(toast)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.rbText)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .rbFloatingShadow()
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.toastMessage)
        .sheet(isPresented: $showShortcutHelp) {
            ShortcutHelpView()
        }
        .sheet(isPresented: $showIssueCenter) {
            ReadBoardIssueCenterView(environment: services.featureEnvironment) { action in
                switch action {
                case .openSources: appTab.selection = 1
                case .openOperations: appTab.selection = 3
                case .openSettings(let route):
                    SettingsNavigationStore.shared.request(route)
                    openSettings()
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await issueCenter.refresh()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .task { await sourceCatalog.monitor() }
        .onReceive(NotificationCenter.default.publisher(for: .pipelinePendingUpdated)) { _ in
            Task { await issueCenter.refresh() }
        }
    }

    // MARK: 快捷键（隐藏按钮承载键盘事件）
    // j/k 上下篇, s 星标, 空格已读切换, v 开原文, e 全部已读, f 搜索, ? 帮助
    private var shortcutHandlers: some View {
        Group {
            Button("") { vm.selectNext() }.keyboardShortcut("j", modifiers: [])
            Button("") { vm.selectPrev() }.keyboardShortcut("k", modifiers: [])
            Button("") { if let it = vm.selectedItem { vm.toggleStar(it) } }.keyboardShortcut("s", modifiers: [])
            Button("") { vm.shortcutToggleRead() }.keyboardShortcut(.space, modifiers: [])
            Button("") { openOriginal() }.keyboardShortcut("v", modifiers: [])
            Button("") { vm.markAllRead() }.keyboardShortcut("e", modifiers: [])
            Button("") { showShortcutHelp = true }.keyboardShortcut("?", modifiers: [])
            Button("") { focusSearch() }.keyboardShortcut("f", modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    @State private var showShortcutHelp = false

    private func focusSearch() {
        searchFocused = true   // @FocusState 包装值，赋值即聚焦搜索框
    }

    private func openOriginal() {
        guard let item = vm.selectedItem, let url = URL(string: item.url), !item.url.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }
    // MARK: 左栏（文件夹→源 两级树，订阅源视角）
    @State private var showAddSource = false
    @State private var showImportSummary = false   // OPML 解析后弹汇总确认页（与订阅管理页同源）
    @State private var importPlan: OPMLImportPlan? = nil
    @State private var showAddFolder = false
    @State private var newFolderName = ""
    /// 重命名目标（source: 源 id / folder: 文件夹 id）+ 输入名 + 弹窗状态
    @State private var renameTarget: (kind: String, id: Int64, currentName: String)? = nil
    @State private var renameInput = ""
    @State private var deleteSourceTarget: (id: Int64, name: String)? = nil
    /// 展开的文件夹 id 集合（自己控制，DisclosureGroup 的 label 无法响应点击过滤）
    /// 持久化到 UserDefaults——重启恢复上次的展开/收起状态（首次启动默认全展开）。
    @State private var expandedFolders: Set<String> = []
    /// 开管线后弹「如何处理历史数据」（kind: source/folder，action: pipeline=LLM管线回填 / fulltext=全文重提）
    @State private var pendingBackfill: (kind: String, id: Int64, name: String, pipelineLabel: String, action: String, policyKey: String?)? = nil

    // MARK: 左栏展开状态持久化

    private static let expandedKey = "sidebar.expandedFolders"

    /// 读上次的展开状态；nil = 首次（调用方默认全展开）
    private func loadExpandedFolders() -> Set<String>? {
        guard let arr = UserDefaults.standard.array(forKey: Self.expandedKey) as? [String] else { return nil }
        return Set(arr)
    }

    /// 切换某文件夹展开状态并持久化
    private func toggleFolderExpanded(_ id: String) {
        if expandedFolders.contains(id) {
            expandedFolders.remove(id)
        } else {
            expandedFolders.insert(id)
        }
        UserDefaults.standard.set(Array(expandedFolders), forKey: Self.expandedKey)
    }

    private var sourceSidebar: some View {
        VStack(spacing: 0) {
            // 顶部眉题条：小标题 + 添加文件夹 / 添加源
            HStack(spacing: 4) {
                Button { showIssueCenter = true } label: {
                    ZStack {
                        Circle()
                            .fill(issueCenterStatusColor.opacity(0.16))
                            .frame(width: 24, height: 24)
                        Image(systemName: issueCenterStatusIcon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(issueCenterStatusColor)
                    }
                }
                .buttonStyle(.plain)
                .help("问题中心：\(issueCenter.statusText)")

                SectionLabel(text: "订阅源")
                Spacer()
                Button { showAddFolder = true } label: {
                    Image(systemName: "folder.badge.plus").font(.system(size: 13))
                }
                .buttonStyle(.quiet)
                .help("新建文件夹")
                // 「+」改为下拉菜单：选择「添加订阅源」或「导入 OPML」，
                // 与订阅管理页入口行为一致（opml 解析后弹同源汇总确认页）
                Menu {
                    Button {
                        showAddSource = true
                    } label: {
                        Label("添加订阅源", systemImage: "plus")
                    }
                    Button {
                        importOPML()
                    } label: {
                        Label("导入 OPML", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.quiet)
                .help("添加订阅源 / 导入 OPML")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Hairline()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    // ── 全部文章（清空过滤，显示所有内容）──
                    allArticlesRow
                    // ── 精确待处理：与 Worker 当前任务集合共用同一组 content id ──
                    pendingRow
                    // ── 已导出文章 ──
                    exportedRow

                    sidebarDivider

                    categoryRow(title: "文章", icon: "doc.text.fill", key: "article",
                                unread: vm.articleUnread, total: vm.articleCount)
                    categoryRow(title: "播客", icon: "mic.fill", key: "podcast",
                                unread: vm.podcastUnread, total: vm.podcastCount)
                    categoryRow(title: "视频", icon: "play.rectangle.fill", key: "video",
                                unread: vm.videoUnread, total: vm.videoCount)

                    sidebarDivider

                    ForEach(vm.sidebarTree) { node in
                        if node.isFolder {
                            // 文件夹行：chevron 与行内图标对齐；子源缩进与文件夹名对齐
                            HStack(spacing: 0) {
                                Button {
                                    toggleFolderExpanded(node.id)
                                } label: {
                                    Image(systemName: expandedFolders.contains(node.id) ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Color.rbText3)
                                        .frame(width: 16, alignment: .center)
                                }
                                .buttonStyle(.plain)
                                sidebarRow(node, indent: 0, showChevronSlot: false)
                            }
                            // 展开的子源（缩进对齐：chevron16 + 图标16 + 间距，让源名与文件夹名基线一致）
                            if expandedFolders.contains(node.id) {
                                ForEach(node.children ?? []) { child in
                                    sidebarRow(child, indent: 1, showChevronSlot: true)
                                }
                            }
                        } else {
                            sidebarRow(node, indent: 0, showChevronSlot: true)
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }

            // ── 底部导航：订阅管理 / 数据看板（替代底部 Tab 栏）──
            Hairline()
            HStack(spacing: 8) {
                sidebarNavButton(icon: "dot.radiowaves.left.and.right", label: "订阅管理", tab: 1)
                sidebarNavButton(icon: "chart.bar.doc.horizontal", label: "数据看板", tab: 3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color.rbBgSidebar)   // 左栏略灰分出层次（纸墨留白）
        .sheet(isPresented: $showAddSource) {
            AddSourceSheet(
                onboarding: services.sourceOnboarding,
                sourceCatalog: services.sourceCatalog,
                sourceManagement: services.sourceManagement)
                .onDisappear {
                    vm.loadAll()
                    Task { await sourceCatalog.refresh() }
                }
        }
        .sheet(isPresented: $showImportSummary) {
            if let plan = importPlan {
                OPMLImportSummary(
                    plan: plan,
                    onboarding: services.sourceOnboarding,
                    sourceCatalog: services.sourceCatalog)
                    .onDisappear {
                        vm.loadAll()
                        Task { await sourceCatalog.refresh() }
                    }
            }
        }
        .alert("新建文件夹", isPresented: $showAddFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("创建") {
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    Task {
                        _ = try? await services.sourceManagement.createFolder(name: name)
                        vm.loadAll()
                    }
                }
                newFolderName = ""
            }
            Button("取消", role: .cancel) { newFolderName = "" }
        } message: {
            Text("文件夹用于给订阅源分组（如「快讯」「深度」），并可批量设置组内内容处理选项。")
        }
        // 重命名对话框（源/文件夹共用）
        .alert("重命名", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("名称", text: $renameInput)
            Button("保存") {
                let name = renameInput.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, let t = renameTarget {
                    let scope = SourceScope(
                        kind: t.kind == "source" ? .source : .folder,
                        id: t.id)
                    Task {
                        _ = try? await services.sourceManagement.rename(scope: scope, name: name)
                        vm.loadAll()
                    }
                }
                renameTarget = nil
            }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        .alert("永久删除订阅源？", isPresented: Binding(
            get: { deleteSourceTarget != nil },
            set: { if !$0 { deleteSourceTarget = nil } }
        )) {
            Button("取消", role: .cancel) { deleteSourceTarget = nil }
            Button("永久删除", role: .destructive) {
                guard let target = deleteSourceTarget else { return }
                deleteSourceTarget = nil
                Task {
                    let result = try? await services.sourceManagement.remove(
                        scope: SourceScope(kind: .source, id: target.id))
                    if vm.selectedItem?.feedId == target.id { vm.selectedItem = nil }
                    if vm.selectedFilter == "source_id=\(target.id)" { vm.selectedFilter = nil }
                    vm.loadAll()
                    vm.showToast("已删除「\(target.name)」及其 \(result?.affectedCount ?? 0) 条内容")
                }
            }
        } message: {
            if let target = deleteSourceTarget {
                Text("将永久删除「\(target.name)」及其全部文章、AI 处理结果和应用内导出记录。此操作无法撤销；已经写入 Obsidian 的文件不会删除。")
            }
        }
        // 开管线/切全文模式后弹「如何处理历史数据」（左栏右键触发，和订阅源页一致）
        .alert("处理历史数据？", isPresented: Binding(
            get: { pendingBackfill != nil },
            set: { if !$0 { pendingBackfill = nil } }
        )) {
            Button(pendingBackfill?.action == "fulltext" ? "重提所有历史全文" : "处理所有历史内容") {
                if let p = pendingBackfill {
                    let scope = SourceScope(
                        kind: p.kind == "folder" ? .folder : .source,
                        id: p.id)
                    if p.action == "fulltext" {
                        Task {
                            _ = try? await services.sourceManagement.refetchFulltext(
                                scope: scope, fullHistory: false)
                        }
                    } else if let rawKey = p.policyKey,
                              let key = SourcePolicyKey(rawValue: rawKey) {
                        Task {
                            _ = try? await services.sourceManagement.backfillProcessing(
                                scope: scope, key: key)
                        }
                    }
                }
                pendingBackfill = nil
            }
            Button("只处理新增", role: .cancel) { pendingBackfill = nil }
        } message: {
            if let p = pendingBackfill {
                if p.action == "fulltext" {
                    Text("「\(p.name)」的全文提取模式已切换为\(p.pipelineLabel)。\n\n• 重提历史：存量文章按新模式重新提取全文（耗时较长）\n• 只处理新增：历史不动，新抓的按新模式抓")
                } else {
                    Text("「\(p.name)」的\(p.pipelineLabel)已开启。\n\n• 处理历史：存量内容补做相应处理（耗时较长，按量计费）\n• 只处理新增：历史不动，新抓的自动进入内容处理引擎")
                }
            }
        }
        .onAppear {
            // 恢复上次的展开/收起状态；首次启动（无保存）默认全展开
            if let saved = loadExpandedFolders() {
                expandedFolders = saved
            } else {
                expandedFolders = Set(vm.sidebarTree.filter { $0.isFolder }.map { $0.id })
            }
            Task { await issueCenter.refresh() }
        }
        .onChange(of: sourceCatalog.sources) { _, _ in
            Task { await issueCenter.refresh() }
        }
    }

    private var issueCenterStatusColor: Color {
        switch issueCenter.status {
        case .healthy: .rbScoreHigh
        case .repairing: .rbScoreMid
        case .needsAttention: .rbScoreLow
        }
    }

    private var issueCenterStatusIcon: String {
        switch issueCenter.status {
        case .healthy: "checkmark"
        case .repairing: "arrow.triangle.2.circlepath"
        case .needsAttention: "exclamationmark"
        }
    }

    /// 左栏底部导航按钮（切到 订阅源管理/数据统计 全窗视图）
    private func sidebarNavButton(icon: String, label: String, tab: Int) -> some View {
        Button {
            appTab.selection = tab
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                Image(systemName: icon)
                    .font(.system(size: 12))
            }
            .foregroundStyle(Color.rbText2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.rowHover)
        .help("打开「\(label)」页面")
    }

    /// 左栏统一的“未读/全部”计数。固定数字槽优先保留，窄栏时名称截断而不吞掉计数。
    private func sidebarCount(unread: Int, total: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            sidebarCountPair(unread: "\(unread)", total: "\(total)", hasUnread: unread > 0)
            sidebarCountPair(
                unread: Self.compactSidebarCount(unread),
                total: Self.compactSidebarCount(total),
                hasUnread: unread > 0)
        }
        .monospacedDigit()
        .lineLimit(1)
        .frame(minWidth: 44, idealWidth: 80, maxWidth: 96, alignment: .trailing)
        .layoutPriority(2)
        .accessibilityLabel("未读 \(unread)，全部 \(total)")
    }

    private func sidebarCountPair(unread: String, total: String, hasUnread: Bool) -> some View {
        HStack(spacing: 1) {
            Text(unread)
                .font(.system(size: RB.F.count * uiFontScale,
                              weight: hasUnread ? .medium : .regular))
                .foregroundStyle(hasUnread ? Color.rbAccent : Color.rbText3)
            Text("/\(total)")
                .font(.system(size: RB.F.count * uiFontScale))
                .foregroundStyle(Color.rbText3)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    nonisolated private static func compactSidebarCount(_ count: Int) -> String {
        guard count >= 10_000 else { return String(count) }
        let value = Double(count) / 10_000
        return value >= 10
            ? String(format: "%.0f万", value)
            : String(format: "%.1f万", value)
    }

    // MARK: OPML 导入（主界面入口，与订阅管理页同源）

    /// 主界面「导入 OPML」：NSOpenPanel 挂 mainWindow（fileImporter 在 NavigationSplitView
    /// 里不弹，实锤按钮触发但面板不出，故用 NSOpenPanel）。
    private func importOPML() {
        let panel = NSOpenPanel()
        // 不过滤文件类型——opml 是未注册动态 UTI，用 .xml 过滤会把它排除（灰掉选不了）。
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要导入的 OPML 文件（.opml 或 .xml）"
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.mainWindow else {
            vm.toastMessage = "无法打开文件选择器（无活动窗口）"
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let xml = try? String(contentsOf: url, encoding: .utf8) else {
                DispatchQueue.main.async { vm.toastMessage = "读取文件失败：\(url.lastPathComponent)" }
                return
            }
            DispatchQueue.main.async { vm.toastMessage = "解析中…" }
            DispatchQueue.global(qos: .userInitiated).async {
                let plan = OPMLService.shared.parseOPML(xml)
                DispatchQueue.main.async {
                    if let err = plan.parseError {
                        vm.toastMessage = "导入失败：\(err)"
                        return
                    }
                    if plan.outlines.isEmpty {
                        vm.toastMessage = "未从文件中解析到任何订阅源"
                        return
                    }
                    vm.toastMessage = nil
                    showImportSummary = true
                    importPlan = plan
                }
            }
        }
    }

    /// 左栏顶部「全部文章」行（清空过滤，显示所有内容）
    private var allArticlesRow: some View {
        let scale = uiFontScale
        let active = vm.selectedFilter == nil
        return Button {
            vm.selectFilter(nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .foregroundStyle(Color.rbAccent)
                    .frame(width: 16)
                Text("全部文章")
                    .font(.system(size: RB.F.sidebar * scale))
                    .foregroundStyle(Color.rbText)
                    .lineLimit(1)
                Spacer()
                sidebarCount(unread: vm.totalUnread, total: vm.totalCount)
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.vertical, 5 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .rbSelection(active)
        }
        .buttonStyle(.rowHover)
    }

    /// 左栏「待处理」显示尚未达到条目 auto_* 所要求处理标准的全部内容。
    private var pendingRow: some View {
        let scale = uiFontScale
        let active = vm.selectedFilter == "pending"
        return Button { vm.selectFilter("pending") } label: {
            HStack(spacing: 6) {
                Image(systemName: "gearshape.2.fill")
                    .foregroundStyle(Color.rbAccent)
                    .frame(width: 16)
                Text("待处理")
                    .font(.system(size: RB.F.sidebar * scale))
                    .foregroundStyle(Color.rbText)
                    .lineLimit(1)
                Spacer()
                sidebarCount(unread: vm.totalPendingUnread, total: vm.totalPending)
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.vertical, 5 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .rbSelection(active)
        }
        .buttonStyle(.rowHover)
    }

    /// 左栏「已导出」行（点击过滤到已导出文章）
    private var exportedRow: some View {
        let scale = uiFontScale
        let active = vm.selectedFilter == "exported"
        return Button {
            vm.selectFilter("exported")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up.fill")
                    .foregroundStyle(Color.rbAccent)
                    .frame(width: 16)
                Text("已导出")
                    .font(.system(size: RB.F.sidebar * scale))
                    .foregroundStyle(Color.rbText)
                    .lineLimit(1)
                Spacer()
                sidebarCount(unread: vm.totalExportedUnread, total: vm.totalExported)
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.vertical, 5 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .rbSelection(active)
        }
        .buttonStyle(.rowHover)
    }

    private var sidebarDivider: some View {
        Hairline()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
    }

    private func categoryRow(title: String, icon: String, key: String,
                             unread: Int, total: Int) -> some View {
        let scale = uiFontScale
        let active = vm.selectedFilter == "ctype=\(key)"
        return Button { vm.selectFilter("ctype=\(key)") } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.rbAccent)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: RB.F.sidebar * scale))
                    .foregroundStyle(Color.rbText)
                    .lineLimit(1)
                Spacer()
                sidebarCount(unread: unread, total: total)
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.vertical, 5 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .rbSelection(active)
        }
        .buttonStyle(.rowHover)
    }

    /// 左栏行（点击过滤 + 未读角标 + 右键设置菜单）。
    /// Button 而非 List.tag——List selection 对 DisclosureGroup/自定义行不可靠。
    /// showChevronSlot：是否预留 chevron 占位宽度（子源/无 chevron 的源行用来对齐有 chevron 的文件夹行）
    private func sidebarRow(_ node: SidebarNode, indent: Int, showChevronSlot: Bool) -> some View {
        let scale = uiFontScale
        let selected = vm.selectedFilter == node.filterKey
        return Button {
            vm.selectFilter(node.filterKey)
        } label: {
            HStack(spacing: 6) {
                // chevron 占位（子源/普通源行对齐文件夹行的 chevron 宽度）
                if showChevronSlot {
                    Spacer().frame(width: 16)
                }
                if node.isFolder {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.rbText3)
                        .frame(width: 16)
                }
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(size: RB.F.sidebar * scale))
                    .foregroundStyle(Color.rbText)
                Spacer()
                sidebarCount(unread: node.unread, total: node.count)
            }
            .padding(.leading, node.isFolder ? 0 : (indent > 0 ? 6 : 0))
            .padding(.trailing, 10)
            .padding(.vertical, 5 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .rbSelection(selected)
        }
        .buttonStyle(.rowHover)
        .contextMenu { sidebarContextMenu(node) }
    }

    /// 左栏右键设置菜单（源/文件夹共用，按类型出不同项）
    @ViewBuilder
    private func sidebarContextMenu(_ node: SidebarNode) -> some View {
        if let sid = node.sourceId {
            // ── 单源设置 ──
            Button {
                renameTarget = ("source", sid, node.name)
                renameInput = node.name
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button { Task { await refreshSource(sid) } } label: {
                Label("立即刷新", systemImage: "arrow.clockwise")
            }
            Button { markSourceRead(sid) } label: {
                Label("全部标为已读", systemImage: "checkmark.circle")
            }
            Divider()
            // 管线开关快速切换
            if let src = sourceCatalog.sources.first(where: { $0.id == sid }) {
                Menu {
                    pipelineToggleMenu(src: src)
                } label: {
                    Label("内容处理", systemImage: "gearshape.2")
                }
                Menu {
                    fetchSettingsMenu(src: src)
                } label: {
                    Label("抓取设置", systemImage: "arrow.down.circle")
                }
                // 重新提取全文（该源全部文章重提）
                Button {
                    Task {
                        _ = try? await services.sourceManagement.refetchFulltext(
                            scope: SourceScope(kind: .source, id: sid), fullHistory: true)
                    }
                } label: {
                    Label("重新提取全文", systemImage: "arrow.triangle.2.circlepath")
                }
                Divider()
                Menu {
                    Button("无文件夹") {
                        Task {
                            try? await services.sourceManagement.assignSource(sourceID: sid, folderID: nil)
                            vm.loadAll()
                        }
                    }
                    ForEach(sourceCatalog.folders) { f in
                        Button(f.name) {
                            Task {
                                try? await services.sourceManagement.assignSource(sourceID: sid, folderID: f.id)
                                vm.loadAll()
                            }
                        }
                    }
                } label: {
                    Label("移动到文件夹", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive) {
                    deleteSourceTarget = (sid, src.name)
                } label: {
                    Label("永久删除此源", systemImage: "trash")
                }
            }
        } else if let fid = node.folderId {
            // ── 文件夹设置 ──
            Button {
                renameTarget = ("folder", fid, node.name)
                renameInput = node.name
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button { Task { await refreshFolder(fid) } } label: {
                Label("立即刷新全部", systemImage: "arrow.clockwise")
            }
            Button { markFolderRead(fid) } label: {
                Label("全部标为已读", systemImage: "checkmark.circle")
            }
            Divider()
            if let folder = sourceCatalog.folders.first(where: { $0.id == fid }) {
                Menu {
                    folderPipelineMenu(folder: folder)
                } label: {
                    Label("内容处理", systemImage: "gearshape.2")
                }
            }
            // 抓取设置（与订阅源统一：提取全文三态 + 抓取频率，打钩反映组内一致性）
            Menu {
                folderFetchSettingsMenu(folderId: fid)
            } label: {
                Label("抓取设置", systemImage: "arrow.down.circle")
            }
            // 重新提取全文（对文件夹内所有源批量重提）
            Button {
                Task {
                    _ = try? await services.sourceManagement.refetchFulltext(
                        scope: SourceScope(kind: .folder, id: fid), fullHistory: true)
                }
            } label: {
                Label("重新提取全文", systemImage: "arrow.triangle.2.circlepath")
            }
            Divider()
            Button(role: .destructive) {
                Task {
                    _ = try? await services.sourceManagement.remove(
                        scope: SourceScope(kind: .folder, id: fid))
                    vm.loadAll()
                }
            } label: {
                Label("删除文件夹", systemImage: "trash")
            }
        }
    }

    /// 重新处理（右键菜单用）：与 Worker 共用 contentId 锁，并按包含关系合并 LLM 调用。
    private func reprocessItem(item: ContentItem) {
        ProcessingCommandCoordinator.start(
            gateway: services.processing,
            contentID: item.id,
            title: item.title,
            operation: .allEnabled)
    }

    /// 单篇文章跑管线（评分/摘要/翻译/转录）——右键菜单调用
    private func runPipelineForItem(item: ContentItem, type: String) {
        guard let operation = ProcessingOperation(rawValue: type) else {
            vm.showToast("不支持的处理类型")
            return
        }
        ProcessingCommandCoordinator.start(
            gateway: services.processing,
            contentID: item.id,
            title: item.title,
            operation: operation)
    }

    /// 删除单篇转录稿（同时清理转录 job，方便按 auto_transcribe 重新转录）
    private func deleteTranscriptForItem(item: ContentItem) {
        guard item.hasTranscript else { return }
        ProcessingCommandCoordinator.start(
            gateway: services.processing,
            contentID: item.id,
            title: item.title,
            operation: .deleteTranscript,
            trackProgress: false
        ) { snapshot in
            vm.showToast(snapshot.message)
        }
    }

    /// 源级管线开关菜单（打勾状态实时反映）
    @ViewBuilder
    private func pipelineToggleMenu(src: SourceCatalogItem) -> some View {
        Button {
            Task {
                _ = try? await services.sourceManagement.backfillProcessing(
                    scope: SourceScope(kind: .source, id: src.id), key: nil)
            }
        } label: {
            Label("重新处理本源全部", systemImage: "arrow.triangle.2.circlepath")
        }
        Divider()
        pipelineMenuItem("AI 评分", key: "auto_score", on: src.policy.autoScore, src: src)
        pipelineMenuItem("AI 翻译", key: "auto_translate", on: src.policy.autoTranslate, src: src)
        pipelineMenuItem("AI 摘要", key: "auto_summarize", on: src.policy.autoSummarize, src: src)
        if src.transcribable {
            pipelineMenuItem("AI 转录", key: "auto_transcribe", on: src.policy.autoTranscribe, src: src)
        }
    }

    private func pipelineMenuItem(_ label: String, key: String, on: Bool, src: SourceCatalogItem) -> some View {
        Button {
            let turningOn = !on
            if let policyKey = SourcePolicyKey(rawValue: key) {
                Task {
                    try? await services.sourceManagement.setPolicy(
                        scope: SourceScope(kind: .source, id: src.id),
                        key: policyKey,
                        enabled: turningOn)
                }
            }
            // 开启时弹「如何处理历史数据」（和订阅源页一致）
            if turningOn {
                pendingBackfill = ("source", src.id, src.name, label, "pipeline", key)
            }
        } label: {
            // 只留打钩表勾选态（不要内容图标——勾选清晰可见最重要）
            Label(label, systemImage: on ? "checkmark" : "")
        }
    }

    /// 抓取设置菜单（fetch_mode + 频率）
    @ViewBuilder
    private func fetchSettingsMenu(src: SourceCatalogItem) -> some View {
        Menu("提取全文：\(src.fetchModeAuto ? "自动（\(fulltextDisplayName(for: src))）" : fulltextDisplayName(for: src))") {
            // ── 自动检测 ──
            Button {
                Task {
                    try? await services.sourceManagement.setFetchMode(
                        scope: SourceScope(kind: .source, id: src.id), mode: .automatic)
                }
            } label: {
                HStack {
                    Image(systemName: src.fetchModeAuto ? "checkmark" : "arrow.triangle.2.circlepath")
                    Text("自动（\(fulltextDisplayName(for: src))）")
                }
            }
            Button("重新检测") {
                Task {
                    try? await services.sourceManagement.redetectFetchMode(
                        scope: SourceScope(kind: .source, id: src.id))
                }
            }
            Divider()
            // ── 五层级手动选择 ──
            ForEach(fetchModes(for: src.stype), id: \.rawValue) { fm in
                Button {
                    guard let mode = SourceFetchMode(rawValue: fm.rawValue) else { return }
                    Task {
                        try? await services.sourceManagement.setFetchMode(
                            scope: SourceScope(kind: .source, id: src.id), mode: mode)
                    }
                } label: {
                    HStack {
                        Image(systemName: (!src.fetchModeAuto && src.localFetchMode == fm) ? "checkmark" : "")
                            .frame(width: 12)
                        Text(fulltextDisplayName(for: src, mode: fm))
                    }
                }
            }
        }
        Menu("抓取频率：\(src.fetchIntervalMin < 60 ? "\(src.fetchIntervalMin)分钟" : "\(src.fetchIntervalMin/60)小时")") {
            ForEach([5, 15, 30, 60, 120, 360, 720], id: \.self) { m in
                Button {
                    Task {
                        try? await services.sourceManagement.setFetchInterval(
                            scope: SourceScope(kind: .source, id: src.id), minutes: m)
                    }
                } label: {
                    Label(m < 60 ? "\(m) 分钟" : "\(m/60) 小时",
                          systemImage: src.fetchIntervalMin == m ? "checkmark" : "")
                }
            }
        }
    }

    private func fulltextDisplayName(for src: SourceCatalogItem, mode: FetchMode? = nil) -> String {
        src.localFetchModeDisplayName(mode)
    }

    /// 平台源只显示自己的字幕路径与「仅摘要」；普通源不暴露平台专属模式。
    private func fetchModes(for sourceType: String) -> [FetchMode] {
        if let source = sourceCatalog.sources.first(where: { $0.stype == sourceType }) {
            return source.localAvailableFetchModes
        }
        return FetchMode.allCases.filter(\.isUserSelectable)
    }

    // MARK: 文件夹抓取设置（与订阅源统一：打钩反映组内是否一致）

    /// 文件夹内所有源的 fetch_interval_min 是否全一致；一致返回该值
    private func folderUniformInterval(_ fid: Int64) -> Int? {
        let intervals = sourceCatalog.sources(inFolder: fid).map { $0.fetchIntervalMin }
        guard let first = intervals.first else { return nil }
        return intervals.allSatisfy { $0 == first } ? first : nil
    }

    /// 文件夹内所有源的「提取全文」状态是否全一致（设置状态 + 实际模式都一致才算）。
    /// 返回 ("auto", 模式) / ("manual", 模式) / ("off", nil) / nil（不一致→「按订阅源设置」）。
    private func folderUniformFetchMode(_ fid: Int64) -> (kind: String, mode: FetchMode?)? {
        let srcs = sourceCatalog.sources(inFolder: fid)
        guard !srcs.isEmpty else { return nil }
        // 全部自动（fetchModeAuto=true）→ 还要实际模式全相同才算一致（各源探测结果不同=混合=按订阅源设置）
        if srcs.allSatisfy({ $0.fetchModeAuto }) {
            let modes = srcs.map { $0.localFetchMode }
            guard let first = modes.first, modes.allSatisfy({ $0 == first }) else { return nil }
            return ("auto", first)
        }
        // 全部手动（fetchModeAuto=false）+ 模式相同 = 一致的手动模式
        if srcs.allSatisfy({ !$0.fetchModeAuto }) {
            let modes = srcs.map { $0.localFetchMode }
            guard let first = modes.first, modes.allSatisfy({ $0 == first }) else { return nil }
            return ("manual", first)
        }
        // 全部仅摘要（fetchMode==.summary——关闭全文提取=summary 兜底，播客显示摘要同此）
        if srcs.allSatisfy({ $0.isFetchOff }) {
            return ("off", nil)
        }
        return nil
    }

    /// 文件夹抓取设置菜单（结构和打钩位置与订阅源完全一致；不一致显示「按订阅源设置」）
    @ViewBuilder
    private func folderFetchSettingsMenu(folderId fid: Int64) -> some View {
        let uniformMode = folderUniformFetchMode(fid)
        let uniformInterval = folderUniformInterval(fid)

        // ── 提取全文 ──
        Menu("提取全文：\(folderFetchModeLabel(fid, uniform: uniformMode))") {
            // 自动（打钩：全组都是自动）
            Button {
                Task {
                    try? await services.sourceManagement.setFetchMode(
                        scope: SourceScope(kind: .folder, id: fid), mode: .automatic)
                }
            } label: {
                HStack {
                    Image(systemName: uniformMode?.kind == "auto" ? "checkmark" : "arrow.triangle.2.circlepath")
                    Text("自动\(uniformMode?.kind == "auto" && uniformMode?.mode != nil ? "（\(uniformMode!.mode!.displayName)）" : "")")
                }
            }
            // 重新检测（始终提供，对全组批量探测）
            Button("重新检测") {
                Task {
                    try? await services.sourceManagement.redetectFetchMode(
                        scope: SourceScope(kind: .folder, id: fid))
                }
            }
            Divider()
            // 五层级手动选择（打钩：全组都是该手动模式）
            ForEach(FetchMode.allCases.filter(\.isUserSelectable), id: \.rawValue) { fm in
                Button {
                    guard let mode = SourceFetchMode(rawValue: fm.rawValue) else { return }
                    Task {
                        try? await services.sourceManagement.setFetchMode(
                            scope: SourceScope(kind: .folder, id: fid), mode: mode)
                    }
                } label: {
                    HStack {
                        Image(systemName: (uniformMode?.kind == "manual" && uniformMode?.mode == fm) ? "checkmark" : "")
                            .frame(width: 12)
                        Text(fm.displayName)
                    }
                }
            }
            Divider()
            // 不一致时：都不打钩，显示「按订阅源设置」并打钩
            Button {} label: {
                Label("按订阅源设置", systemImage: uniformMode == nil ? "checkmark" : "")
            }
            .disabled(true)
        }

        // ── 抓取频率 ──
        Menu("抓取频率：\(uniformInterval != nil ? (uniformInterval! < 60 ? "\(uniformInterval!)分钟" : "\(uniformInterval!/60)小时") : "按订阅源设置")") {
            ForEach([5, 15, 30, 60, 120, 360, 720], id: \.self) { m in
                Button {
                    Task {
                        try? await services.sourceManagement.setFetchInterval(
                            scope: SourceScope(kind: .folder, id: fid), minutes: m)
                    }
                } label: {
                    Label(m < 60 ? "\(m) 分钟" : "\(m/60) 小时",
                          systemImage: uniformInterval == m ? "checkmark" : "")
                }
            }
            Divider()
            Button {} label: {
                Label("按订阅源设置", systemImage: uniformInterval == nil ? "checkmark" : "")
            }
            .disabled(true)
        }
    }

    /// 文件夹「提取全文」菜单标题的当前值文本
    private func folderFetchModeLabel(_ fid: Int64, uniform: (kind: String, mode: FetchMode?)?) -> String {
        guard let uniform else { return "按订阅源设置" }
        switch uniform.kind {
        case "auto": return uniform.mode != nil ? "自动（\(uniform.mode!.displayName)）" : "自动"
        case "manual": return uniform.mode != nil ? uniform.mode!.displayName : "手动"
        case "off": return "仅摘要"
        default: return "按订阅源设置"
        }
    }


    /// 文件夹级管线菜单（打钩显示组内一致性：全开=钩，全关=不钩，不一致=「按订阅源设置」不钩）
    @ViewBuilder
    private func folderPipelineMenu(folder: SourceFolderItem) -> some View {
        Button {
            Task {
                _ = try? await services.sourceManagement.backfillProcessing(
                    scope: SourceScope(kind: .folder, id: folder.id), key: nil)
            }
        } label: {
            Label("重新处理本夹全部", systemImage: "arrow.triangle.2.circlepath")
        }
        Divider()
        folderPipelineItem("AI 评分", key: "auto_score", folder: folder)
        folderPipelineItem("AI 翻译", key: "auto_translate", folder: folder)
        folderPipelineItem("AI 摘要", key: "auto_summarize", folder: folder)
        folderPipelineItem("AI 转录", key: "auto_transcribe", folder: folder)
    }

    /// 文件夹内所有源某管线键的值是否全一致；一致返回该值（true/false），不一致返回 nil
    private func folderUniformPolicy(_ fid: Int64, key: String) -> Bool? {
        let vals = sourceCatalog.sources(inFolder: fid).map { src -> Bool in
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

    private func folderPipelineItem(_ label: String, key: String, folder: SourceFolderItem) -> some View {
        let uniform = folderUniformPolicy(folder.id, key: key)
        // 一致时：值即组内统一值；不一致时：nil（显示「按订阅源设置」不钩）
        let isOn = uniform ?? false
        let inconsistent = uniform == nil
        return Button {
            // 切换目标：当前非全开则全设开，当前全开则全设关（不一致时默认全设开）
            let turningOn = !(uniform ?? false)
            if let policyKey = SourcePolicyKey(rawValue: key) {
                Task {
                    try? await services.sourceManagement.setPolicy(
                        scope: SourceScope(kind: .folder, id: folder.id),
                        key: policyKey,
                        enabled: turningOn)
                }
            }
            // 开启时弹「如何处理历史数据」（和订阅源页一致）
            if turningOn {
                pendingBackfill = ("folder", folder.id, folder.name, label, "pipeline", key)
            }
        } label: {
            // 只留打钩表勾选态；不一致显示「按订阅源设置」不钩
            if inconsistent {
                Label("\(label)（按订阅源设置）", systemImage: "")
            } else {
                Label(label, systemImage: isOn ? "checkmark" : "")
            }
        }
    }

    // MARK: 左栏操作辅助

    private func refreshSource(_ sid: Int64) async {
        _ = try? await services.sourceManagement.sync(
            scope: SourceScope(kind: .source, id: sid))
        vm.loadAll()
    }

    private func refreshFolder(_ fid: Int64) async {
        _ = try? await services.sourceManagement.sync(
            scope: SourceScope(kind: .folder, id: fid))
        vm.loadAll()
    }

    private func markSourceRead(_ sid: Int64) {
        Task {
            do {
                _ = try await services.library.markRead(filter: ContentFilter(sourceID: sid))
                vm.loadAll()
            } catch {
                vm.showToast(error.localizedDescription)
            }
        }
    }

    private func markFolderRead(_ fid: Int64) {
        Task {
            do {
                _ = try await services.library.markRead(filter: ContentFilter(folderID: fid))
                vm.loadAll()
            } catch {
                vm.showToast(error.localizedDescription)
            }
        }
    }

    // MARK: 中栏

    /// 筛选 chip（纸墨胶囊：激活墨蓝浅底+描边，未激活 surface+hairline）
    /// 三态筛选 chip：.none 不筛选（surface 底）/ .yes 已处理（实色）/ .no 未处理（淡粉）
    private func filterChip(label: String, state: ContentViewModel.ProcessedState,
                            action: @escaping () -> Void) -> some View {
        let (bg, fg, border): (Color, Color, Color) = {
            switch state {
            case .yes:  return (Color.rbAccent.opacity(0.14), Color.rbAccent, Color.rbAccent.opacity(0.35))
            case .no:   return (Color.rbPink.opacity(0.16), Color.rbPink, Color.rbPink.opacity(0.40))
            case .none: return (Color.rbSurface, Color.rbText2, Color.rbHairline)
            }
        }()
        return Button(action: action) {
            Text(label)
                .font(.system(size: 11))
                .padding(.horizontal, 8).padding(.vertical, 3.5)
                .background(bg)
                .foregroundStyle(fg)
                .clipShape(RoundedRectangle(cornerRadius: RB.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: RB.Radius.md)
                        .strokeBorder(border, lineWidth: RB.Line.hair)
                )
        }
        .buttonStyle(.plain)
    }

    /// 处理状态三态按钮：none→已处理(实色 yes)→未处理(淡粉 no)→none
    private func processedToggle(key: String, label: String) -> some View {
        let state = vm.processedStates[key] ?? .none
        return filterChip(label: label, state: state) {
            let next = state.next
            if next == .none { vm.processedStates.removeValue(forKey: key) }
            else { vm.processedStates[key] = next }
            vm.reload()
        }
    }

    private var scoreFilterControls: some View {
        HStack(spacing: 5) {
            Text("评分")
                .font(.system(size: 11))
                .foregroundStyle(Color.rbText3)
            scoreField(placeholder: "0", value: $vm.minScore)
            Text("–")
                .font(.system(size: 11))
                .foregroundStyle(Color.rbText3)
            scoreField(placeholder: "100", value: $vm.maxScore)
            if vm.minScore > 0 || vm.maxScore < 100 {
                filterChip(label: "含未评分", state: vm.includeUnscored ? .yes : .none) {
                    vm.includeUnscored.toggle()
                    vm.reload()
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func scoreField(placeholder: String, value: Binding<Int>) -> some View {
        TextField(placeholder, value: value, format: .number)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .frame(width: 30)
            .padding(.horizontal, 6)
            .padding(.vertical, 3.5)
            .background(RoundedRectangle(cornerRadius: RB.Radius.md).fill(Color.rbSurface))
            .overlay(
                RoundedRectangle(cornerRadius: RB.Radius.md)
                    .strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
            )
            .onSubmit { vm.reload() }
            .onChange(of: value.wrappedValue) { _, _ in vm.reloadDebounced() }
    }

    private var readAndSortControls: some View {
        HStack(spacing: 8) {
            RBSegmented(
                items: ContentViewModel.ReadFilter.allCases.map { ($0, $0.display) },
                selection: $vm.readFilter
            )
            .onChange(of: vm.readFilter) { _, _ in vm.reload() }

            Menu {
                ForEach(ContentViewModel.SortOrder.allCases) { order in
                    Button { vm.sortOrder = order } label: {
                        Label(order.display, systemImage: vm.sortOrder == order ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.rbText3)
                    Text(vm.sortOrder.display)
                        .font(.system(size: 11))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.rbText3)
                }
                .foregroundStyle(Color.rbText2)
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(Color.rbSurface))
                .overlay(Capsule().strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onChange(of: vm.sortOrder) { _, _ in vm.reload() }
        }
    }

    private var articleList: some View {
        VStack(spacing: 0) {
            // 搜索框（胶囊输入：surface 底 + hairline 描边，聚焦转墨蓝）
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.rbText3)
                    .font(.system(size: 12))
                TextField("搜索标题 / 正文", text: $vm.keyword)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
                    .onChange(of: searchFocused) { _, f in vm.searchFocused = f }
                    .onChange(of: vm.keyword) { _, _ in vm.reloadDebounced() }
                if !vm.keyword.isEmpty {
                    Button { vm.keyword = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.rbText3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .rbFieldBackground(focused: searchFocused)
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // 筛选条行1：宽栏同排；窄栏自动拆成“评分区间 / 阅读状态+排序”两行。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    scoreFilterControls
                    Spacer(minLength: 8)
                    readAndSortControls
                }
                VStack(alignment: .leading, spacing: 6) {
                    scoreFilterControls
                    HStack(spacing: 8) {
                        readAndSortControls
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 筛选条行2：处理状态平铺三态按钮（AI 评分/AI 摘要/AI 翻译/AI 转录，可多选）
            // 三态：无底色=不筛选 → 实色=已处理 → 淡粉=未处理，点击循环切换
            RBFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                Text("处理")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.rbText3)
                processedToggle(key: "fulltext", label: "全文提取")
                processedToggle(key: "score", label: "AI 评分")
                processedToggle(key: "summary", label: "AI 摘要")
                processedToggle(key: "translate", label: "AI 翻译")
                processedToggle(key: "transcribe", label: "AI 转录")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Hairline()

            // 操作条：计数 + 全部标已读
            HStack {
                SectionLabel(text: "\(vm.items.count) 条")
                Spacer()
                Button {
                    vm.markAllRead()
                } label: {
                    Label("全部已读", systemImage: "checkmark.circle")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.quiet)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            List(selection: Binding(
                get: { vm.selectedItem },
                // 点击触发的 set 在事件处理上下文（非视图更新周期），同步写 @Published 安全；
                // 曾改为 GCD 延迟——反而让 open() 落进表格布局中段，触发 reentrant + AG cycle 闪退
                set: { if let it = $0 { vm.open(it) } }
            )) {
                ForEach(vm.items) { item in
                    ArticleRow(item: item, isSelected: vm.selectedItem?.id == item.id,
                               isReadOverride: vm.readMarks[item.id],
                               scale: uiFontScale,
                               density: listDensity, showSource: listShowSource,
                               showDate: listShowDate, unreadBold: listUnreadBold,
                               dateFormat: listDateFormat)
                        .tag(item)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                        .contextMenu {
                            // ── 状态操作 ──
                            Button { vm.toggleRead(item) } label: {
                                Label(vm.effectiveIsRead(item) ? "标为未读" : "标为已读",
                                      systemImage: vm.effectiveIsRead(item) ? "envelope.badge" : "envelope.open")
                            }
                            Button { vm.toggleStar(item) } label: {
                                Label(item.starred ? "取消星标" : "加星标",
                                      systemImage: item.starred ? "star.slash" : "star")
                            }
                            Divider()

                            // ── 打开 / 复制 ──
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.url, forType: .string)
                            } label: {
                                Label("复制链接", systemImage: "link")
                            }
                            Button {
                                if let url = URL(string: item.url), !item.url.isEmpty {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Label("浏览器打开原文", systemImage: "safari")
                            }

                            Divider()

                            // ── 内容处理（AI 评分/摘要/翻译/转录）──
                            Menu {
                                Button {
                                    reprocessItem(item: item)
                                } label: {
                                    Label("重新处理", systemImage: "arrow.triangle.2.circlepath")
                                }
                                Divider()
                                Button {
                                    runPipelineForItem(item: item, type: "score")
                                } label: {
                                    Label("AI 评分", systemImage: "star")
                                }
                                Button {
                                    runPipelineForItem(item: item, type: "summarize")
                                } label: {
                                    Label("AI 摘要", systemImage: "text.quote")
                                }
                                // 翻译：文章翻正文；播客/视频翻简介（与转录对照独立）——统一命名「AI 翻译」
                                Button {
                                    runPipelineForItem(item: item, type: "translate")
                                } label: {
                                    Label("AI 翻译", systemImage: "character.bubble")
                                }
                                if item.ctype == "podcast" || item.ctype == "video" || item.audioUrl != nil {
                                    Button {
                                        runPipelineForItem(item: item, type: "transcribe")
                                    } label: {
                                        Label("AI 转录", systemImage: "waveform")
                                    }
                                }
                                if item.hasTranscript {
                                    Divider()
                                    Button {
                                        deleteTranscriptForItem(item: item)
                                    } label: {
                                        Label("删除转录稿", systemImage: "trash")
                                    }
                                }
                            } label: {
                                Label("内容处理", systemImage: "gearshape.2")
                            }
                            // 重新提取全文（单篇重提）
                            Button {
                                runPipelineForItem(item: item, type: "fulltext")
                            } label: {
                                Label("重新提取全文", systemImage: "arrow.triangle.2.circlepath")
                            }

                            // ── 后处理 ──
                            Button {
                                Task { _ = try? await services.export.forceExport(contentID: item.id) }
                            } label: {
                                Label("触发导出规则", systemImage: "square.and.arrow.up.on.square")
                            }

                        }
                        // 最后一行出现时自动加载下一页（滚动到底分页，打破 300 条上限）
                        .onAppear {
                            if item.id == vm.items.last?.id { vm.loadMore() }
                        }
                }
                if vm.hasMore {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .onAppear { vm.loadMore() }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: 右栏
    private var readingPane: some View {
        Group {
            if let item = vm.selectedItem {
                ReadingView(item: item, showTranslated: $vm.showTranslated,
                            library: services.library,
                            contentDetail: services.contentDetail,
                            processing: services.processing,
                            export: services.export,
                            onPrev: { vm.selectPrev() }, onNext: { vm.selectNext() })
                    .id(item.id)   // 切文章重建阅读视图；手动处理状态由 content id 共享 Store 恢复
            } else {
                ContentUnavailableView(
                    "选择一篇文章",
                    systemImage: "doc.text",
                    description: Text("共 \(vm.totalCount) 条内容")
                )
            }
        }
    }
}

// MARK: - 文章行

public struct ArticleRow: View {
    let item: ContentItem
    let isSelected: Bool
    /// 乐观已读覆盖（open() 点未读后由 vm.readMarks 传入——不碰 items 数据源）
    var isReadOverride: Bool? = nil
    /// 有效已读态（覆盖优先，其次 item 字段）
    private var isRead: Bool { isReadOverride ?? item.isRead }
    let scale: Double
    let density: String
    let showSource: Bool
    let showDate: Bool
    let unreadBold: Bool
    let dateFormat: String

    /// 紧凑密度下行距更紧。
    private var isCompact: Bool { density == "compact" }

    /// 平台图标以订阅源 stype 为准，不再用内容 ctype。RSS/Podcast 保留原有
    /// 语义图标；YouTube/BiliBili/微信用平台典型符号和低饱和品牌色。
    private var platformIcon: String? {
        switch platformType {
        case "podcast": return "mic.fill"
        case "youtube": return "play.rectangle.fill"
        case "bilibili": return "tv.fill"
        case "wechat": return "message.badge.filled.fill"
        default: return nil  // RSS 用自定义 RSSIcon 组件，不走 SF Symbol
        }
    }

    private var platformIconColor: Color {
        switch platformType {
        case "podcast": return .rbPodcast
        case "youtube": return .rbYouTube
        case "bilibili": return .rbBilibili
        case "wechat": return .rbWeChat
        default: return Color.rbText3
        }
    }

    /// 历史 content.source 不完全等于订阅源 stype（早期 podcast 条目曾写成 rss）。
    /// 优先用 LEFT JOIN 拿到的 content_source.stype；无源/旧数据再回落到 source。
    private var platformType: String {
        (item.sourceStype ?? item.source).lowercased()
    }

    private var isRSSPlatform: Bool {
        platformType == "rss" || platformType == "article"
    }

    /// 显示标题：媒体项优先标题译文（llm_title_translated）；否则有正文译文取 translatedHead 第一个非空行；都没有用原标题
    private var displayTitle: String {
        // 媒体项：标题译文（独立的 llm_title_translated 字段，不再靠 excerptTranslated 第一行猜）
        if let t = item.titleTranslated, !t.isEmpty {
            return t
        }
        guard let head = item.translatedHead, !head.isEmpty else {
            return item.title
        }
        // 跳过空行取第一个非空行（llm_translated_md 开头常是空行，第二行才是标题）
        let firstNonEmpty = head.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let cleaned = firstNonEmpty.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
        return cleaned.isEmpty ? item.title : cleaned
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 9) {
            // 未读点固定在整行最左侧并垂直居中；已读时保留槽位，正文不会左右跳。
            Circle()
                .fill(isRead ? Color.clear : Color.rbAccent)
                .frame(width: 6, height: 6)
                .frame(width: 8)

            VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
                // 第一行：标题 + 星标
                HStack(alignment: .top, spacing: 6) {
                    Text(displayTitle)
                        .font(.system(size: RB.F.rowTitle * scale, weight: (unreadBold && !isRead) ? .semibold : .regular))
                        // 系统 List 高亮在窗口活跃/非活跃时都会压暗背景；选中标题固定用
                        // 浅灰，避免已读项继续沿用 rbText2 后与高亮底混在一起。
                        .foregroundStyle(isSelected ? Color.white.opacity(0.82) : (isRead ? Color.rbText2 : Color.rbText))
                        .lineLimit(isCompact ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.starred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(Color.rbStar)
                            .font(.system(size: 11 * scale))
                    }
                    Spacer(minLength: 0)
                }

                // 第二行：平台图标 + 订阅源名称 + 时间
                HStack(spacing: 6) {
                    if isRSSPlatform {
                        RSSIcon(size: 11, color: .rbRSS)
                    } else if let icon = platformIcon {
                        Image(systemName: icon)
                            .font(.system(size: 11))
                            .foregroundStyle(platformIconColor)
                    }
                    if showSource {
                        Text(item.sourceName ?? item.source)
                            .font(.system(size: RB.F.rowMeta * scale))
                            .foregroundStyle(Color.rbText3)
                            .lineLimit(1)
                    }
                    if showSource, showDate, item.publishedAt != nil {
                        Text("·").foregroundStyle(Color.rbText3)
                    }
                    if showDate, let pd = item.publishedAt, pd.count >= 10 {
                        Text(formattedDate(pd))
                            .font(.system(size: RB.F.rowMeta * scale))
                            .foregroundStyle(Color.rbText3)
                    }
                    Spacer(minLength: 0)
                }

                // 第三行：加工状态；已导出与前五项分开并固定靠右。
                HStack(spacing: 6) {
                    if let accessBadge {
                        RBadge(text: accessBadge.text, color: accessBadge.color, scale: scale)
                    }
                    if item.ctype != "podcast", item.hasFulltext {
                        RBadge(text: "全文", color: .rbScoreHigh, scale: scale)
                    }
                    if let s = item.llmScore {
                        Text("评分 \(s)")
                            .font(.system(size: RB.F.badge * scale, weight: .medium))
                            .foregroundStyle(scoreColor(s))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(scoreColor(s).opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: RB.Radius.sm))
                            .overlay(
                                RoundedRectangle(cornerRadius: RB.Radius.sm)
                                    .strokeBorder(scoreColor(s).opacity(0.22), lineWidth: RB.Line.hair)
                            )
                    }
                    if let sum = item.llmSummary, !sum.isEmpty {
                        RBadge(text: "摘要", color: .rbSummary, scale: scale)
                    }
                    if item.hasTranslation {
                        RBadge(text: "翻译", color: .rbTranslate, scale: scale)
                    }
                    if item.isMedia && item.hasTranscript {
                        RBadge(text: "转录", color: .rbSummary, scale: scale)
                    }
                    Spacer(minLength: 8)
                    if item.hasExport {
                        RBadge(text: "已导出", color: .rbAccent, scale: scale)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isCompact ? 4 : 8)
        .contentShape(Rectangle())
        .rbSelection(isSelected, radius: RB.Radius.lg)
    }

    /// 日期格式：relative=相对（x 分钟/小时/天前）/ absolute=绝对（yyyy-MM-dd）
    private func formattedDate(_ publishedAt: String) -> String {
        if dateFormat == "relative" {
            return Self.relativeDate(from: publishedAt)
        }
        return String(publishedAt.prefix(10))
    }

    private var accessBadge: (text: String, color: Color)? {
        switch item.accessState {
        case "paidPreview": return ("单片付费", .rbScoreLow)
        case "paidSeason": return ("付费合集", .rbScoreLow)
        case "upowerExclusive": return ("充电专属", .rbScoreMid)
        case "upowerEarlyAccess": return ("充电抢先看", .rbScoreMid)
        case "loginRequired": return ("需登录", .rbText2)
        default: return nil
        }
    }

    /// 相对时间（ISO8601 → x 分钟/小时/天前）
    nonisolated static func relativeDate(from iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = f.date(from: iso)
        if date == nil {
            f.formatOptions = [.withInternetDateTime]
            date = f.date(from: iso)
        }
        guard let d = date else { return String(iso.prefix(10)) }
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "刚刚" }
        if secs < 3600 { return "\(secs / 60) 分钟前" }
        if secs < 86400 { return "\(secs / 3600) 小时前" }
        if secs < 86400 * 7 { return "\(secs / 86400) 天前" }
        return String(iso.prefix(10))
    }

    /// 评分颜色分段（降饱和语义色）：90+ 灰绿 / 75-84 墨蓝 / 60-74 赭 / 1-59 砖红 / 0 灰
    private func scoreColor(_ s: Int) -> Color {
        switch s {
        case 90...: return .rbScoreHigh
        case 75..<90: return .rbScoreGood
        case 60..<75: return .rbScoreMid
        case 1..<60: return .rbScoreLow
        default: return .rbScoreNone   // 0 分
        }
    }
}

// MARK: - 阅读区

/// 阅读器版面设置（持久化 UserDefaults）
struct ReadingLayout {
    static var fontSize: Double {
        get { let v = UserDefaults.standard.double(forKey: "reading.fontSize"); return v > 0 ? v : 16 }
        set { UserDefaults.standard.set(newValue, forKey: "reading.fontSize") }
    }
    static var lineSpacing: Double {
        get { let v = UserDefaults.standard.double(forKey: "reading.lineSpacing"); return v > 0 ? v : 6 }
        set { UserDefaults.standard.set(newValue, forKey: "reading.lineSpacing") }
    }
    static var contentWidth: Double {   // 最大内容宽度
        get { let v = UserDefaults.standard.double(forKey: "reading.contentWidth"); return v > 0 ? v : 720 }
        set { UserDefaults.standard.set(newValue, forKey: "reading.contentWidth") }
    }
    // 分块字号（不跟正文走——标题/元信息/摘要独立，解决"标题比正文还小"）
    static var titleFontSize: Double {
        get { let v = UserDefaults.standard.double(forKey: "reading.titleFontSize"); return v > 0 ? v : 24 }
        set { UserDefaults.standard.set(newValue, forKey: "reading.titleFontSize") }
    }
    static var metaFontSize: Double {
        get { let v = UserDefaults.standard.double(forKey: "reading.metaFontSize"); return v > 0 ? v : 12 }
        set { UserDefaults.standard.set(newValue, forKey: "reading.metaFontSize") }
    }
    static var summaryFontSize: Double {
        get { let v = UserDefaults.standard.double(forKey: "reading.summaryFontSize"); return v > 0 ? v : 14 }
        set { UserDefaults.standard.set(newValue, forKey: "reading.summaryFontSize") }
    }
    /// 界面字体大小（左栏源名/中栏列表/操作条，独立于阅读正文）
    static var uiFontScale: Double {
        get { let v = UserDefaults.standard.double(forKey: "reading.uiFontScale"); return v > 0 ? v : 1.0 }
        set { UserDefaults.standard.set(newValue, forKey: "reading.uiFontScale") }
    }

    // MARK: 文章列表外观（常见 RSS 阅读器设置项）

    /// 摘要显示行数（0 = 不显示摘要）
    static var excerptLines: Int {
        get { UserDefaults.standard.object(forKey: "list.excerptLines") as? Int ?? 2 }
        set { UserDefaults.standard.set(newValue, forKey: "list.excerptLines") }
    }
    /// 列表密度：compact=紧凑 / comfortable=舒适（默认）
    static var listDensity: String {
        get { UserDefaults.standard.string(forKey: "list.density") ?? "comfortable" }
        set { UserDefaults.standard.set(newValue, forKey: "list.density") }
    }
    /// 列表是否显示来源名
    static var showSource: Bool {
        get { UserDefaults.standard.object(forKey: "list.showSource") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "list.showSource") }
    }
    /// 列表是否显示日期
    static var showDate: Bool {
        get { UserDefaults.standard.object(forKey: "list.showDate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "list.showDate") }
    }
    /// 未读文章标题是否加粗（视觉区分已读/未读）
    static var unreadBold: Bool {
        get { UserDefaults.standard.object(forKey: "list.unreadBold") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "list.unreadBold") }
    }
    /// 日期格式：relative=相对（x 分钟前）/ absolute=绝对（yyyy-MM-dd）
    static var dateFormat: String {
        get { UserDefaults.standard.string(forKey: "list.dateFormat") ?? "absolute" }
        set { UserDefaults.standard.set(newValue, forKey: "list.dateFormat") }
    }
}

public struct ReadingView: View {
    let item: ContentItem
    @Binding var showTranslated: Bool
    private let library: any LibraryGateway
    private let contentDetail: any ContentDetailGateway
    private let processing: any ProcessingGateway
    private let export: any ExportGateway
    /// 上一篇/下一篇导航回调（阅读区顶部按钮，键盘 j/k 的图形化对应）
    var onPrev: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil

    @State private var llmAvailable = false  // 在 onAppear 中赋值，避免 body 渲染时调 isAvailable→SecretStore 递归锁崩溃
    @ObservedObject private var processingStates = ContentProcessingStateStore.shared
    /// 媒体项（播客/视频）正文标签：0=原文(简介) / 1=译文(简介翻译) / 2=转录(中英对照)
    /// @AppStorage 持久化——记住上次读的标签，切文章不重置（和 viewMode 同模式）
    @AppStorage("reading.mediaTab") private var mediaTab = 0
    /// 版面设置（@AppStorage 直绑——设置面板/阅读器设置页改这里视图自动刷新，
    /// 不再像 @State 静态读 UserDefaults 只在创建读一次。和 uiFontScale 同模式）
    @AppStorage("reading.fontSize") private var fontSize: Double = 16
    @AppStorage("reading.lineSpacing") private var lineSpacing: Double = 6
    @AppStorage("reading.contentWidth") private var contentWidth: Double = 720
    @AppStorage("reading.theme") private var themeRaw: String = "claude"
    @AppStorage("reading.themeMode") private var themeModeRaw: String = "system"
    @AppStorage("reading.font") private var fontRaw: String = "system"
    @AppStorage("reading.titleFontSize") private var titleFontSize: Double = 24
    @AppStorage("reading.metaFontSize") private var metaFontSize: Double = 12
    @AppStorage("reading.summaryFontSize") private var summaryFontSize: Double = 14
    /// 界面缩放（@AppStorage 直绑——layoutPanel 里改这里视图自动刷新，
    /// 同时 ContentView/ArticleRow 的同名 @AppStorage 也会跟着重建，全局生效）
    @AppStorage("reading.uiFontScale") private var uiFontScale: Double = 1.0
    @State private var showLayoutPopover = false
    @State private var showShareSheet = false
    /// 正文 frontmatter 块是否展开（默认收起，记住状态）
    @AppStorage("reading.metaExpanded") private var metaExpanded: Bool = false
    /// 星标/已读状态（本地镜像，操作后即时反馈，不依赖 reload）
    @State private var isStarred = false
    @State private var isRead = false

    init(
        item: ContentItem,
        showTranslated: Binding<Bool>,
        library: any LibraryGateway,
        contentDetail: any ContentDetailGateway,
        processing: any ProcessingGateway,
        export: any ExportGateway,
        onPrev: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil
    ) {
        self.item = item
        _showTranslated = showTranslated
        self.library = library
        self.contentDetail = contentDetail
        self.processing = processing
        self.export = export
        self.onPrev = onPrev
        self.onNext = onNext
    }

    /// theme/themeMode/fontChoice 从 raw 键派生（@AppStorage 存 String rawValue）
    private var theme: ReadingTheme {
        get { ReadingTheme(rawValue: themeRaw) ?? .claude }
        nonmutating set { themeRaw = newValue.rawValue }
    }
    private var themeMode: ReadingTheme.Mode {
        get { ReadingTheme.Mode(rawValue: themeModeRaw) ?? .light }
        nonmutating set { themeModeRaw = newValue.rawValue }
    }
    private var fontChoice: ReadingFont {
        get {
            if fontRaw.hasPrefix("custom:") { return .custom(String(fontRaw.dropFirst(7))) }
            switch fontRaw {
            case "heiti": return .heiti
            case "kaiti": return .kaiti
            case "fangsong": return .fangsong
            default: return .system
            }
        }
        nonmutating set {
            switch newValue {
            case .system: fontRaw = "system"
            case .heiti: fontRaw = "heiti"
            case .kaiti: fontRaw = "kaiti"
            case .fangsong: fontRaw = "fangsong"
            case .custom(let n): fontRaw = "custom:\(n)"
            }
        }
    }

    public var body: some View {
        fullBody
    }

    private var processingState: ContentProcessingStateStore.Entry? {
        processingStates.state(for: item.id)
    }

    private var busy: Bool { processingState?.isProcessing == true }
    private var statusMsg: String? { processingState?.message }

    private var fullBody: some View {
        VStack(spacing: 0) {
            // ── 顶部操作条：左右操作槽等宽，文稿标签占满中间区域并保持整体居中。──
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    // 快捷操作簇（统一 15pt + frame 24×24 对齐，SF Symbol 视觉大小归一）
                    Button { toggleStar() } label: {
                        Image(systemName: isStarred ? "star.fill" : "star")
                            .font(.system(size: 15, weight: .regular))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(isStarred ? Color.rbStar : Color.rbText2)
                    }
                    .buttonStyle(.staticQuiet)
                    .help(isStarred ? "取消星标" : "加星标")

                    Button { toggleRead() } label: {
                        Image(systemName: isRead ? "envelope.open" : "envelope")
                            .font(.system(size: 15, weight: .regular))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(Color.rbText2)
                    }
                    .buttonStyle(.staticQuiet)
                    .help(isRead ? "标为未读" : "标为已读")

                    Button { showShareSheet = true } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .regular))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(Color.rbText2)
                    }
                    .buttonStyle(.staticQuiet)
                    .help("分享 / 后处理")
                }
                .frame(width: 76, alignment: .leading)

                // 视图切换：非媒体项「译文/原文」两段；媒体项「原文/译文/转录」三段（同一组件同一位置）
                if isMediaItem {
                    // 媒体标签分别由各自字段决定：译文看 llm_translated_md，
                    // 转录看 llm_transcript_md；二者互不作为对方的显示条件。
                    RBSegmented(
                        items: mediaTabItems,
                        selection: mediaTabSelection,
                        fillsAvailableWidth: false
                    )
                    .frame(maxWidth: .infinity)
                // ⚠️ 切标签"点了没反应"根治（09:21 用户直觉定位：在等通知但通知没给到，是个低级问题）：
                // 原判断 `!= nil` —— llm_translated_md=0KB 的文章 loadedTranslatedMd 是**空字符串 ""（非 nil）**，
                // `!= nil` 通过 → 标签显示"译文/原文"；但正文 hasTranslated 判断是 `!$0.isEmpty`，
                // 空串 → false → 正文只渲染原文 → 点"译文"画面不变（你以为没识别，其实是没内容可切）。
                // 修复：标签显示条件与正文一致——译文**非空**才显示切换标签。
                } else if translatedText != nil {
                    RBSegmented(
                        items: [(0, "译文"), (1, "原文")],
                        selection: $viewMode,
                        fillsAvailableWidth: false
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    Spacer(minLength: 0)
                }

                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    // 明确显示 Aa 字标；不再沿用此前没有产生视觉变化的 textformat 图标。
                    Button { showLayoutPopover = true } label: {
                        Text("Aa")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(Color.rbText2)
                    }
                    .buttonStyle(.staticQuiet)
                    .help("阅读器设置")
                    .popover(isPresented: $showLayoutPopover, arrowEdge: .bottom) {
                        layoutPanel
                    }
                }
                .frame(width: 76, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.rbBg)   // 弃 .bar 材质（实时模糊有开销）改纯色更干净

            Hairline()

            // ── 正文滚动区 ──
            // ⚠️ 切标签「不上屏」的稳定兜底：标签键挂 ScrollView，切标签 = 重建滚动区。
            // （上游「视图更新中发布」根因已修——见 ContentViewModel.init；但重建路径已被
            // 多轮实测确认可靠，先保留。后续验证就地更新稳定后可移除以保留滚动位置。）
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 原生 NSTextView 同时处理拖选、单击和 pointing-hand cursor rect。
                    SelectableLinkTitle(
                        text: item.title,
                        destination: item.url,
                        font: fontChoice.nsFont(size: titleFontSize, bold: true),
                        normalColor: NSColor(p.text),
                        hoverColor: NSColor(Color.rbAccent.opacity(0.88))
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("点击在浏览器打开原文")
                    // 中文标题（有译文时显示在英文标题下方——从 translatedHead 第一行取）
                    if let chineseTitle = chineseTitle, chineseTitle != item.title {
                        Text(chineseTitle)
                            .font(fontChoice.font(size: titleFontSize * 0.75).weight(.medium))
                            .foregroundStyle(p.textSecondary)
                            .textSelection(.enabled)
                    }
                    // 元信息（类型图标 + 源名称 · 作者 · 日期 · 评分）
                    if !metaParts.isEmpty {
                        HStack(spacing: 6) {
                            let ctype = item.ctype
                            if ctype == "podcast" {
                                Image(systemName: "mic.fill")
                                    .foregroundStyle(Color.rbPodcast)
                            } else if ctype == "video" || ctype == "youtube" {
                                Image(systemName: "play.rectangle.fill")
                                    .foregroundStyle(Color.rbVideo)
                            } else if ctype != "wechat" && ctype != "social" {
                                RSSIcon(size: metaFontSize, color: .rbRSS)
                            }
                            Text(metaParts.joined(separator: "  ·  "))
                        }
                        .font(.system(size: metaFontSize))
                        .foregroundStyle(p.textSecondary)
                    }

                    // ── 媒体播放器（固定顶部——切标签不动）──
                    // 播客：音频播放器（loadedAudioUrl 判据，见下注释）。
                    // YouTube/视频：视频播放器（loadedVideoId 判据，从 meta.video_id 回填）。
                    // ⚠️ 判据用 loadedAudioUrl/loadedVideoId 而非 item.audioUrl/videoId：
                    // 轻列查询不取媒体地址（Database.swift:993 写死"媒体地址点开再查"），
                    // item 上这两个字段恒 nil；loaded* 在 onAppear 的 loadContentMd() 里从
                    // fetchContentBody 同步回填（与 loadedContentMd 同构，安全不替换 item）。
                    if item.ctype == "podcast", let audioUrl = loadedAudioUrl, !audioUrl.isEmpty {
                        AudioPlayerView(audioUrl: audioUrl, title: item.title)
                            .padding(.vertical, 4)
                    } else if (item.ctype == "video" || item.ctype == "youtube"),
                              let vid = loadedVideoId, !vid.isEmpty {
                        switch VideoPlayerPlatform.resolve(source: item.source) {
                        case .bilibili:
                            BilibiliPlayerView(bvid: vid, title: item.title, pageURL: item.url)
                                .padding(.vertical, 4)
                        case .youtube:
                            YouTubePlayerView(videoId: vid, title: item.title)
                                .padding(.vertical, 4)
                        }
                    }

                    // ── LLM 操作条（胶囊按钮组 + 状态提示，精致排版）──
                    // 这套是阅读器唯一的操作按钮组（右上角已只留格式）。
                    // 所有按钮都是单篇手动操作/重操作，不受文件夹/订阅源自动开关限制。
                    HStack(spacing: 8) {
                        // 提取全文：不需 LLM，任何项都可点（抓正文/重抓）
                        StaticCapsuleButton(title: "提取全文", icon: "doc.text", disabled: busy) { runFulltext() }
                        // 内容处理：按源开关重新跑已开启管线（一次点击跑全部）
                        StaticCapsuleButton(title: "内容处理", icon: "gearshape.2", disabled: busy) {
                            reprocessFromReadingView()
                        }
                        if llmAvailable {
                            // 评分/摘要/翻译按钮：均始终显示，已有结果也可重新执行
                            StaticCapsuleButton(title: "AI 评分", icon: "star", disabled: busy) { runScore() }
                            StaticCapsuleButton(title: "AI 摘要", icon: "text.quote", disabled: busy) { runSummarize() }
                            StaticCapsuleButton(title: "AI 翻译", icon: "character.bubble", disabled: busy) { runTranslate() }
                        }
                        // AI 转录：媒体项始终显示（放最后）；已有转录稿也显示（可重新转录）
                        if isMediaItem {
                            StaticCapsuleButton(title: "AI 转录", icon: "waveform", disabled: busy) { runTranscribe() }
                        }
                        // 所有状态统一位于最后一个操作按钮右侧。
                        if busy {
                            ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                        }
                        if let msg = statusMsg {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(msg.contains("失败") ? Color.rbScoreLow : Color.rbText3)
                                .lineLimit(1)
                                .help(msg)
                        } else if !llmAvailable, !isMediaItem {
                            Label("未配置 LLM Key", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(Color.rbScoreLow)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)

                    Hairline()

                    // 摘要（灰紫缘引用卡：独立字号设置；effectiveSummary 镜像优先——AI 完成后即刻上屏）
                    if let sum = effectiveSummary, !sum.isEmpty {
                        Text(sum)
                            .font(.system(size: summaryFontSize))
                            .foregroundStyle(p.textSecondary)
                            .lineSpacing(3)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(p.backgroundAlt)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.rbSummary.opacity(0.85))
                                    .frame(width: 3)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
                    }

                    // 正文：媒体项按三标签渲染，非媒体项统一用 MarkdownBodyView。
                    // ⚠️ 关键修复：原代码用三分支（if isMediaItem / else if viewMode==0 let translated / else），
                    // 当 loadBodyIfNeeded 异步填回 item.llmTranslatedMd（nil→有值）时，
                    // 条件分支从"原文"切换到"译文" → VStack 子视图结构在布局期间变化 →
                    // StackLayout.makeChildren → use-after-free 崩溃。
                    // 修复：非媒体项统一渲染 MarkdownBodyView(displayMd)，用计算属性选择译文/原文内容。
                    // item 字段异步变化只改 markdown 参数值，不改子视图类型/数量，布局安全。
                    if isMediaItem {
                        mediaBodyView
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // 正文渲染：f269c64 稳定设计（后台解析 + @State 写回，详见 ReadingTheme.swift 注释）。
                        // 切标签秒切由两层保证：① 通知回调改 GCD（视图更新中发布根因已除）；
                        // ② ScrollView 随标签重建（实测确认的稳定路径，代价是滚动位置回顶）。
                        MarkdownBodyView(
                            markdown: displayMd,
                            theme: theme, mode: themeMode, fontChoice: fontChoice,
                            fontSize: fontSize, lineSpacing: lineSpacing
                        )
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: contentWidth)
                .frame(maxWidth: .infinity)   // 内容限宽后居中
            }
            // 切标签连同 ScrollView 一起重建（实测确认的稳定路径，代价是滚动位置回顶）
            .id("reading-body-\(viewMode)-\(effectiveMediaTab)")
            .background(p.background)   // 主题底色
        }
        // 视图随 .id(item.id) 重建，onAppear 即切文章——刷新有效开关与本地状态
        .onAppear {
            Trace.i("ReadingView.onAppear id=\(item.id) ctype=\(item.ctype) 已有contentMd=\(item.contentMd != nil) llmTranslatedMd非空=\(item.llmTranslatedMd != nil) mem=\(Trace.mb())MB [\(buildTag)]", category: "read")
            Trace.startMemorySampler(category: "read.mem")
            Task {
                llmAvailable = await processing.capabilities().llmAvailable
            }
            isStarred = item.starred
            isRead = item.isRead
        }
        // 正文、译文、转录、评分、摘要和源策略一次后台读取；不再在 onAppear 主线程查两遍 DB。
        .task(id: item.id) { await loadContentMd() }
        .onChange(of: processingState?.isProcessing) { wasProcessing, isProcessing in
            if wasProcessing == true, isProcessing == false {
                refreshLoadedBody()
            }
        }
        .onDisappear {
            Trace.i("ReadingView.onDisappear id=\(item.id) mem=\(Trace.mb())MB", category: "read")
            Trace.stopMemorySampler(category: "read.mem")
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(item: item, export: export)
        }
    }

    /// 元信息片段（作者/日期/评分）——编辑部点分隔风格，有则收集
    private var metaParts: [String] {
        var parts: [String] = []
        if let sn = item.sourceName, !sn.isEmpty { parts.append(sn) }
        if let a = item.author, !a.isEmpty { parts.append(a) }
        if let pd = item.publishedAt { parts.append(String(pd.prefix(10))) }
        if let s = effectiveScore { parts.append("评分 \(s)") }
        return parts
    }

    /// 右上角直接复用设置页完整的阅读器设置，避免两处配置项和取值范围再次分叉。
    private var layoutPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("阅读器设置")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.rbText)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ReaderPane()
        }
        .frame(width: 480, height: 620)
    }

    // MARK: 快捷操作（本地即时反馈 + 通知列表刷新）

    private func toggleStar() {
        let target = !isStarred
        isStarred = target
        let contentID = item.id
        Task {
            do {
                _ = try await library.setStarred(contentID: contentID, isStarred: target)
                NotificationCenter.default.post(name: .contentUpdated, object: nil)
            } catch {
                // 快速连续点击时，只撤销仍与本次请求目标一致的乐观状态。
                if isStarred == target { isStarred = !target }
            }
        }
    }

    private func toggleRead() {
        let targetRead = !isRead
        isRead = targetRead
        let contentID = item.id
        Task {
            do {
                _ = try await library.setRead(contentID: contentID, isRead: targetRead)
                // 写入确认后再通知列表刷新，避免 observer 读到旧状态。
                NotificationCenter.default.post(name: .contentUpdated, object: nil)
            } catch {
                if isRead == targetRead { isRead = !targetRead }
            }
        }
    }

    /// 正文视图模式：0=双语对照 / 1=仅原文 / 2=仅译文。
    /// @AppStorage 持久化——你的选择记住，切文章/重启不重置。默认双语对照（Follo 风格）。
    /// ⚠️ 09:23 实测：@State 和 @AppStorage 都复现"点两次才切"，证明延迟不在存储层。
    /// 真正机制：自定义 Binding 的 set 在 onTapGesture 回调里改 @State，若同一 runloop body 已求值过，
    /// 这次变更被合并到下一次 body 求值 → 第一次点击没立即重绘，第二次点击又触发 body 才带出。
    /// 改回 @AppStorage 直绑（系统保证读写同步、立即触发 body），去掉自定义 Binding 中间层。
    @AppStorage("reading.viewMode") private var viewMode: Int = 0
    /// 构建标记——验证部署版本用（启动 onAppear 打日志，确认跑的是不是含此标记的新二进制）
    private let buildTag = "BUILD_1637_crypto_fix"

    /// 双语对照模式（viewMode=0 且有译文）
    private var bilingualMode: Bool {
        viewMode == 0 && item.llmTranslatedMd != nil
    }

    private var bodyText: String {
        // 双语/仅原文：优先原文 md（contentMd ?? excerpt）
        if let md = loadedContentMd, !md.isEmpty { return md }
        if let md = item.contentMd, !md.isEmpty { return md }
        return item.excerpt ?? "(无内容)"
    }

    /// 正文渲染用 markdown：viewMode 0 优先译文，viewMode 1 或无译文用原文。
    /// ⚠️ 09:36 用户定位「点原文秒切、点译文要等；播客切换不卡」→ 根因是译文走 @State 依赖链。
    /// 播客译文直接读 item.llmTranslatedMd（let 属性，同步确定）→ 秒切；
    /// RSS 译文走 loadedTranslatedMd(@State) → 与刚变的 viewMode 同帧快照错位 → 第一次求值不一致。
    /// 对齐播客：译文**优先读 item.llmTranslatedMd**（读 let 属性安全，崩溃是"异步替换 selectedItem"
    /// 导致的，读属性不触发），@State loadedTranslatedMd 仅作 item 无译文时的兜底。
    /// 译文文本——同步、确定，与播客读 item 字段等价。
    /// 不走 @State（@State 写入有"延迟一帧提交"语义，与 viewMode 变更同帧快照错位 → 点译文要等）。
    /// 改为 body 求值时同步查 DB（fetchContentBody 实测 0ms），随取随用，与 viewMode 变更同帧一致。
    /// 列表是轻列 item.llmTranslatedMd=nil，译文只能查 DB；用 memo 字典按 id 缓存避免重复查。
    private var translatedText: String? {
        // ⚠️ 只读 @State 镜像，绝不在 body 求值里查 DB（16:03 定案）：
        // 09:36 加的「body 求值时同步 fetchContentBody 兜底」让每次求值都跑 1~3 次 SQL
        // （标签条件/displayMd/chineseTitle），每开一篇文章 ~10 次求值 = 几十次主线程查询
        // + 几十条 dblock 日志——渲染成本爆炸，快速连点时 AG 更新相互踩踏 → cycle → 闪退。
        // 「@State 延迟一帧」当年看似要等，根因是通知回调"视图更新中发布"丢帧（已根治），
        // 现在镜像写入后一帧即上屏，不需要 DB 兜底。
        if let t = loadedTranslatedMd, !t.isEmpty { return t }
        return nil
    }

    private var displayMd: String {
        if viewMode == 0, let t = translatedText { return t }
        return bodyText
    }

    /// 是否媒体项（播客/视频，可转录）
    private var isMediaItem: Bool {
        item.ctype == "podcast" || item.ctype == "video" || item.ctype == "youtube" || item.audioUrl != nil
    }

    // MARK: 媒体项三标签（原文/译文/转录）

    /// 媒体标签动态组合：原文始终存在，译文和转录分别检查自己的字段。
    private var mediaTabItems: [(Int, String)] {
        Self.mediaTabOptions(hasTranslation: translatedText != nil, hasTranscript: hasTranscript)
    }

    /// 纯逻辑入口，供回归测试验证四种译文/转录组合。
    nonisolated static func mediaTabOptions(hasTranslation: Bool, hasTranscript: Bool) -> [(Int, String)] {
        var tabs: [(Int, String)] = [(0, "原文")]
        if hasTranslation { tabs.append((1, "译文")) }
        if hasTranscript { tabs.append((2, "转录")) }
        return tabs
    }

    private var hasTranscript: Bool {
        guard let text = loadedTranscriptMd else { return false }
        return !text.isEmpty
    }

    /// mediaTab 用 @AppStorage 记住上次选择；切到不具备该内容的媒体时安全回退原文。
    private var effectiveMediaTab: Int {
        mediaTabItems.contains(where: { $0.0 == mediaTab }) ? mediaTab : 0
    }

    private var mediaTabSelection: Binding<Int> {
        Binding(
            get: { effectiveMediaTab },
            set: { mediaTab = $0 }
        )
    }

    /// feed 简介原文（excerpt 已是剥标签纯文本——播客简介存摘要字段；兜底 content_html 剥标签兼容旧数据）
    private var excerptPlainText: String {
        if let ex = item.excerpt, !ex.isEmpty { return ex }
        let html = item.contentHtml ?? ""
        guard !html.isEmpty else { return "(无简介)" }
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "(无简介)" : text
    }

    /// 媒体项正文（按 mediaTab 渲染对应内容；无转录稿时 mediaTab=2 钳制回原文）
    /// ⚠️ 与 RSS 正文同一根治：原实现 @ViewBuilder switch 三分支（Text / MarkdownBodyView 混用），
    /// 切标签 = 换分支 = 子树换类型重建 → 与 .id 相同的「首次渲染被推迟」隐患。
    /// 改为计算属性出 markdown + 单一 MarkdownBodyView（身份稳定，就地更新，同事务上屏）。
    private var mediaBodyMarkdown: String {
        switch effectiveMediaTab {
        case 0:
            // 原文：defuddle 抓到的全文（content_md），兜底 feed 简介
            if let md = loadedContentMd, !md.isEmpty { return md }
            return excerptPlainText
        case 1:
            // 译文：全文/简介翻译（llm_translated_md），与转录稿字段彼此独立。
            // 原用 effectiveExcerptTranslated（简介翻译 llm_excerpt_translated），
            // 但翻译全文（translate）只写 llm_translated_md 不写 llm_excerpt_translated，
            // 导致简介翻译永远空 → 「译文」标签永远「尚无译文」。
            if let t = translatedText { return t }
            return "尚无译文——点「翻译」生成中英对照译稿"
        default:
            // 转录：Whisper 转录稿（llm_transcript_md），独立于翻译稿
            if let t = loadedTranscriptMd, !t.isEmpty { return t }
            return "尚无转录稿——点「转录」生成中英文对照稿"
        }
    }

    @ViewBuilder
    private var mediaBodyView: some View {
        MarkdownBodyView(markdown: mediaBodyMarkdown, theme: theme, mode: themeMode, fontChoice: fontChoice,
                         fontSize: fontSize, lineSpacing: lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 中文标题：统一优先读 llm_title_translated（所有类型），
    /// null 时回退到译文正文首行提取（兼容旧翻译）。

    /// 中文标题（统一读 llm_title_translated，null 时回退译文首行提取）
    private var chineseTitle: String? {
        // 优先 llm_title_translated（所有类型统一——translate()/translateExcerpt() 都写这列）
        if let t = effectiveTitleTranslated, !t.isEmpty { return t }
        // 兜底：旧翻译 llm_title_translated 为空 → 从译文正文首行提取
        guard let translated = translatedText else { return nil }
        let firstNonEmpty = translated.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var cleaned = firstNonEmpty.replacingOccurrences(of: "^标题：\\s*", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 当前 palette（按 themeMode 取——亮/暗切换即时生效）
    private var p: ThemePalette { theme.palette(for: themeMode) }

    // MARK: - LLM 操作

    /// AI 评分/翻译用的正文：优先 Markdown，退回 excerpt
    /// 正文内容——@State 缓存，打开时按 id 查 content_md（列表查询不取 content_md，
    /// selectedItem.contentMd 为 nil 导致 contentBody 用 excerpt 闪烁）
    @State private var loadedContentMd: String? = nil
    /// 译文（@State 缓存）——从 loadContentMd 同步加载（onAppear 时查 DB，<1ms）。
    /// 原来由 ContentViewModel.loadBodyIfNeeded 异步填回 selectedItem，但替换 selectedItem 实例
    /// 会导致 ReadingView 条件分支在布局期间切换 → use-after-free 崩溃。
    /// 改为 @State 后：onAppear 同步查 DB 填回 → displayMd 值变（但子视图结构不变）→ 安全。
    @State private var loadedTranslatedMd: String? = nil
    /// 标题译文镜像（中文标题用）——item 是轻列实例，列表查询不取，镜像从 fetchContentBody 补齐。
    @State private var loadedTitleTranslated: String? = nil
    /// 评分/摘要镜像（AI 完成后自动上屏用）——selectedItem 实例刻意不替换（会诱发
    /// AttributeGraph 无限重绘循环，12:10 hang 实锤），item 里的这两字段永远是打开时的旧值。
    @State private var loadedScore: Int? = nil
    @State private var loadedSummary: String? = nil
    /// 音频地址镜像（媒体项播放器用）——轻列查询不取 audio_url（Database.swift:993 写死
    /// "媒体地址点开再查"），item.audioUrl 恒为 nil。此处从 fetchContentBody 同步回填，
    /// 让 AudioPlayerView 的渲染判据成立。与 loadedContentMd 同构：onAppear 同步查、不替换 item。
    @State private var loadedAudioUrl: String? = nil
    /// 视频 id 镜像（YouTube 播放器用）——meta.video_id 同属"大字段点开再查"，
    /// 轻列 item 不含。从 fetchContentBody 第 7 元组回填，让 YouTubePlayerView 渲染判据成立。
    @State private var loadedVideoId: String? = nil
    /// 转录稿镜像（llm_transcript_md）。独立于翻译稿，供「转录」标签使用。
    @State private var loadedTranscriptMd: String? = nil
    @State private var readerPayloadLoaded = false

    /// 镜像优先的有效值（镜像未就绪时回退 item 字段）
    private var effectiveTitleTranslated: String? { loadedTitleTranslated ?? item.titleTranslated }
    private var effectiveScore: Int? { loadedScore ?? item.llmScore }
    private var effectiveSummary: String? { loadedSummary ?? item.llmSummary }

    /// 打开时从阅读器专用连接一次加载所有所需字段，不受列表/Worker 长查询占用。
    @MainActor
    private func loadContentMd() async {
        guard !readerPayloadLoaded else { return }
        let t0 = Date()
        let contentId = item.id
        do {
            let detail = try await contentDetail.detail(contentID: contentId)
            guard !Task.isCancelled else { return }
            readerPayloadLoaded = true
            apply(detail)
            let mdKb = (detail.contentMarkdown ?? "").count / 1024
            let transKb = (detail.translatedMarkdown ?? "").count / 1024
            Trace.i("阅读数据加载完成 id=\(item.id) content_md=\(mdKb)KB llm_translated_md=\(transKb)KB 用时=\(Int(t0.timeIntervalSinceNow * -1000))ms mem=\(Trace.mb())MB", category: "read")
        } catch {
            guard !Task.isCancelled else { return }
            readerPayloadLoaded = true
            Trace.w("阅读数据加载失败 id=\(item.id)：\(error.localizedDescription)", category: "read")
        }
    }

    /// LLM 任务完成后重查全部镜像（item 实例刻意不替换，新鲜度全走镜像/DB 兜底——
    /// 翻译/摘要/评分/转录完成后 译文标题、摘要卡、评分标、标签入口 即刻自动上屏）
    private func refreshLoadedBody() {
        let contentId = item.id
        Task { @MainActor in
            guard let detail = try? await contentDetail.detail(contentID: contentId),
                  contentId == item.id else { return }
            apply(detail)
        }
    }

    private func apply(_ detail: ContentDetail) {
        loadedContentMd = detail.contentMarkdown
        loadedTranslatedMd = detail.translatedMarkdown
        loadedTitleTranslated = detail.translatedTitle
        loadedAudioUrl = detail.audioURL
        loadedVideoId = detail.videoID
        loadedTranscriptMd = detail.transcriptMarkdown
        loadedScore = detail.score
        loadedSummary = detail.summary
    }

    /// 重新处理：按文章所属源的当前开关，重新跑所有已开启管线（阅读栏用，带状态反馈）
    private func reprocessFromReadingView() {
        runProcessing(.allEnabled)
    }

    private func runFulltext() {
        runProcessing(.fulltext)
    }

    private func runScore() {
        runProcessing(.score)
    }

    private func runTranslate() {
        runProcessing(.translate)
    }

    private func runSummarize() {
        runProcessing(.summarize)
    }

    private func runTranscribe() {
        runProcessing(.transcribe)
    }

    private func runProcessing(_ operation: ProcessingOperation) {
        ProcessingCommandCoordinator.start(
            gateway: processing,
            contentID: item.id,
            title: item.title,
            operation: operation
        ) { snapshot in
            guard snapshot.contentChanged else { return }
            refreshLoadedBody()
            if operation == .translate {
                if isMediaItem { mediaTab = 1 }
                else if viewMode == 1 { viewMode = 0 }
            } else if operation == .transcribe, viewMode == 1 {
                viewMode = 0
            }
        }
    }
}

extension Notification.Name {
    static let contentUpdated = Notification.Name("contentUpdated")
}

// MARK: - 分享 / 后处理（阅读区）

public struct ShareSheet: View {
    let item: ContentItem
    private let export: any ExportGateway
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""

    public init(item: ContentItem, export: any ExportGateway) {
        self.item = item
        self.export = export
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：标题 + 文章名（两行克制排版）
            VStack(alignment: .leading, spacing: 6) {
                Text("分享 / 后处理")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.rbText)
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.rbText3)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Hairline()

            // 动作行（hover 浮现 surface 底，hairline 分组）
            VStack(alignment: .leading, spacing: 2) {
                shareActionRow("复制链接", icon: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url, forType: .string)
                    message = "✅ 链接已复制"
                }
                shareActionRow("复制标题 + 链接", icon: "doc.on.doc") {
                    let text = "\(item.title)\n\(item.url)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    message = "✅ 标题+链接已复制"
                }
                shareActionRow("在浏览器打开原文", icon: "safari") {
                    if let url = URL(string: item.url), !item.url.isEmpty {
                        NSWorkspace.shared.open(url)
                    }
                    dismiss()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            Hairline()

            VStack(alignment: .leading, spacing: 2) {
                shareActionRow("触发导出规则", icon: "square.and.arrow.up.on.square") {
                    Task {
                        _ = try? await export.forceExport(contentID: item.id)
                        message = "✅ 已触发手动导出规则"
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.rbScoreHigh)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }

            Spacer()

            Hairline()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.primaryCapsule)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400, height: 430)
    }

    /// 分享动作行：图标 + 文字整行可点，hover 浮现 surface 底
    private func shareActionRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.rbText2)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.rbText)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.rowHover)
    }
}

// MARK: - 快捷键帮助面板（按 ? 弹出）

struct ShortcutHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("导航", [
            ("j / ↓", "下一篇"),
            ("k / ↑", "上一篇"),
            ("f", "聚焦搜索框"),
        ]),
        ("文章操作", [
            ("空格", "已读 / 未读切换"),
            ("s", "星标 / 取消星标"),
            ("e", "当前筛选范围全部标已读"),
            ("v", "浏览器打开原文"),
        ]),
        ("其他", [
            ("?", "显示本帮助"),
            ("⌘N", "添加订阅源"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("键盘快捷键")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.rbText)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.rbText3)
                }
                .buttonStyle(.plain)
            }

            ForEach(groups, id: \.0) { group, rows in
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: group)
                    ForEach(rows, id: \.0) { key, desc in
                        HStack(spacing: 10) {
                            Text(key)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.rbText2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.rbSurface)
                                .clipShape(RoundedRectangle(cornerRadius: RB.Radius.md))
                                .overlay(
                                    RoundedRectangle(cornerRadius: RB.Radius.md)
                                        .strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
                                )
                                .frame(minWidth: 72, alignment: .center)
                            Text(desc)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.rbText)
                            Spacer()
                        }
                    }
                }
            }

            Text("提示：搜索框聚焦时，j/k/空格 等单键快捷键自动禁用，避免与输入冲突。")
                .font(.system(size: 11))
                .foregroundStyle(Color.rbText3)
        }
        .padding(24)
        .frame(width: 430)
    }
}
