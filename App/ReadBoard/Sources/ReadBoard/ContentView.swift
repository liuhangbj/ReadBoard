import SwiftUI

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
                    .font(.caption)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .shadow(radius: 4)
                    .padding(.bottom, 16)
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
    @State private var showAddFolder = false
    @State private var newFolderName = ""
    /// 重命名目标（source: 源 id / folder: 文件夹 id）+ 输入名 + 弹窗状态
    @State private var renameTarget: (kind: String, id: Int64, currentName: String)? = nil
    @State private var renameInput = ""
    /// 展开的文件夹 id 集合（自己控制，DisclosureGroup 的 label 无法响应点击过滤）
    @State private var expandedFolders: Set<String> = []
    /// 开管线后弹「如何处理历史数据」（kind: source/folder，action: pipeline=LLM管线回填 / fulltext=全文重抓）
    @State private var pendingBackfill: (kind: String, id: Int64, name: String, pipelineLabel: String, action: String)? = nil

    private var sourceSidebar: some View {
        VStack(spacing: 0) {
            // 顶部工具条：添加源 / 添加文件夹
            HStack(spacing: 4) {
                Text("订阅源")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showAddFolder = true } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("新建文件夹")
                Button { showAddSource = true } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("添加订阅源")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // ── 全部文章（清空过滤，显示所有内容）──
                    allArticlesRow

                    ForEach(vm.sidebarTree) { node in
                        if node.isFolder {
                            // 文件夹行：左侧箭头控制展开，点击行过滤该组
                            HStack(spacing: 4) {
                                Button {
                                    if expandedFolders.contains(node.id) {
                                        expandedFolders.remove(node.id)
                                    } else {
                                        expandedFolders.insert(node.id)
                                    }
                                } label: {
                                    Image(systemName: expandedFolders.contains(node.id) ? "chevron.down" : "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 14)
                                }
                                .buttonStyle(.plain)

                                sidebarRow(node, indent: 0)
                            }
                            // 展开的子源
                            if expandedFolders.contains(node.id) {
                                ForEach(node.children ?? []) { child in
                                    sidebarRow(child, indent: 1)
                                }
                            }
                        } else {
                            sidebarRow(node, indent: 0)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // ── 底部导航：订阅源管理 / 数据统计（替代底部 Tab 栏）──
            Divider()
            HStack(spacing: 0) {
                sidebarNavButton(icon: "dot.radiowaves.left.and.right", label: "订阅源", tab: 1)
                sidebarNavButton(icon: "chart.bar.doc.horizontal", label: "管理", tab: 3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .sheet(isPresented: $showAddSource) {
            AddSourceSheet(store: sourceStore)
                .onDisappear { vm.loadAll() }
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
            Button(pendingBackfill?.action == "fulltext" ? "重抓所有历史全文" : "处理所有历史并重新生成 md") {
                if let p = pendingBackfill {
                    if p.action == "fulltext" {
                        if p.kind == "folder" {
                            Task { await PipelineWorker.shared.refetchFullTextForFolder(folderId: p.id) }
                        } else {
                            Task { await PipelineWorker.shared.refetchFullTextForSource(onlySourceId: p.id) }
                        }
                    } else {
                        if p.kind == "folder" {
                            Task { await PipelineWorker.shared.backfillHistoryForFolder(folderId: p.id) }
                        } else {
                            Task { await PipelineWorker.shared.backfillHistory(onlySourceId: p.id) }
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
                    Text("「\(p.name)」的\(p.pipelineLabel)已开启。\n\n• 处理历史：存量文章补跑管线并刷新已生成的 md 文件（耗时较长，按量计费）\n• 只处理新增：历史不动，新抓的自动走管线")
                }
            }
        }
        .onAppear {
            // 默认展开所有文件夹（用户能直接看到源，不用先点一下）
            expandedFolders = Set(vm.sidebarTree.filter { $0.isFolder }.map { $0.id })
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
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开「\(label)」页面")
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
                    .foregroundStyle(active ? .white : .secondary)
                    .frame(width: 16)
                Text("全部文章")
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(active ? .white : .primary)
                Spacer()
                Text("\(vm.totalCount)")
                    .foregroundStyle(active ? .white.opacity(0.8) : .secondary)
                    .font(.system(size: 11 * scale))
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.vertical, 6 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 左栏行（点击过滤 + 未读角标 + 右键设置菜单）。
    /// Button 而非 List.tag——List selection 对 DisclosureGroup/自定义行不可靠。
    private func sidebarRow(_ node: SidebarNode, indent: Int) -> some View {
        let scale = uiFontScale
        return Button {
            vm.selectFilter(node.filterKey)
        } label: {
            HStack(spacing: 6) {
                if node.isFolder {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                Text(node.name)
                    .lineLimit(1)
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(vm.selectedFilter == node.filterKey ? .white : .primary)
                Spacer()
                // 始终显示 未读/总数（未读 > 0 时未读部分蓝色高亮，读完则灰色）
                HStack(spacing: 1) {
                    Text("\(node.unread)")
                        .font(.system(size: 11 * scale, weight: node.unread > 0 ? .bold : .regular))
                        .foregroundStyle(node.unread > 0
                            ? (vm.selectedFilter == node.filterKey ? .white : .accentColor)
                            : (vm.selectedFilter == node.filterKey ? .white.opacity(0.8) : .secondary))
                    Text("/\(node.count)")
                        .font(.system(size: 11 * scale))
                        .foregroundStyle(vm.selectedFilter == node.filterKey ? .white.opacity(0.8) : .secondary)
                }
            }
            .padding(.leading, CGFloat(indent) * 18 + 12)
            .padding(.trailing, 12)
            .padding(.vertical, 6 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(vm.selectedFilter == node.filterKey ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                Menu("内容处理管道") {
                    pipelineToggleMenu(src: src)
                }
                Menu("抓取设置") {
                    fetchSettingsMenu(src: src)
                }
                Divider()
                Menu("移动到文件夹") {
                    Button("无文件夹") { sourceStore.assignSource(sourceId: sid, folderId: nil); vm.loadAll() }
                    ForEach(sourceStore.folders) { f in
                        Button(f.name) { sourceStore.assignSource(sourceId: sid, folderId: f.id); vm.loadAll() }
                    }
                }
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
                Label("刷新此文件夹全部源", systemImage: "arrow.clockwise")
            }
            Button { markFolderRead(fid) } label: {
                Label("全部标为已读", systemImage: "checkmark.circle")
            }
            Divider()
            if let folder = sourceStore.folders.first(where: { $0.id == fid }) {
                Menu("组级管线总开关") {
                    folderPipelineMenu(folder: folder)
                }
            }
            // 全文抓取模式（对文件夹内所有源批量设置）
            Menu("全文抓取模式") {
                ForEach(FetchMode.allCases, id: \.rawValue) { m in
                    Button {
                        sourceStore.setFolderFetchMode(folderId: fid, mode: m)
                        // 切换后弹「如何处理历史数据」（重抓全文或只新增）
                        pendingBackfill = ("folder", fid, node.name, m.displayName, "fulltext")
                    } label: {
                        Text(m.displayName)
                    }
                }
            }
            Button(role: .destructive) { sourceStore.removeFolder(id: fid); vm.loadAll() } label: {
                Label("删除文件夹", systemImage: "trash")
            }
        }
    }

    /// 源级管线开关菜单（打勾状态实时反映）
    @ViewBuilder
    private func pipelineToggleMenu(src: FeedSource) -> some View {
        pipelineMenuItem("AI 打分", key: "auto_score", on: src.policy.autoScore, src: src)
        pipelineMenuItem("AI 翻译", key: "auto_translate", on: src.policy.autoTranslate, src: src)
        pipelineMenuItem("AI 摘要", key: "auto_summarize", on: src.policy.autoSummarize, src: src)
        if src.transcribable {
            pipelineMenuItem("转录", key: "auto_transcribe", on: src.policy.autoTranscribe, src: src)
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
            Label(label, systemImage: on ? "checkmark" : "")
        }
    }

    /// 抓取设置菜单（fetch_mode + 频率）
    @ViewBuilder
    private func fetchSettingsMenu(src: FeedSource) -> some View {
        Menu("全文模式：\(src.fetchMode.displayName)") {
            ForEach(FetchMode.allCases, id: \.rawValue) { m in
                Button {
                    let changed = src.fetchMode != m
                    sourceStore.setFetchMode(id: src.id, mode: m)
                    // 切换全文模式后弹「如何处理历史数据」（重抓全文或只新增）
                    if changed {
                        pendingBackfill = ("source", src.id, src.name, m.displayName, "fulltext")
                    }
                } label: {
                    Label(m.displayName, systemImage: src.fetchMode == m ? "checkmark" : "")
                }
            }
            Divider()
            Button("重新探测") { Task { await sourceStore.reprobeFetchMode(id: src.id) } }
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

    /// 文件夹级管线总开关菜单
    @ViewBuilder
    private func folderPipelineMenu(folder: Folder) -> some View {
        folderMenuItem("AI 打分", key: "auto_score", on: folder.policy.autoScore, folder: folder)
        folderMenuItem("AI 翻译", key: "auto_translate", on: folder.policy.autoTranslate, folder: folder)
        folderMenuItem("AI 摘要", key: "auto_summarize", on: folder.policy.autoSummarize, folder: folder)
        folderMenuItem("转录", key: "auto_transcribe", on: folder.policy.autoTranscribe, folder: folder)
    }

    private func folderMenuItem(_ label: String, key: String, on: Bool, folder: Folder) -> some View {
        Button {
            let turningOn = !on
            sourceStore.setFolderPolicy(id: folder.id, key: key, value: turningOn)
            // 开启时弹「如何处理历史数据」（和订阅源页一致）
            if turningOn {
                pendingBackfill = ("folder", folder.id, folder.name, label, "pipeline")
            }
        } label: {
            Label(label, systemImage: on ? "checkmark" : "")
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

    /// 处理状态平铺多选按钮（激活高亮，点击切换加入/移出多选集）
    private func processedToggle(key: String, label: String) -> some View {
        let active = vm.processedFilters.contains(key)
        return Button {
            if active { vm.processedFilters.remove(key) }
            else { vm.processedFilters.insert(key) }
            vm.reload()
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(active ? Color.accentColor : Color.gray.opacity(0.12))
                .foregroundStyle(active ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private var articleList: some View {
        VStack(spacing: 0) {
            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("搜索标题 / 正文", text: $vm.keyword)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
                    .onChange(of: searchFocused) { _, f in vm.searchFocused = f }
                    .onChange(of: vm.keyword) { _, _ in vm.reloadDebounced() }
                if !vm.keyword.isEmpty {
                    Button { vm.keyword = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5))

            // 筛选条行1：评分(输入框) + 标签 + 未读/全部/星标(单选) + 归档
            HStack {
                Text("评分 ≥")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("0", value: $vm.minScore, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                    .font(.caption)
                    .onSubmit { vm.reload() }
                    .onChange(of: vm.minScore) { _, _ in vm.reloadDebounced() }
                if vm.minScore > 0 {
                    Toggle("含未评分", isOn: $vm.includeUnscored)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .controlSize(.small)
                        .onChange(of: vm.includeUnscored) { _, _ in vm.reload() }
                }

                Spacer()

                // 全部/未读/星标/归档 四选一单选（分段控件）
                Picker("", selection: $vm.readFilter) {
                    ForEach(ContentViewModel.ReadFilter.allCases, id: \.self) { f in
                        Text(f.display).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                .controlSize(.small)
                .onChange(of: vm.readFilter) { _, _ in vm.reload() }

                // 排序选择（最新/最早/评分）
                Picker(selection: $vm.sortOrder) {
                    ForEach(ContentViewModel.SortOrder.allCases) { o in
                        Text(o.display).tag(o)
                    }
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 80)
                .font(.caption)
                .controlSize(.small)
                .onChange(of: vm.sortOrder) { _, _ in vm.reload() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            // 筛选条行2：处理状态平铺多选按钮（打分/摘要/翻译/转录，可多选）
            HStack(spacing: 6) {
                Text("处理")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                processedToggle(key: "score", label: "已打分")
                processedToggle(key: "summary", label: "已摘要")
                processedToggle(key: "translate", label: "已翻译")
                processedToggle(key: "transcribe", label: "已转录")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            // 操作条：全部标已读 + 计数
            HStack {
                Text("\(vm.items.count) 条")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    let n = vm.markAllRead()
                    _ = n
                } label: {
                    Label("全部已读", systemImage: "checkmark.circle")
                        .font(.caption)
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)

            List(selection: Binding(
                get: { vm.selectedItem },
                set: { if let it = $0 { vm.open(it) } }
            )) {
                ForEach(vm.items) { item in
                    ArticleRow(item: item, isSelected: vm.selectedItem?.id == item.id)
                        .tag(item)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                        .contextMenu {
                            Button(item.isRead ? "标为未读" : "标为已读") { vm.toggleRead(item) }
                            Button(item.starred ? "取消星标" : "加星标") { vm.toggleStar(item) }
                            Button(item.archived ? "取消归档" : "归档") { vm.toggleArchive(item) }
                            Divider()
                            Button("复制链接") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.url, forType: .string)
                            }
                            Button("浏览器打开原文") {
                                if let url = URL(string: item.url), !item.url.isEmpty {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            Divider()
                            Button("重新生成 md 文件") {
                                ArchiveService.shared.rearchive(contentId: item.id)
                            }
                            Button("触发导出规则") {
                                Task { await ExportService.shared.runPending(trigger: "manual", contentId: item.id) }
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

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: isCompact ? 2 : 5) {
                // 标题行（评分挪到下方来源行了，标题行只留标题 + 星标）
                HStack(alignment: .top, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 15 * scale, weight: (unreadBold && !item.isRead) ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : (item.isRead ? .secondary : .primary))
                        .lineLimit(isCompact ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.starred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(isSelected ? .white : .yellow)
                            .font(.system(size: 11 * scale))
                    }
                    Spacer(minLength: 0)
                }
                // 摘要（行数可配，0 = 不显示）
                if excerptLines > 0, let ex = item.excerpt, !ex.isEmpty {
                    Text(ex)
                        .font(.system(size: 12.5 * scale))
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                        .lineLimit(excerptLines)
                }
                // 来源 + 评分标签 + 日期（评分挪到标题下面这行，在 RSS 来源旁边）
                HStack(spacing: 8) {
                    if showSource {
                        Text(item.source)
                            .font(.system(size: 11 * scale, weight: .medium))
                            .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
                    }
                    // 评分背景色标签（按分数段配色，跟在来源后）
                    if let s = item.llmScore {
                        Text("\(s)")
                            .font(.system(size: 10 * scale).bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(isSelected ? Color.white.opacity(0.25) : scoreColor(s).opacity(0.18))
                            .foregroundStyle(isSelected ? .white : scoreColor(s))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    // 四项管线已处理标签（有结果才显示，跟在评分后）
                    if let sum = item.llmSummary, !sum.isEmpty {
                        pipelineBadge("摘", color: .purple, isSelected: isSelected)
                    }
                    if item.hasTranslation {
                        // 媒体项译文来自转录，标「录」；文章标「译」
                        pipelineBadge(item.isMedia ? "录" : "译", color: .blue, isSelected: isSelected)
                    }
                    if showDate, let pd = item.publishedAt, pd.count >= 10 {
                        Text(formattedDate(pd))
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(isSelected ? .white.opacity(0.7) : Color(nsColor: .tertiaryLabelColor))
                    }
                    Spacer()
                    if !item.isRead && !isSelected {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    }
                }
            }
            // 右侧缩略图（可关；紧凑模式更小）
            if showThumbnails, let img = item.imageUrl, let url = URL(string: img) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure, .empty:
                        Rectangle().fill(Color.gray.opacity(0.15))
                    @unknown default:
                        Rectangle().fill(Color.gray.opacity(0.15))
                    }
                }
                .frame(width: (isCompact ? 48 : 72) * scale, height: (isCompact ? 48 : 72) * scale)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isCompact ? 5 : 10)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
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

    private func scoreColor(_ s: Int) -> Color {
        switch s {
        case 80...: return .green
        case 60..<80: return .orange
        case 40..<60: return .yellow
        default: return .gray
        }
    }

    /// 管线已处理小标签（摘/译/录，单字背景色标签）
    private func pipelineBadge(_ text: String, color: Color, isSelected: Bool) -> some View {
        Text(text)
            .font(.system(size: 9 * scale).bold())
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(isSelected ? Color.white.opacity(0.25) : color.opacity(0.18))
            .foregroundStyle(isSelected ? .white : color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
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
    /// 版面设置
    @State private var fontSize = ReadingLayout.fontSize
    @State private var lineSpacing = ReadingLayout.lineSpacing
    @State private var contentWidth = ReadingLayout.contentWidth
    @State private var theme = ReadingTheme.current
    @State private var themeMode = ReadingTheme.Mode.current
    @State private var fontChoice = ReadingFont.current
    @State private var titleFontSize = ReadingLayout.titleFontSize
    @State private var metaFontSize = ReadingLayout.metaFontSize
    @State private var summaryFontSize = ReadingLayout.summaryFontSize
    /// 界面缩放（@AppStorage 直绑——layoutPanel 里改这里视图自动刷新，
    /// 同时 ContentView/ArticleRow 的同名 @AppStorage 也会跟着重建，全局生效）
    @AppStorage("reading.uiFontScale") private var uiFontScale: Double = 1.0
    @State private var showLayoutPopover = false
    @State private var showShareSheet = false
    /// 星标/已读状态（本地镜像，操作后即时反馈，不依赖 reload）
    @State private var isStarred = false
    @State private var isRead = false

    public var body: some View {
        VStack(spacing: 0) {
            // ── 顶部操作条：快捷操作（星标/已读/归档/分享）+ 版面设置 ──
            HStack(spacing: 14) {
                // 快捷操作
                Button { toggleStar() } label: {
                    Image(systemName: isStarred ? "star.fill" : "star")
                        .foregroundStyle(isStarred ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isStarred ? "取消星标" : "加星标")

                Button { toggleRead() } label: {
                    Image(systemName: isRead ? "envelope.open" : "envelope.badge")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(isRead ? "标为未读" : "标为已读")

                Button { toggleArchive() } label: {
                    Image(systemName: item.archived ? "tray.and.arrow.up" : "archivebox")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(item.archived ? "取消归档" : "归档")

                Button { showShareSheet = true } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("分享 / 后处理")

                Spacer()

                // 双语/原文/翻译切换（有翻译时）：双语对照 / 仅原文 / 仅译文
                if item.llmTranslatedMd != nil {
                    Picker("", selection: $viewMode) {
                        Text("双语").tag(0)
                        Text("原文").tag(1)
                        Text("译文").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    .controlSize(.small)
                }

                // 版面设置
                Button { showLayoutPopover = true } label: {
                    Image(systemName: "textformat.size")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("版面设置")
                .popover(isPresented: $showLayoutPopover, arrowEdge: .bottom) {
                    layoutPanel
                }

                // 上一篇/下一篇（键盘 j/k 的图形化对应）
                HStack(spacing: 2) {
                    Button { onPrev?() } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .help("上一篇（k）")
                    .disabled(onPrev == nil)
                    Button { onNext?() } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .help("下一篇（j）")
                    .disabled(onNext == nil)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // ── 正文滚动区 ──
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 标题 + 元信息（独立字号设置；标题字体跟用户字体选择走，不被主题强制）
                    Text(item.title)
                        .font(fontChoice.font(size: titleFontSize).bold())
                        .foregroundStyle(p.text)
                    HStack(spacing: 10) {
                        if let a = item.author, !a.isEmpty { Label(a, systemImage: "person") }
                        if let pd = item.publishedAt { Label(String(pd.prefix(10)), systemImage: "calendar") }
                        if let s = item.llmScore { Label("评分 \(s)", systemImage: "star.fill") }
                    }
                    .font(.system(size: metaFontSize))
                    .foregroundStyle(p.textSecondary)

                    // ── LLM 操作条 ──
                    HStack(spacing: 10) {
                        if isMediaItem, item.llmTranslatedMd == nil, policy.autoTranscribe {
                            Button { runTranscribe() } label: {
                                Label("转录", systemImage: "waveform")
                            }
                            .disabled(busy)
                        }
                        if !pipeline.isAvailable {
                            if !isMediaItem {
                                Label("未配置 LLM Key", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        } else {
                            if item.llmScore == nil, policy.autoScore {
                                Button { runScore() } label: {
                                    Label("AI 评分", systemImage: "star")
                                }
                                .disabled(busy)
                            }
                            if item.llmSummary == nil, policy.autoSummarize {
                                Button { runSummarize() } label: {
                                    Label("摘要", systemImage: "text.quote")
                                }
                                .disabled(busy)
                            }
                            if !isMediaItem, item.llmTranslatedMd == nil, policy.autoTranslate {
                                Button { runTranslate() } label: {
                                    Label("AI 翻译", systemImage: "character.bubble")
                                }
                                .disabled(busy)
                            }
                            if busy {
                                ProgressView().scaleEffect(0.7)
                            }
                            if let msg = statusMsg {
                                Text(msg)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }

                    Divider()

                    // 摘要（独立字号设置）
                    if let sum = item.llmSummary, !sum.isEmpty {
                        Text(sum)
                            .font(.system(size: summaryFontSize))
                            .foregroundStyle(p.textSecondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(p.backgroundAlt)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // 正文：有译文时双语逐段对照（Follo 核心交互），否则单语 markdown
                    // 双语原文用 bodyText（contentMd ?? excerpt）——绝大多数文章 content_md
                    // 是空的（正文在 content_html/excerpt，全文未抓），只看 contentMd 会把
                    // 几乎所有译文文章挡在双语门外，掉到单语只显示原文。
                    if bilingualMode, let translated = item.llmTranslatedMd, !translated.isEmpty {
                        BilingualBodyView(
                            original: bodyText,
                            translated: translated,
                            theme: theme,
                            mode: themeMode,
                            fontChoice: fontChoice,
                            fontSize: fontSize,
                            lineSpacing: lineSpacing
                        )
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarkdownBodyView(
                            markdown: bodyText,
                            theme: theme,
                            mode: themeMode,
                            fontChoice: fontChoice,
                            fontSize: fontSize,
                            lineSpacing: lineSpacing
                        )
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(24)
                .frame(maxWidth: contentWidth)
                .frame(maxWidth: .infinity)   // 内容限宽后居中
            }
            .background(p.background)   // 主题底色
        }
        // 视图随 .id(item.id) 重建，onAppear 即切文章——刷新有效开关与本地状态
        .onAppear {
            policy = Database.shared.effectivePolicyFor(contentId: item.id)
            isStarred = item.starred
            isRead = item.isRead
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(item: item)
        }
    }

    /// 版面设置面板
    private var layoutPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("版面设置").font(.headline)

            // 主题 + 亮/暗
            HStack {
                Text("主题").frame(width: 60, alignment: .leading)
                Picker("", selection: $theme) {
                    ForEach(ReadingTheme.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: theme) { _, v in ReadingTheme.current = v }
            }
            HStack {
                Text("亮暗").frame(width: 60, alignment: .leading)
                Picker("", selection: $themeMode) {
                    ForEach(ReadingTheme.Mode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: themeMode) { _, v in ReadingTheme.Mode.current = v }
            }

            // 字号（正文/标题/信息/摘要 分块独立 + 界面）
            HStack {
                Text("正文字号").frame(width: 60, alignment: .leading)
                Stepper(value: $fontSize, in: 12...28, step: 1) {
                    Text("\(Int(fontSize))").font(.callout.monospacedDigit())
                }
                .onChange(of: fontSize) { _, v in ReadingLayout.fontSize = v }
            }
            HStack {
                Text("标题字号").frame(width: 60, alignment: .leading)
                Stepper(value: $titleFontSize, in: 16...40, step: 1) {
                    Text("\(Int(titleFontSize))").font(.callout.monospacedDigit())
                }
                .onChange(of: titleFontSize) { _, v in ReadingLayout.titleFontSize = v }
            }
            HStack {
                Text("信息字号").frame(width: 60, alignment: .leading)
                Stepper(value: $metaFontSize, in: 9...18, step: 1) {
                    Text("\(Int(metaFontSize))").font(.callout.monospacedDigit())
                }
                .onChange(of: metaFontSize) { _, v in ReadingLayout.metaFontSize = v }
            }
            HStack {
                Text("摘要字号").frame(width: 60, alignment: .leading)
                Stepper(value: $summaryFontSize, in: 10...22, step: 1) {
                    Text("\(Int(summaryFontSize))").font(.callout.monospacedDigit())
                }
                .onChange(of: summaryFontSize) { _, v in ReadingLayout.summaryFontSize = v }
            }
            HStack {
                Text("界面缩放").frame(width: 60, alignment: .leading)
                Slider(value: $uiFontScale, in: 0.8...1.5, step: 0.05) { _ in
                    ReadingLayout.uiFontScale = uiFontScale
                }
                Text(String(format: "%.0f%%", uiFontScale * 100)).frame(width: 40).font(.callout.monospacedDigit())
            }

            // 字体（预置 黑体/楷体/仿宋 + 系统字体列表任选，不手输）
            HStack {
                Text("字体").frame(width: 60, alignment: .leading)
                Picker("", selection: $fontChoice) {
                    // 预置组
                    ForEach(ReadingFont.presets, id: \.self) { f in
                        Text(f.displayName).tag(f)
                    }
                    Divider()
                    // 系统字体列表（每个用自身字体渲染预览，所见即所得）
                    ForEach(ReadingFont.availableFontFamilies, id: \.self) { family in
                        Text(family)
                            .font(.custom(family, size: 13))
                            .tag(ReadingFont.custom(family))
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: fontChoice) { _, v in ReadingFont.current = v }
            }

            // 行距
            HStack {
                Text("行距").frame(width: 60, alignment: .leading)
                Slider(value: $lineSpacing, in: 0...16, step: 1) { _ in
                    ReadingLayout.lineSpacing = lineSpacing
                }
                Text("\(Int(lineSpacing))").frame(width: 24).font(.callout.monospacedDigit())
            }

            // 宽度
            HStack {
                Text("宽度").frame(width: 60, alignment: .leading)
                Picker("", selection: $contentWidth) {
                    Text("窄").tag(560.0)
                    Text("中").tag(720.0)
                    Text("宽").tag(960.0)
                }
                .pickerStyle(.segmented)
                .onChange(of: contentWidth) { _, v in ReadingLayout.contentWidth = v }
            }
        }
        .padding()
        .frame(width: 360)
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
    @AppStorage("reading.viewMode") private var viewMode = 0

    /// 双语对照模式（viewMode=0 且有译文）
    private var bilingualMode: Bool {
        viewMode == 0 && item.llmTranslatedMd != nil
    }

    private var bodyText: String {
        // 仅译文：有译文显示译文；无译文（还没翻译）显示提示而非掉回原文
        if viewMode == 2 {
            if let t = item.llmTranslatedMd, !t.isEmpty { return t }
            return "（本篇尚未翻译——点上方「AI 翻译」生成译文后此处显示）"
        }
        // 双语/仅原文：优先原文 md
        if let md = item.contentMd, !md.isEmpty { return md }
        return item.excerpt ?? "(无内容)"
    }

    /// 是否媒体项（播客/视频，可转录）
    private var isMediaItem: Bool {
        item.ctype == "podcast" || item.ctype == "video" || item.audioUrl != nil
    }

    /// 当前 palette（按 themeMode 取——亮/暗切换即时生效）
    private var p: ThemePalette { theme.palette(for: themeMode) }

    // MARK: - LLM 操作

    /// 评分/翻译用的正文：优先 markdown，退回 excerpt
    private var contentBody: String {
        if let md = item.contentMd, !md.isEmpty { return md }
        return item.excerpt ?? ""
    }

    private func runScore() {
        let cid = item.id
        busy = true
        busyForId = cid
        statusMsg = "评分中…"
        Task {
            let ok = await pipeline.score(contentId: cid, title: item.title, body: contentBody)
            if ok { ArchiveService.shared.rearchive(contentId: cid) }   // 手动重处理 → 刷新归档文件
            await MainActor.run {
                guard busyForId == cid else { return }   // 已切走，不覆盖新文章状态
                busy = false
                statusMsg = ok ? "✅ 评分完成" : "❌ 评分失败"
                if ok { NotificationCenter.default.post(name: .contentUpdated, object: nil) }
            }
        }
    }

    private func runTranslate() {
        let cid = item.id
        busy = true
        busyForId = cid
        statusMsg = "翻译中…"
        Task {
            let ok = await pipeline.translate(contentId: cid, title: item.title, body: contentBody)
            if ok { ArchiveService.shared.rearchive(contentId: cid) }
            await MainActor.run {
                guard busyForId == cid else { return }
                busy = false
                statusMsg = ok ? "✅ 翻译完成" : "❌ 翻译失败"
                if ok {
                    // 翻译完成：若当前是仅原文，切到双语对照让用户立刻看到译文
                    if viewMode == 1 { viewMode = 0 }
                    NotificationCenter.default.post(name: .contentUpdated, object: nil)
                }
            }
        }
    }

    private func runSummarize() {
        let cid = item.id
        busy = true
        busyForId = cid
        statusMsg = "摘要中…"
        Task {
            let ok = await pipeline.summarize(contentId: cid, title: item.title, body: contentBody)
            if ok { ArchiveService.shared.rearchive(contentId: cid) }
            await MainActor.run {
                guard busyForId == cid else { return }
                busy = false
                statusMsg = ok ? "✅ 摘要完成" : "❌ 摘要失败"
                if ok { NotificationCenter.default.post(name: .contentUpdated, object: nil) }
            }
        }
    }

    private func runTranscribe() {
        let cid = item.id
        busy = true
        busyForId = cid
        statusMsg = "转录中（下载+识别，较长）…"
        Task {
            let ok = await transcriber.transcribe(
                contentId: cid, title: item.title, audioUrl: item.audioUrl, pageUrl: item.url, language: item.language)
            if ok { ArchiveService.shared.rearchive(contentId: cid) }
            await MainActor.run {
                guard busyForId == cid else { return }
                busy = false
                statusMsg = ok ? "✅ 转录完成" : "❌ 转录失败"
                if ok {
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
        VStack(alignment: .leading, spacing: 16) {
            Text("分享 / 后处理").font(.title3.bold())
            Text(item.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url, forType: .string)
                    message = "✅ 链接已复制"
                } label: {
                    Label("复制链接", systemImage: "link")
                }

                Button {
                    let text = "\(item.title)\n\(item.url)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    message = "✅ 标题+链接已复制"
                } label: {
                    Label("复制标题+链接", systemImage: "doc.on.doc")
                }

                Button {
                    if let url = URL(string: item.url), !item.url.isEmpty {
                        NSWorkspace.shared.open(url)
                    }
                    dismiss()
                } label: {
                    Label("在浏览器打开原文", systemImage: "safari")
                }

                Divider()

                Button {
                    ArchiveService.shared.rearchive(contentId: item.id)
                    message = "✅ 已重新生成 md 文件"
                } label: {
                    Label("重新生成 md 文件", systemImage: "arrow.clockwise.doc")
                }

                Button {
                    Task {
                        await ExportService.shared.runPending(trigger: "manual", contentId: item.id)
                        message = "✅ 已触发手动导出规则"
                    }
                } label: {
                    Label("触发导出规则（Obsidian/webhook）", systemImage: "square.and.arrow.up.on.square")
                }
            }
            .buttonStyle(.borderless)

            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.green)
            }

            Spacer()
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380, height: 420)
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
                Text("键盘快捷键").font(.title3.bold())
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ForEach(groups, id: \.0) { group, rows in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group).font(.headline).foregroundStyle(.secondary)
                    ForEach(rows, id: \.0) { key, desc in
                        HStack {
                            Text(key)
                                .font(.system(.callout, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .frame(minWidth: 70, alignment: .center)
                            Text(desc).font(.callout)
                            Spacer()
                        }
                    }
                }
            }

            Text("提示：搜索框聚焦时，j/k/空格 等单键快捷键自动禁用，避免与输入冲突。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
    }
}
