import SwiftUI
import WebKit
import QuartzCore

public struct ContentView: View {
    @StateObject private var vm = ContentViewModel()
    @EnvironmentObject private var appTab: AppTab
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool
    /// 界面缩放（@AppStorage 直接绑 UserDefaults——改值视图自动重建，静态读取不会触发刷新）
    @AppStorage("reading.uiFontScale") private var uiFontScale: Double = 1.0

    public var body: some View {
        NavigationSplitView {
            // ── 左栏：源列表 ──
            sourceSidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            // ── 中栏：文章列表 ──
            articleList
                .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 480)
        } detail: {
            // ── 右栏：阅读区 ──
            readingPane
        }
        .navigationTitle("ReadBoard")
        .onAppear { vm.loadAll() }
        .background(shortcutHandlers)
        // 轻提示（取消归档等操作的反馈）
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
    }

    // MARK: 快捷键（隐藏按钮承载键盘事件）
    // j/k 上下篇, s 星标, a 归档, 空格已读切换, v 开原文, e 全部已读, f 搜索, ? 帮助
    private var shortcutHandlers: some View {
        Group {
            Button("") { vm.selectNext() }.keyboardShortcut("j", modifiers: [])
            Button("") { vm.selectPrev() }.keyboardShortcut("k", modifiers: [])
            Button("") { if let it = vm.selectedItem { vm.toggleStar(it) } }.keyboardShortcut("s", modifiers: [])
            Button("") { if let it = vm.selectedItem { vm.toggleArchive(it) } }.keyboardShortcut("a", modifiers: [])
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
    @StateObject private var sourceStore = SourceStore.shared
    @State private var showAddSource = false
    @State private var showImportSummary = false   // OPML 解析后弹汇总确认页（与订阅管理页同源）
    @State private var importPlan: OPMLImportPlan? = nil
    @State private var showAddFolder = false
    @State private var newFolderName = ""
    /// 重命名目标（source: 源 id / folder: 文件夹 id）+ 输入名 + 弹窗状态
    @State private var renameTarget: (kind: String, id: Int64, currentName: String)? = nil
    @State private var renameInput = ""
    /// 展开的文件夹 id 集合（自己控制，DisclosureGroup 的 label 无法响应点击过滤）
    /// 持久化到 UserDefaults——重启恢复上次的展开/收起状态（首次启动默认全展开）。
    @State private var expandedFolders: Set<String> = []
    /// 开管线后弹「如何处理历史数据」（kind: source/folder，action: pipeline=LLM管线回填 / fulltext=全文重抓）
    @State private var pendingBackfill: (kind: String, id: Int64, name: String, pipelineLabel: String, action: String)? = nil

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
            AddSourceSheet(store: sourceStore)
                .onDisappear { vm.loadAll() }
        }
        .sheet(isPresented: $showImportSummary) {
            if let plan = importPlan {
                OPMLImportSummary(store: sourceStore, plan: plan)
                    .onDisappear { vm.loadAll() }
            }
        }
        .alert("新建文件夹", isPresented: $showAddFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("创建") {
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    sourceStore.addFolder(name: name)
                    vm.loadAll()
                }
                newFolderName = ""
            }
            Button("取消", role: .cancel) { newFolderName = "" }
        } message: {
            Text("文件夹用于给订阅源分组（如「快讯」「深度」），并可设置组级管线总开关。")
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
                    if t.kind == "source" { sourceStore.renameSource(id: t.id, name: name) }
                    else { sourceStore.renameFolder(id: t.id, name: name) }
                    vm.loadAll()
                }
                renameTarget = nil
            }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        // 开管线/切全文模式后弹「如何处理历史数据」（左栏右键触发，和订阅源页一致）
        .alert("处理历史数据？", isPresented: Binding(
            get: { pendingBackfill != nil },
            set: { if !$0 { pendingBackfill = nil } }
        )) {
            // action=pipeline（LLM 管线回填）：按钮文案带 md；action=fulltext（全文重抓）：文案带全文
            Button(pendingBackfill?.action == "fulltext" ? "重抓所有历史全文" : "处理所有历史并重新生成 Markdown") {
                if let p = pendingBackfill {
                    if p.action == "fulltext" {
                        // detached 后台跑——fetchAndStore spawn node 进程 + 超时轮询 Thread.sleep，
                        // 在 MainActor 上会冻结 UI 崩溃/卡死（WeChat 文件夹实测崩过）
                        if p.kind == "folder" {
                            Task.detached { await PipelineWorker.shared.refetchFullTextForFolder(folderId: p.id) }
                        } else {
                            Task.detached { await PipelineWorker.shared.refetchFullTextForSource(onlySourceId: p.id) }
                        }
                    } else {
                        if p.kind == "folder" {
                            Task.detached { await PipelineWorker.shared.backfillHistoryForFolder(folderId: p.id) }
                        } else {
                            Task.detached { await PipelineWorker.shared.backfillHistory(onlySourceId: p.id) }
                        }
                    }
                }
                pendingBackfill = nil
            }
            Button("只处理新增", role: .cancel) { pendingBackfill = nil }
        } message: {
            if let p = pendingBackfill {
                if p.action == "fulltext" {
                    Text("「\(p.name)」的全文抓取模式已切换为\(p.pipelineLabel)。\n\n• 重抓历史：存量文章按新模式重新抓取全文（耗时较长）\n• 只处理新增：历史不动，新抓的按新模式抓")
                } else {
                    Text("「\(p.name)」的\(p.pipelineLabel)已开启。\n\n• 处理历史：存量文章补跑管线并刷新已生成的 Markdown 文件（耗时较长，按量计费）\n• 只处理新增：历史不动，新抓的自动走管线")
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
        }
    }

    /// 左栏底部导航按钮（切到 订阅源管理/数据统计 全窗视图）
    private func sidebarNavButton(icon: String, label: String, tab: Int) -> some View {
        Button {
            appTab.selection = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.rbText2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.rowHover)
        .help("打开「\(label)」页面")
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
                    .foregroundStyle(Color.rbText3)
                    .frame(width: 16)
                Text("全部文章")
                    .font(.system(size: RB.F.sidebar * scale))
                    .foregroundStyle(Color.rbText)
                Spacer()
                // 未读/总数（和文件夹行格式一致：未读>0 墨蓝 medium，读完纯 text3）
                HStack(spacing: 1) {
                    Text("\(vm.totalUnread)")
                        .font(.system(size: RB.F.count * scale, weight: vm.totalUnread > 0 ? .medium : .regular))
                        .foregroundStyle(vm.totalUnread > 0 ? Color.rbAccent : Color.rbText3)
                    Text("/\(vm.totalCount)")
                        .font(.system(size: RB.F.count * scale))
                        .foregroundStyle(Color.rbText3)
                }
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
                    .font(.system(size: RB.F.sidebar * scale))
                    .foregroundStyle(Color.rbText)
                Spacer()
                // 始终显示 未读/总数（未读 > 0 时未读部分墨蓝 medium，读完纯 text3）
                HStack(spacing: 1) {
                    Text("\(node.unread)")
                        .font(.system(size: RB.F.count * scale, weight: node.unread > 0 ? .medium : .regular))
                        .foregroundStyle(node.unread > 0 ? Color.rbAccent : Color.rbText3)
                    Text("/\(node.count)")
                        .font(.system(size: RB.F.count * scale))
                        .foregroundStyle(Color.rbText3)
                }
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
            if let src = sourceStore.sources.first(where: { $0.id == sid }) {
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
                // 重新抓取全文（该源全部文章重抓）
                Button {
                    Task { await FullTextFetcher.shared.refetchSourceFulltext(sourceId: sid) }
                } label: {
                    Label("重新抓取全文", systemImage: "arrow.triangle.2.circlepath")
                }
                Divider()
                Menu {
                    Button("无文件夹") { sourceStore.assignSource(sourceId: sid, folderId: nil); vm.loadAll() }
                    ForEach(sourceStore.folders) { f in
                        Button(f.name) { sourceStore.assignSource(sourceId: sid, folderId: f.id); vm.loadAll() }
                    }
                } label: {
                    Label("移动到文件夹", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive) { sourceStore.removeSource(id: sid); vm.loadAll() } label: {
                    Label("删除此源", systemImage: "trash")
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
            if let folder = sourceStore.folders.first(where: { $0.id == fid }) {
                Menu {
                    folderPipelineMenu(folder: folder)
                } label: {
                    Label("内容处理", systemImage: "gearshape.2")
                }
            }
            // 抓取设置（与订阅源统一：获取全文三态 + 抓取频率，打钩反映组内一致性）
            Menu {
                folderFetchSettingsMenu(folderId: fid)
            } label: {
                Label("抓取设置", systemImage: "arrow.down.circle")
            }
            // 重新抓取全文（对文件夹内所有源批量重抓）
            Button {
                Task { await FullTextFetcher.shared.refetchFolderFulltext(folderId: fid) }
            } label: {
                Label("重新抓取全文", systemImage: "arrow.triangle.2.circlepath")
            }
            Divider()
            Button(role: .destructive) { sourceStore.removeFolder(id: fid); vm.loadAll() } label: {
                Label("删除文件夹", systemImage: "trash")
            }
        }
    }

    /// 导出单篇文章到指定平台（不必遵循规则，直接用平台预设配置）
    private func exportToPlatform(item: ContentItem, platform: String) {
        Task {
            let config = ExportPlatformConfig.shared
            var rule = ExportRule(
                id: 0, name: "单篇导出", enabled: true,
                criteria: ExportRule.Criteria(),
                triggerOn: "manual", target: platform, targetConfig: [:], lastRunAt: nil)
            // 用平台预设配置填充 targetConfig
            switch platform {
            case "obsidian":
                rule.targetConfig["dir"] = config.obsidianDir
            case "notion":
                rule.targetConfig["token"] = config.notionToken
                rule.targetConfig["database_id"] = config.notionDatabaseId
            case "cubox":
                rule.targetConfig["token"] = config.cuboxToken
            case "instapaper":
                rule.targetConfig["username"] = config.instapaperUser
                rule.targetConfig["password"] = config.instapaperPass
            case "readwise":
                rule.targetConfig["token"] = config.readwiseToken
            case "webhook":
                rule.targetConfig["url"] = config.webhookURL
                rule.targetConfig["headers"] = config.webhookHeaders
            default: break
            }
            // 直接调 deliver（不经过规则匹配）
            let (ok, dest, err) = await ExportService.shared.deliverSingle(rule: rule, contentId: item.id)
            await MainActor.run {
                // 用 App 级通知显示导出结果（不依赖 ViewModel 状态）
                NotificationCenter.default.post(
                    name: NSNotification.Name("ExportResult"),
                    object: nil,
                    userInfo: [
                        "ok": ok,
                        "platform": platform,
                        "dest": dest ?? "",
                        "error": err ?? ""
                    ])
            }
        }
    }

    /// 单篇文章跑管线（评分/摘要/翻译/转录）——右键菜单调用
    private func runPipelineForItem(item: ContentItem, type: String) {
        let pipeline = LLMPipeline()
        let transcriber = TranscribePipeline()
        let body = item.contentMd ?? item.excerpt ?? ""
        Task {
            let ok: Bool
            switch type {
            case "score":
                ok = await pipeline.score(contentId: item.id, title: item.title, body: body)
            case "summarize":
                ok = await pipeline.summarize(contentId: item.id, title: item.title, body: body)
            case "translate":
                // 媒体项翻简介（content_html → llm_excerpt_translated）；非媒体项翻正文
                if item.ctype == "podcast" || item.ctype == "video" || item.audioUrl != nil {
                    ok = await pipeline.translateExcerpt(contentId: item.id, title: item.title, contentHtml: item.excerpt ?? item.contentHtml ?? "")
                } else {
                    ok = await pipeline.translate(contentId: item.id, title: item.title, body: body)
                }
            case "transcribe":
                ok = await transcriber.transcribe(contentId: item.id, title: item.title,
                                                  audioUrl: item.audioUrl, pageUrl: item.url,
                                                  language: item.language)
            default:
                ok = false
            }
            if ok {
                ArchiveService.shared.rearchive(contentId: item.id)   // 刷新入库文件
                await MainActor.run {
                    NotificationCenter.default.post(name: .contentUpdated, object: nil)
                }
            }
        }
    }

    /// 源级管线开关菜单（打勾状态实时反映）
    @ViewBuilder
    private func pipelineToggleMenu(src: FeedSource) -> some View {
        pipelineMenuItem("AI 评分", key: "auto_score", on: src.policy.autoScore, src: src)
        pipelineMenuItem("AI 翻译", key: "auto_translate", on: src.policy.autoTranslate, src: src)
        pipelineMenuItem("AI 摘要", key: "auto_summarize", on: src.policy.autoSummarize, src: src)
        if src.transcribable {
            pipelineMenuItem("AI 转录", key: "auto_transcribe", on: src.policy.autoTranscribe, src: src)
        }
    }

    private func pipelineMenuItem(_ label: String, key: String, on: Bool, src: FeedSource) -> some View {
        Button {
            let turningOn = !on
            sourceStore.setPolicy(id: src.id, key: key, value: turningOn)
            // 开启时弹「如何处理历史数据」（和订阅源页一致）
            if turningOn {
                pendingBackfill = ("source", src.id, src.name, label, "pipeline")
            }
        } label: {
            // 只留打钩表勾选态（不要内容图标——勾选清晰可见最重要）
            Label(label, systemImage: on ? "checkmark" : "")
        }
    }

    /// 抓取设置菜单（fetch_mode + 频率）
    @ViewBuilder
    private func fetchSettingsMenu(src: FeedSource) -> some View {
        Menu("获取全文：\(src.fetchModeAuto ? "自动（\(src.fetchMode.displayName)）" : src.fetchMode.displayName)") {
            Button {
                Task { await sourceStore.setFetchMode(id: src.id, mode: "auto") }
            } label: {
                Label("自动（\(src.fetchMode.displayName)）",
                      systemImage: src.fetchModeAuto ? "checkmark" : "")
            }
            Button("重新检测") { Task { await sourceStore.redetectFetchMode(id: src.id) } }
            Divider()
            Button {
                Task { await sourceStore.setFetchMode(id: src.id, mode: "off") }
            } label: {
                Label("仅摘要", systemImage: src.isFetchOff ? "checkmark" : "")
            }
        }
        Menu("抓取频率：\(src.fetchIntervalMin < 60 ? "\(src.fetchIntervalMin)分钟" : "\(src.fetchIntervalMin/60)小时")") {
            ForEach([5, 15, 30, 60, 120, 360, 720], id: \.self) { m in
                Button { sourceStore.setFetchInterval(id: src.id, minutes: m) } label: {
                    Label(m < 60 ? "\(m) 分钟" : "\(m/60) 小时",
                          systemImage: src.fetchIntervalMin == m ? "checkmark" : "")
                }
            }
        }
    }

    // MARK: 文件夹抓取设置（与订阅源统一：打钩反映组内是否一致）

    /// 文件夹内所有源的 fetch_interval_min 是否全一致；一致返回该值
    private func folderUniformInterval(_ fid: Int64) -> Int? {
        let intervals = sourceStore.sources(inFolder: fid).map { $0.fetchIntervalMin }
        guard let first = intervals.first else { return nil }
        return intervals.allSatisfy { $0 == first } ? first : nil
    }

    /// 文件夹内所有源的「获取全文」状态是否全一致（设置状态 + 实际模式都一致才算）。
    /// 返回 ("auto", 模式) / ("off", nil) / nil（不一致→「按订阅源设置」）。
    private func folderUniformFetchMode(_ fid: Int64) -> (kind: String, mode: FetchMode?)? {
        let srcs = sourceStore.sources(inFolder: fid)
        guard !srcs.isEmpty else { return nil }
        // 全部自动（fetchModeAuto=true）→ 还要实际模式全相同才算一致（各源探测结果不同=混合=按订阅源设置）
        if srcs.allSatisfy({ $0.fetchModeAuto }) {
            let modes = srcs.map { $0.fetchMode }
            guard let first = modes.first, modes.allSatisfy({ $0 == first }) else { return nil }
            return ("auto", first)
        }
        // 全部仅摘要（fetchMode==.summary——关闭全文获取=summary 兜底，播客显示摘要同此）
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

        // ── 获取全文 ──
        Menu("获取全文：\(folderFetchModeLabel(fid, uniform: uniformMode))") {
            // 自动（打钩：全组都是自动）
            Button {
                Task { await sourceStore.setFolderFetchModeAuto(folderId: fid) }
            } label: {
                Label("自动\(uniformMode?.kind == "auto" && uniformMode?.mode != nil ? "（\(uniformMode!.mode!.displayName)）" : "")",
                      systemImage: uniformMode?.kind == "auto" ? "checkmark" : "")
            }
            // 重新检测（始终提供，对全组批量探测）
            Button("重新检测") { Task { await sourceStore.redetectFolderFetchMode(folderId: fid) } }
            Divider()
            // 仅摘要（关闭全文获取=summary 兜底；打钩：全组都是 summary）
            Button {
                sourceStore.setFolderFetchModeOff(folderId: fid)
            } label: {
                Label("仅摘要", systemImage: uniformMode?.kind == "off" ? "checkmark" : "")
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
                Button { sourceStore.setFolderFetchInterval(folderId: fid, minutes: m) } label: {
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

    /// 文件夹「获取全文」菜单标题的当前值文本
    private func folderFetchModeLabel(_ fid: Int64, uniform: (kind: String, mode: FetchMode?)?) -> String {
        guard let uniform else { return "按订阅源设置" }
        switch uniform.kind {
        case "auto": return uniform.mode != nil ? "自动（\(uniform.mode!.displayName)）" : "自动"
        case "off": return "仅摘要"
        default: return "按订阅源设置"
        }
    }


    /// 文件夹级管线菜单（打钩显示组内一致性：全开=钩，全关=不钩，不一致=「按订阅源设置」不钩）
    @ViewBuilder
    private func folderPipelineMenu(folder: Folder) -> some View {
        folderPipelineItem("AI 评分", key: "auto_score", folder: folder)
        folderPipelineItem("AI 翻译", key: "auto_translate", folder: folder)
        folderPipelineItem("AI 摘要", key: "auto_summarize", folder: folder)
        folderPipelineItem("AI 转录", key: "auto_transcribe", folder: folder)
    }

    /// 文件夹内所有源某管线键的值是否全一致；一致返回该值（true/false），不一致返回 nil
    private func folderUniformPolicy(_ fid: Int64, key: String) -> Bool? {
        let vals = sourceStore.sources(inFolder: fid).map { src -> Bool in
            let p = PipelinePolicy.from(configJson: src.config)
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

    private func folderPipelineItem(_ label: String, key: String, folder: Folder) -> some View {
        let uniform = folderUniformPolicy(folder.id, key: key)
        // 一致时：值即组内统一值；不一致时：nil（显示「按订阅源设置」不钩）
        let isOn = uniform ?? false
        let inconsistent = uniform == nil
        return Button {
            // 切换目标：当前非全开则全设开，当前全开则全设关（不一致时默认全设开）
            let turningOn = !(uniform ?? false)
            sourceStore.setFolderPolicy(id: folder.id, key: key, value: turningOn)
            // 开启时弹「如何处理历史数据」（和订阅源页一致）
            if turningOn {
                pendingBackfill = ("folder", folder.id, folder.name, label, "pipeline")
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
        if let src = sourceStore.sources.first(where: { $0.id == sid }) {
            _ = try? await sourceStore.syncOne(src)
            vm.loadAll()
        }
    }

    private func refreshFolder(_ fid: Int64) async {
        for src in sourceStore.sources where src.folderId == fid && src.enabled {
            _ = try? await sourceStore.syncOne(src)
        }
        vm.loadAll()
    }

    private func markSourceRead(_ sid: Int64) {
        Database.shared.execute(
            "UPDATE content SET read_at = datetime('now') WHERE source_id = ? AND read_at IS NULL",
            params: [sid])
        vm.loadAll()
    }

    private func markFolderRead(_ fid: Int64) {
        Database.shared.execute("""
            UPDATE content SET read_at = datetime('now')
            WHERE read_at IS NULL AND source_id IN (SELECT id FROM content_source WHERE folder_id = ?)
            """, params: [fid])
        vm.loadAll()
    }

    // MARK: 中栏

    /// 筛选 chip（纸墨胶囊：激活墨蓝浅底+描边，未激活 surface+hairline）
    private func filterChip(label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11))
                .padding(.horizontal, 8).padding(.vertical, 3.5)
                .background(active ? Color.rbAccent.opacity(0.10) : Color.rbSurface)
                .foregroundStyle(active ? Color.rbAccent : Color.rbText2)
                .clipShape(RoundedRectangle(cornerRadius: RB.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: RB.Radius.md)
                        .strokeBorder(active ? Color.rbAccent.opacity(0.30) : Color.rbHairline,
                                      lineWidth: RB.Line.hair)
                )
        }
        .buttonStyle(.plain)
    }

    /// 处理状态平铺多选按钮（激活高亮，点击切换加入/移出多选集）
    private func processedToggle(key: String, label: String) -> some View {
        let active = vm.processedFilters.contains(key)
        return filterChip(label: label, active: active) {
            if active { vm.processedFilters.remove(key) }
            else { vm.processedFilters.insert(key) }
            vm.reload()
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

            // 筛选条行1：评分(输入框) + 标签 + 未读/全部/星标(单选) + 归档
            HStack(spacing: 8) {
                Text("评分 ≥")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.rbText3)
                TextField("0", value: $vm.minScore, format: .number)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 30)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: RB.Radius.md)
                            .fill(Color.rbSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RB.Radius.md)
                            .strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
                    )
                    .onSubmit { vm.reload() }
                    .onChange(of: vm.minScore) { _, _ in vm.reloadDebounced() }
                if vm.minScore > 0 {
                    filterChip(label: "含未评分", active: vm.includeUnscored) {
                        vm.includeUnscored.toggle()
                        vm.reload()
                    }
                }

                Spacer()

                // 全部/未读/星标/归档 四选一单选（纸墨分段，替代原生 segmented）
                RBSegmented(
                    items: ContentViewModel.ReadFilter.allCases.map { ($0, $0.display) },
                    selection: $vm.readFilter
                )
                .onChange(of: vm.readFilter) { _, _ in vm.reload() }

                // 排序选择（最新/最早/评分；胶囊 Menu，替代原生弹出按钮）
                Menu {
                    ForEach(ContentViewModel.SortOrder.allCases) { o in
                        Button { vm.sortOrder = o } label: {
                            Label(o.display, systemImage: vm.sortOrder == o ? "checkmark" : "")
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
                    .overlay(
                        Capsule().strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
                    )
                }
                .menuStyle(.borderlessButton)
                .onChange(of: vm.sortOrder) { _, _ in vm.reload() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 筛选条行2：处理状态平铺多选按钮（AI 评分/AI 摘要/AI 翻译/AI 转录，可多选）
            HStack(spacing: 6) {
                Text("处理")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.rbText3)
                processedToggle(key: "score", label: "已 AI 评分")
                processedToggle(key: "summary", label: "已摘要")
                processedToggle(key: "translate", label: "已翻译")
                processedToggle(key: "transcribe", label: "已转录")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Hairline()

            // 操作条：计数 + 全部标已读
            HStack {
                SectionLabel(text: "\(vm.items.count) 条")
                Spacer()
                Button {
                    let n = vm.markAllRead()
                    _ = n
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
                               isReadOverride: vm.readMarks[item.id] == true)
                        .tag(item)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                        .contextMenu {
                            // ── 状态操作 ──
                            Button { vm.toggleRead(item) } label: {
                                Label(item.isRead ? "标为未读" : "标为已读",
                                      systemImage: item.isRead ? "envelope.badge" : "envelope.open")
                            }
                            Button { vm.toggleStar(item) } label: {
                                Label(item.starred ? "取消星标" : "加星标",
                                      systemImage: item.starred ? "star.slash" : "star")
                            }
                            Button { vm.toggleArchive(item) } label: {
                                Label(item.archived ? "取消归档" : "归档",
                                      systemImage: item.archived ? "tray.and.arrow.up" : "archivebox")
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
                            } label: {
                                Label("内容处理", systemImage: "gearshape.2")
                            }
                            // 重新抓取全文（单篇重抓）
                            Button {
                                Task { await FullTextFetcher.shared.refetchSingleFulltext(contentId: item.id) }
                            } label: {
                                Label("重新抓取全文", systemImage: "arrow.triangle.2.circlepath")
                            }

                            // ── 后处理 ──
                            Button {
                                ArchiveService.shared.rearchive(contentId: item.id)
                            } label: {
                                Label("重新生成 Markdown 文件", systemImage: "doc.arrow.clockwise")
                            }
                            // 在 Finder 中打开 Markdown 文件（已归档的显示，未归档的禁用）
                            if let archivePath = ArchiveService.shared.archiveFilePath(contentId: item.id),
                               FileManager.default.fileExists(atPath: archivePath) {
                                Button {
                                    NSWorkspace.shared.selectFile(archivePath, inFileViewerRootedAtPath: "")
                                } label: {
                                    Label("在 Finder 中打开 md", systemImage: "folder")
                                }
                            }
                            Button {
                                Task { await ExportService.shared.runPending(trigger: "manual", contentId: item.id) }
                            } label: {
                                Label("触发导出规则", systemImage: "square.and.arrow.up.on.square")
                            }

                            // ── 导出到平台（不必遵循规则，直接导出到各平台预设位置）──
                            Menu {
                                Button {
                                    exportToPlatform(item: item, platform: "obsidian")
                                } label: {
                                    Label("Obsidian", systemImage: "note.text")
                                }
                                Button {
                                    exportToPlatform(item: item, platform: "notion")
                                } label: {
                                    Label("Notion", systemImage: "square.grid.2x2")
                                }
                                Button {
                                    exportToPlatform(item: item, platform: "cubox")
                                } label: {
                                    Label("Cubox", systemImage: "cube")
                                }
                                Button {
                                    exportToPlatform(item: item, platform: "instapaper")
                                } label: {
                                    Label("Instapaper", systemImage: "book")
                                }
                                Button {
                                    exportToPlatform(item: item, platform: "readwise")
                                } label: {
                                    Label("Readwise", systemImage: "bookmark")
                                }
                                Button {
                                    exportToPlatform(item: item, platform: "webhook")
                                } label: {
                                    Label("Webhook", systemImage: "link")
                                }
                            } label: {
                                Label("导出到平台", systemImage: "square.and.arrow.up")
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
                            onPrev: { vm.selectPrev() }, onNext: { vm.selectNext() })
                    .id(item.id)   // 切文章强制重建视图：busy/statusMsg 等 @State 不串到下一篇
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
    var isReadOverride: Bool = false
    /// 有效已读态（覆盖优先，其次 item 字段）
    private var isRead: Bool { isReadOverride || item.isRead }
    /// @AppStorage 让设置变化时行自动重建（静态 ReadingLayout 读取不触发刷新）
    @AppStorage("reading.uiFontScale") private var scale: Double = 1.0
    @AppStorage("list.showThumbnails") private var showThumbnails: Bool = true
    @AppStorage("list.excerptLines") private var excerptLines: Int = 2
    @AppStorage("list.density") private var density: String = "comfortable"
    @AppStorage("list.showSource") private var showSource: Bool = true
    @AppStorage("list.showDate") private var showDate: Bool = true
    @AppStorage("list.unreadBold") private var unreadBold: Bool = true
    @AppStorage("list.dateFormat") private var dateFormat: String = "absolute"

    /// 紧凑密度下缩略图更小、行距更紧
    private var isCompact: Bool { density == "compact" }

    /// 源类型图标（RSS 用经典三半圆图标，其他来源待补齐品牌图标）
    /// 返回 nil 表示暂不显示图标（等写对应订阅功能时再补）
    private var ctypeIcon: String? {
        switch item.ctype {
        case "podcast": return "mic"
        case "video", "youtube": return nil  // 待 YouTube 订阅功能补齐品牌图标
        case "wechat", "social": return nil   // 待微信订阅功能补齐品牌图标
        default: return nil  // RSS 用自定义 RSSIcon 组件，不走 SF Symbol
        }
    }

    /// 是否 RSS 协议源（用自定义三半圆图标）
    private var isRSSSource: Bool {
        item.ctype != "podcast" && item.ctype != "video" && item.ctype != "youtube" &&
        item.ctype != "wechat" && item.ctype != "social"
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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: isCompact ? 2 : 5) {
                // 标题行（评分挪到下方来源行了，标题行只留标题 + 星标）
                HStack(alignment: .top, spacing: 6) {
                    // 有译文时显示中文标题（llm_translated_md 第一行），否则原标题
                    Text(displayTitle)
                        .font(.system(size: RB.F.rowTitle * scale, weight: (unreadBold && !isRead) ? .semibold : .regular))
                        .foregroundStyle(isRead ? Color.rbText2 : Color.rbText)
                        .lineLimit(isCompact ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.starred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(Color.rbStar)
                            .font(.system(size: 11 * scale))
                    }
                    Spacer(minLength: 0)
                }
                // 摘要（行数可配，0 = 不显示）
                if excerptLines > 0, let ex = item.excerpt, !ex.isEmpty {
                    Text(ex)
                        .font(.system(size: RB.F.rowExcerpt * scale))
                        .foregroundStyle(Color.rbText2)
                        .lineLimit(excerptLines)
                }
                // 来源 + 评分标签 + 日期（评分挪到标题下面这行，在 RSS 来源旁边）
                HStack(spacing: 6) {
                    if showSource {
                        HStack(spacing: 4) {
                            // 源类型图标：RSS 用经典三半圆，其他来源待补齐品牌图标（只显示图标不要文字）
                            if isRSSSource {
                                RSSIcon(size: 11, color: .rbText3)
                            } else if let icon = ctypeIcon {
                                Image(systemName: icon)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.rbText3)
                            }
                        }
                    }
                    // 评分 badge（固定宽度——个位数/0 不短一截）
                    if let s = item.llmScore {
                        Text("评分 \(s)")
                            .font(.system(size: RB.F.badge * scale, weight: .medium))
                            .foregroundStyle(scoreColor(s))
                            .frame(width: 52, alignment: .center)   // 固定宽度
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(scoreColor(s).opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: RB.Radius.sm))
                            .overlay(
                                RoundedRectangle(cornerRadius: RB.Radius.sm)
                                    .strokeBorder(scoreColor(s).opacity(0.22), lineWidth: RB.Line.hair)
                            )
                    }
                    // 全文 badge（有全文绿 / 无全文红）——仅文章；媒体项没正文概念不显示（播客靠转录非全文）
                    if !item.isMedia {
                        if item.hasFulltext {
                            RBadge(text: "全文", color: .rbScoreHigh, scale: scale)
                        } else {
                            RBadge(text: "无全文", color: .rbScoreLow, scale: scale)
                        }
                    }
                    // 管线已处理 badge（两字标签）
                    if let sum = item.llmSummary, !sum.isEmpty {
                        RBadge(text: "摘要", color: .rbSummary, scale: scale)
                    }
                    // 翻译/转录 badge：文章翻译=hasTranslation(llm_translated_md)；
                    // 媒体项分开——翻译=hasExcerptTrans(简介翻译 llm_excerpt_translated)，转录=hasTranslation(转录稿 llm_translated_md)
                    if item.isMedia {
                        if item.hasExcerptTrans {
                            RBadge(text: "翻译", color: .rbTranslate, scale: scale)
                        }
                        if item.hasTranslation {
                            RBadge(text: "转录", color: .rbSummary, scale: scale)
                        }
                    } else if item.hasTranslation {
                        RBadge(text: "翻译", color: .rbTranslate, scale: scale)
                    }
                    if showDate, let pd = item.publishedAt, pd.count >= 10 {
                        Text(formattedDate(pd))
                            .font(.system(size: RB.F.rowMeta * scale))
                            .foregroundStyle(Color.rbText3)
                    }
                    Spacer()
                    // 未读点：6pt 墨蓝（选中态不隐藏——浅底下保持可见）
                    if !isRead {
                        Circle().fill(Color.rbAccent).frame(width: 6, height: 6)
                    }
                }
            }
            // 右侧缩略图（可关；紧凑模式更小；失败占位 surface 更干净；hairline 描边挺边）
            if showThumbnails, let img = item.imageUrl, let url = URL(string: img) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure, .empty:
                        Rectangle().fill(Color.rbSurface)
                    @unknown default:
                        Rectangle().fill(Color.rbSurface)
                    }
                }
                .frame(width: (isCompact ? 48 : 72) * scale, height: (isCompact ? 48 : 72) * scale)
                .clipShape(RoundedRectangle(cornerRadius: RB.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: RB.Radius.md)
                        .strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
                )
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

    /// 相对时间（ISO8601 → x 分钟/小时/天前）
    static func relativeDate(from iso: String) -> String {
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

    /// 列表是否显示缩略图（右侧小图）
    static var showThumbnails: Bool {
        get { UserDefaults.standard.object(forKey: "list.showThumbnails") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "list.showThumbnails") }
    }
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
    /// 上一篇/下一篇导航回调（阅读区顶部按钮，键盘 j/k 的图形化对应）
    var onPrev: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil

    @State private var pipeline = LLMPipeline()
    @State private var transcriber = TranscribePipeline()
    @State private var busy = false
    @State private var statusMsg: String?
    /// busy 所属的内容 id——切文章后旧任务完成不再污染新文章的 busy 状态
    @State private var busyForId: Int64? = nil
    /// 当前内容的有效管线开关（源 OR 文件夹）
    @State private var policy = PipelinePolicy()
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

    private var fullBody: some View {
        VStack(spacing: 0) {
            // ── 顶部操作条：左快捷操作 / 中双语切换 / 右版面设置（三段分组式）──
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

                Button { toggleArchive() } label: {
                    Image(systemName: item.archived ? "tray.and.arrow.up" : "archivebox")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(Color.rbText2)
                }
                .buttonStyle(.staticQuiet)
                .help(item.archived ? "取消归档" : "归档")

                Button { showShareSheet = true } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(Color.rbText2)
                }
                .buttonStyle(.staticQuiet)
                .help("分享 / 后处理")

                Spacer()

                // 视图切换：非媒体项「译文/原文」两段；媒体项「原文/译文/转录」三段（同一组件同一位置）
                if isMediaItem {
                    // 媒体项三标签：有转录对照稿才显示「转录」段
                    // （用 translatedText 判定——DB 兜底，不依赖 item 轻列字段的新鲜度）
                    if translatedText != nil {
                        RBSegmented(
                            items: [(0, "原文"), (1, "译文"), (2, "转录")],
                            selection: $mediaTab
                        )
                    } else {
                        // 无转录稿只两段；mediaTab 持久化值可能=2（上次转录），钳制到 0 防越界
                        RBSegmented(
                            items: [(0, "原文"), (1, "译文")],
                            selection: Binding(
                                get: { min(mediaTab, 1) },
                                set: { mediaTab = $0 }
                            )
                        )
                    }
                // ⚠️ 切标签"点了没反应"根治（09:21 用户直觉定位：在等通知但通知没给到，是个低级问题）：
                // 原判断 `!= nil` —— llm_translated_md=0KB 的文章 loadedTranslatedMd 是**空字符串 ""（非 nil）**，
                // `!= nil` 通过 → 标签显示"译文/原文"；但正文 hasTranslated 判断是 `!$0.isEmpty`，
                // 空串 → false → 正文只渲染原文 → 点"译文"画面不变（你以为没识别，其实是没内容可切）。
                // 修复：标签显示条件与正文一致——译文**非空**才显示切换标签。
                } else if translatedText != nil {
                    RBSegmented(
                        items: [(0, "译文"), (1, "原文")],
                        selection: $viewMode
                    )
                }

                Spacer()

                // 版面设置（Aa 图标）——右上角只留格式按钮；全文/评分/摘要/翻译/转录统一在标题栏下方胶囊按钮组
                Button { showLayoutPopover = true } label: {
                    Image(systemName: "textformat")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(Color.rbText2)
                }
                .buttonStyle(.staticQuiet)
                .help("版面设置")
                .popover(isPresented: $showLayoutPopover, arrowEdge: .bottom) {
                    layoutPanel
                }
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
                    // 标题（独立字号设置；标题字体跟用户字体选择走，不被主题强制）
                    // 点击直接在浏览器打开原文 + 文本可选择
                    Button {
                        if let url = URL(string: item.url), !item.url.isEmpty {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Text(item.title)
                            .font(fontChoice.font(size: titleFontSize).bold())
                            .foregroundStyle(p.text)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .help("点击在浏览器打开原文")
                    .textSelection(.enabled)
                    // 中文标题（有译文时显示在英文标题下方——从 translatedHead 第一行取）
                    if let chineseTitle = chineseTitle, chineseTitle != item.title {
                        Text(chineseTitle)
                            .font(fontChoice.font(size: titleFontSize * 0.75).weight(.medium))
                            .foregroundStyle(p.textSecondary)
                            .textSelection(.enabled)
                    }
                    // 元信息（作者 · 日期 · 评分，编辑部点分隔；frontmatter 块在正文里单独折叠）
                    if !metaParts.isEmpty {
                        Text(metaParts.joined(separator: "  ·  "))
                            .font(.system(size: metaFontSize))
                            .foregroundStyle(p.textSecondary)
                    }

                    // ── 播客音频播放器（podcast 且有 audioUrl 时显示，固定顶部——切标签不动）──
                    if item.ctype == "podcast", let audioUrl = item.audioUrl, !audioUrl.isEmpty {
                        AudioPlayerView(audioUrl: audioUrl, title: item.title)
                            .padding(.vertical, 4)
                    }

                    // ── LLM 操作条（胶囊按钮组 + 状态提示，精致排版）──
                    // 这套是阅读器唯一的操作按钮组（右上角已只留格式）。
                    // 所有按钮都是单篇手动操作/重操作，不受文件夹/订阅源自动开关限制。
                    HStack(spacing: 8) {
                        // 获取全文：不需 LLM，任何项都可点（抓正文/重抓）
                        StaticCapsuleButton(title: "获取全文", icon: "doc.text", disabled: busy) { runFulltext() }
                        if !pipeline.isAvailable {
                            if !isMediaItem {
                                Label("未配置 LLM Key", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(Color.rbScoreLow)
                            }
                        } else {
                            // 评分/摘要/翻译按钮：均始终显示，已有结果也可重新执行
                            StaticCapsuleButton(title: "AI 评分", icon: "star", disabled: busy) { runScore() }
                            StaticCapsuleButton(title: "AI 摘要", icon: "text.quote", disabled: busy) { runSummarize() }
                            StaticCapsuleButton(title: "AI 翻译", icon: "character.bubble", disabled: busy) { runTranslate() }
                            if busy {
                                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                            }
                            if let msg = statusMsg {
                                Text(msg)
                                    .font(.caption)
                                    .foregroundStyle(Color.rbText3)
                                    .lineLimit(1)
                            }
                        }
                        // AI 转录：媒体项始终显示（放最后）；已有转录稿也显示（可重新转录）
                        if isMediaItem {
                            StaticCapsuleButton(title: "AI 转录", icon: "waveform", disabled: busy) { runTranscribe() }
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
            .id("reading-body-\(viewMode)-\(mediaTab)")
            .background(p.background)   // 主题底色
        }
        // 视图随 .id(item.id) 重建，onAppear 即切文章——刷新有效开关与本地状态
        .onAppear {
            Trace.i("ReadingView.onAppear id=\(item.id) ctype=\(item.ctype) 已有contentMd=\(item.contentMd != nil) llmTranslatedMd非空=\(item.llmTranslatedMd != nil) mem=\(Trace.mb())MB [\(buildTag)]", category: "read")
            Trace.startMemorySampler(category: "read.mem")
            policy = Database.shared.effectivePolicyFor(contentId: item.id)
            isStarred = item.starred
            isRead = item.isRead
            loadContentMd()   // 按 id 查 content_md（列表查询不取，点开再查防闪烁）
        }
        .onDisappear {
            Trace.i("ReadingView.onDisappear id=\(item.id) mem=\(Trace.mb())MB", category: "read")
            Trace.stopMemorySampler(category: "read.mem")
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(item: item)
        }
    }

    /// 元信息片段（作者/日期/评分）——编辑部点分隔风格，有则收集
    private var metaParts: [String] {
        var parts: [String] = []
        if let a = item.author, !a.isEmpty { parts.append(a) }
        if let pd = item.publishedAt { parts.append(String(pd.prefix(10))) }
        if let s = effectiveScore { parts.append("评分 \(s)") }
        return parts
    }

    /// 版面设置面板（极简分组：外观 / 字号 / 排版，标签统一 text2 右对齐，数值等宽）
    private var layoutPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("版面设置")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.rbText)

            // ── 外观 ──
            SectionLabel(text: "外观")
            settingRow("主题") {
                Picker("", selection: $themeRaw) {
                    ForEach(ReadingTheme.allCases) { t in
                        Text(t.displayName).tag(t.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .tint(Color.rbAccent)
            }
            settingRow("亮暗") {
                Picker("", selection: $themeModeRaw) {
                    ForEach(ReadingTheme.Mode.allCases) { m in
                        Text(m.displayName).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .tint(Color.rbAccent)
            }
            settingRow("字体") {
                Picker("", selection: $fontRaw) {
                    ForEach(ReadingFont.presets, id: \.self) { f in
                        Text(f.displayName).tag(fontKey(f))
                    }
                    Divider()
                    ForEach(ReadingFont.availableFontFamilies, id: \.self) { family in
                        Text(family)
                            .font(.custom(family, size: 13))
                            .tag("custom:\(family)")
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.rbAccent)
            }

            Hairline()

            // ── 字号（统一滑块）──
            SectionLabel(text: "字号")
            sliderRow("正文", value: $fontSize, range: 12...28)
            sliderRow("标题", value: $titleFontSize, range: 16...40)
            sliderRow("信息", value: $metaFontSize, range: 9...18)
            sliderRow("摘要", value: $summaryFontSize, range: 10...22)
            sliderRow("界面缩放", value: $uiFontScale, range: 0.8...1.5, step: 0.05,
                      format: { String(format: "%.0f%%", $0 * 100) })

            Hairline()

            // ── 排版 ──
            SectionLabel(text: "排版")
            sliderRow("行距", value: $lineSpacing, range: 0...16)
            settingRow("宽度") {
                Picker("", selection: $contentWidth) {
                    Text("窄").tag(560.0)
                    Text("中").tag(720.0)
                    Text("宽").tag(960.0)
                }
                .pickerStyle(.segmented)
                .tint(Color.rbAccent)
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    /// 设置行：左侧标签（text2 右对齐固定宽）+ 右侧控件
    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.rbText2)
                .frame(width: 56, alignment: .trailing)
            content()
        }
    }

    /// 滑块行（字号/行距/界面缩放统一）：标签 + 滑块 + 数值等宽。
    /// format 自定义数值显示（默认整数，界面缩放传百分比）。
    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double = 1, format: ((Double) -> String)? = nil) -> some View {
        settingRow(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: step)
                    .tint(Color.rbAccent)
                Text(format?(value.wrappedValue) ?? "\(Int(value.wrappedValue))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.rbText2)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    /// ReadingFont → 持久化 key（和 ReadingFont.current 存储格式一致）
    private func fontKey(_ f: ReadingFont) -> String {
        switch f {
        case .system: return "system"
        case .heiti: return "heiti"
        case .kaiti: return "kaiti"
        case .fangsong: return "fangsong"
        case .custom(let name): return "custom:\(name)"
        }
    }

    // MARK: 快捷操作（本地即时反馈 + 通知列表刷新）

    private func toggleStar() {
        Database.shared.toggleStar(contentId: item.id)
        isStarred.toggle()
        NotificationCenter.default.post(name: .contentUpdated, object: nil)
    }

    private func toggleRead() {
        if isRead { Database.shared.markUnread(contentId: item.id) }
        else { Database.shared.markRead(contentId: item.id) }
        isRead.toggle()
        NotificationCenter.default.post(name: .contentUpdated, object: nil)
    }

    private func toggleArchive() {
        Database.shared.toggleArchive(contentId: item.id)
        NotificationCenter.default.post(name: .contentUpdated, object: nil)
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
        item.ctype == "podcast" || item.ctype == "video" || item.audioUrl != nil
    }

    // MARK: 媒体项三标签（原文/译文/转录）

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
        // 无转录对照稿时，mediaTab=2（上次记住的转录）无内容，钳制回原文
        let hasTranscript = translatedText != nil
        let tab = (mediaTab == 2 && !hasTranscript) ? 0 : mediaTab
        switch tab {
        case 0:
            // 原文：feed 简介（剥标签纯文本）
            return excerptPlainText
        case 1:
            // 译文：简介的中文翻译（llm_excerpt_translated）；没有则提示点「AI 翻译」
            if let t = effectiveExcerptTranslated, !t.isEmpty { return t }
            return "尚无译文——点右上角「翻译」生成简介的中文翻译"
        default:
            // 转录：中英对照转录稿（llm_translated_md）
            if let t = translatedText { return t }
            return "尚无转录稿——点「转录」生成中英文对照稿"
        }
    }

    @ViewBuilder
    private var mediaBodyView: some View {
        MarkdownBodyView(markdown: mediaBodyMarkdown, theme: theme, mode: themeMode, fontChoice: fontChoice,
                         fontSize: fontSize, lineSpacing: lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 中文标题（媒体项取标题译文 titleTranslated；非媒体项从正文译文 translatedHead 第一行取）
    private var chineseTitle: String? {
        // 媒体项：独立的标题译文（llm_title_translated）——镜像优先（item 轻列可能陈旧）
        if isMediaItem {
            guard let t = effectiveTitleTranslated, !t.isEmpty else { return nil }
            return t
        }
        // 非媒体：从译文正文取首个非空行（translatedText 自带 DB 兜底——
        // 翻译完成后 item.translatedHead 是旧实例字段、可能为 nil，走 DB 才新鲜）
        guard let translated = translatedText else { return nil }
        let firstNonEmpty = translated.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        // 剥「标题：」前缀（LLM 输出格式标记）+ markdown 标题标记（##）
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
    /// 简介译文/标题译文镜像（媒体项三标签与中文标题用）——item 是轻列实例，
    /// 这两字段列表查询不取/可能陈旧，镜像从 fetchContentBody 补齐。
    @State private var loadedExcerptTranslated: String? = nil
    @State private var loadedTitleTranslated: String? = nil
    /// 评分/摘要镜像（AI 完成后自动上屏用）——selectedItem 实例刻意不替换（会诱发
    /// AttributeGraph 无限重绘循环，12:10 hang 实锤），item 里的这两字段永远是打开时的旧值。
    @State private var loadedScore: Int? = nil
    @State private var loadedSummary: String? = nil

    /// 镜像优先的有效值（镜像未就绪时回退 item 字段）
    private var effectiveExcerptTranslated: String? { loadedExcerptTranslated ?? item.excerptTranslated }
    private var effectiveTitleTranslated: String? { loadedTitleTranslated ?? item.titleTranslated }
    private var effectiveScore: Int? { loadedScore ?? item.llmScore }
    private var effectiveSummary: String? { loadedSummary ?? item.llmSummary }

    private var contentBody: String {
        if let md = loadedContentMd, !md.isEmpty { return md }
        if let md = item.contentMd, !md.isEmpty { return md }
        return item.excerpt ?? ""
    }

    /// 打开时按 id 查 content_md（列表查询不取大字段，点开再查）
    private func loadContentMd() {
        guard loadedContentMd == nil else { return }
        let t0 = Date()
        if let body = Database.shared.fetchContentBody(id: item.id) {
            let mdKb = (body.contentMd ?? "").count / 1024
            let htmlKb = (body.contentHtml ?? "").count / 1024
            let transKb = (body.llmTranslatedMd ?? "").count / 1024
            Trace.i("loadContentMd 完成 id=\(item.id) content_md=\(mdKb)KB content_html=\(htmlKb)KB llm_translated_md=\(transKb)KB 用时=\(Int(t0.timeIntervalSinceNow * -1000))ms mem=\(Trace.mb())MB", category: "read")
            loadedContentMd = body.contentMd
            loadedContentHtml = body.contentHtml
            loadedTranslatedMd = body.llmTranslatedMd
            loadedExcerptTranslated = body.excerptTranslated
            loadedTitleTranslated = body.titleTranslated
            if let ex = Database.shared.fetchLLMExtras(id: item.id) {
                loadedScore = ex.score
                loadedSummary = ex.summary
            }
        } else {
            Trace.w("loadContentMd 返回 nil id=\(item.id)", category: "read")
        }
    }

    /// LLM 任务完成后重查全部镜像（item 实例刻意不替换，新鲜度全走镜像/DB 兜底——
    /// 翻译/摘要/评分/转录完成后 译文标题、摘要卡、评分标、标签入口 即刻自动上屏）
    private func refreshLoadedBody() {
        guard let body = Database.shared.fetchContentBody(id: item.id) else { return }
        loadedContentMd = body.contentMd
        loadedContentHtml = body.contentHtml
        loadedTranslatedMd = body.llmTranslatedMd
        loadedExcerptTranslated = body.excerptTranslated
        loadedTitleTranslated = body.titleTranslated
        if let ex = Database.shared.fetchLLMExtras(id: item.id) {
            loadedScore = ex.score
            loadedSummary = ex.summary
        }
    }

    /// 原始 HTML（原网页视图用）——@State 缓存，打开时按 id 查
    @State private var loadedContentHtml: String? = nil

    private func runFulltext() {
        let cid = item.id
        guard PipelineWorker.shared.tryLockContent(cid) else {
            statusMsg = "⏳ 该篇正在后台处理中，请稍候"
            return
        }
        busy = true
        busyForId = cid
        statusMsg = "获取全文中…"
        Task {
            // 从源 config 解析 fetch_mode
            let srcConfig = Database.shared.queryRows("""
                SELECT s.config FROM content c LEFT JOIN content_source s ON c.source_id = s.id WHERE c.id = ?
                """, params: [cid]).first?["config"] ?? "{}"
            var mode: FetchMode = .summary
            if let data = srcConfig.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = obj["fetch_mode"] as? String,
               let m = FetchMode(rawValue: raw) { mode = m }
            let ok = await FullTextFetcher.shared.fetchAndStore(
                contentId: cid, url: item.url, feedHtml: nil, mode: mode)
            if ok { ArchiveService.shared.rearchive(contentId: cid) }
            await MainActor.run {
                PipelineWorker.shared.unlockContent(cid)
                guard busyForId == cid else { return }
                busy = false
                statusMsg = ok ? "✅ 全文获取完成" : "❌ 全文获取失败"
                if ok {
                    refreshLoadedBody()
                    NotificationCenter.default.post(name: .contentUpdated, object: nil)
                }
            }
        }
    }

    private func runScore() {
        let cid = item.id
        // contentId 互斥：worker 正在处理同一篇则不重复触发（防双倍 LLM 计费，修 P1-10）
        guard PipelineWorker.shared.tryLockContent(cid) else {
            statusMsg = "⏳ 该篇正在后台处理中，请稍候"
            return
        }
        busy = true
        busyForId = cid
        statusMsg = "AI 评分中…"
        Task {
            let ok = await pipeline.score(contentId: cid, title: item.title, body: contentBody)
            if ok { ArchiveService.shared.rearchive(contentId: cid) }   // 手动重处理 → 刷新归档文件
            await MainActor.run {
                PipelineWorker.shared.unlockContent(cid)
                guard busyForId == cid else { return }   // 已切走，不覆盖新文章状态
                busy = false
                statusMsg = ok ? "✅ AI 评分完成" : "❌ AI 评分失败"
                if ok {
                    refreshLoadedBody()
                    NotificationCenter.default.post(name: .contentUpdated, object: nil)
                }
            }
        }
    }

    private func runTranslate() {
        let cid = item.id
        guard PipelineWorker.shared.tryLockContent(cid) else {
            statusMsg = "⏳ 该篇正在后台处理中，请稍候"
            return
        }
        busy = true
        busyForId = cid
        statusMsg = "翻译中…"
        Task {
            // 媒体项：翻译 feed 简介 → llm_excerpt_translated（「译文」标签）；
            // 非媒体项：翻译正文 → llm_translated_md（译文/原文切换）
            let ok: Bool
            if isMediaItem {
                ok = await pipeline.translateExcerpt(contentId: cid, title: item.title, contentHtml: item.excerpt ?? item.contentHtml ?? "")
            } else {
                ok = await pipeline.translate(contentId: cid, title: item.title, body: contentBody)
            }
            if ok { ArchiveService.shared.rearchive(contentId: cid) }
            await MainActor.run {
                PipelineWorker.shared.unlockContent(cid)
                guard busyForId == cid else { return }
                busy = false
                statusMsg = ok ? "✅ 翻译完成" : "❌ 翻译失败"
                if ok {
                    refreshLoadedBody()
                    // 非媒体：仅原文→双语对照；媒体：切到「译文」标签立刻看到
                    if isMediaItem { mediaTab = 1 }
                    else if viewMode == 1 { viewMode = 0 }
                    NotificationCenter.default.post(name: .contentUpdated, object: nil)
                }
            }
        }
    }

    private func runSummarize() {
        let cid = item.id
        guard PipelineWorker.shared.tryLockContent(cid) else {
            statusMsg = "⏳ 该篇正在后台处理中，请稍候"
            return
        }
        busy = true
        busyForId = cid
        statusMsg = "摘要中…"
        Task {
            let ok = await pipeline.summarize(contentId: cid, title: item.title, body: contentBody)
            if ok { ArchiveService.shared.rearchive(contentId: cid) }
            await MainActor.run {
                PipelineWorker.shared.unlockContent(cid)
                guard busyForId == cid else { return }
                busy = false
                statusMsg = ok ? "✅ 摘要完成" : "❌ 摘要失败"
                if ok {
                    refreshLoadedBody()
                    NotificationCenter.default.post(name: .contentUpdated, object: nil)
                }
            }
        }
    }

    private func runTranscribe() {
        let cid = item.id
        guard PipelineWorker.shared.tryLockContent(cid) else {
            statusMsg = "⏳ 该篇正在后台处理中，请稍候"
            return
        }
        busy = true
        busyForId = cid
        statusMsg = "转录中（下载+识别，较长）…"
        Task {
            let ok = await transcriber.transcribe(
                contentId: cid, title: item.title, audioUrl: item.audioUrl, pageUrl: item.url, language: item.language)
            if ok { ArchiveService.shared.rearchive(contentId: cid) }
            await MainActor.run {
                PipelineWorker.shared.unlockContent(cid)
                guard busyForId == cid else { return }
                busy = false
                statusMsg = ok ? "✅ 转录完成" : "❌ 转录失败"
                if ok {
                    refreshLoadedBody()
                    // 翻译完成：若当前是仅原文，切到双语对照让用户立刻看到译文
                    if viewMode == 1 { viewMode = 0 }
                    NotificationCenter.default.post(name: .contentUpdated, object: nil)
                }
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
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""

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
                shareActionRow("重新生成 Markdown 文件", icon: "arrow.clockwise.doc") {
                    ArchiveService.shared.rearchive(contentId: item.id)
                    message = "✅ 已重新生成 Markdown 文件"
                }
                shareActionRow("触发导出规则（Obsidian / webhook）", icon: "square.and.arrow.up.on.square") {
                    Task {
                        await ExportService.shared.runPending(trigger: "manual", contentId: item.id)
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
            ("a", "归档 / 取消归档"),
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
