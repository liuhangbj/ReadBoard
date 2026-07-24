import SwiftUI

public struct ContentView: View {
    @StateObject private var vm = ContentViewModel()
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
    }

    // MARK: 快捷键（隐藏按钮承载键盘事件）
    // j/k 上下篇, s 星标, a 归档, 空格已读切换, v 开原文
    private var shortcutHandlers: some View {
        Group {
            Button("") { vm.selectNext() }.keyboardShortcut("j", modifiers: [])
            Button("") { vm.selectPrev() }.keyboardShortcut("k", modifiers: [])
            Button("") { if let it = vm.selectedItem { vm.toggleStar(it) } }.keyboardShortcut("s", modifiers: [])
            Button("") { if let it = vm.selectedItem { vm.toggleArchive(it) } }.keyboardShortcut("a", modifiers: [])
            Button("") { vm.shortcutToggleRead() }.keyboardShortcut(.space, modifiers: [])
            Button("") { openOriginal() }.keyboardShortcut("v", modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
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
    /// 展开的文件夹 id 集合（自己控制，DisclosureGroup 的 label 无法响应点击过滤）
    @State private var expandedFolders: Set<String> = []

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
                    // 固定分类（Follo 式置顶）：全部 / 未读 / 星标 / 归档
                    allRow
                    quickFilterRow(icon: "envelope.badge", name: "未读",
                                   isActive: vm.readFilter == .unread) {
                        vm.readFilter = vm.readFilter == .unread ? .all : .unread
                        vm.reload()
                    }
                    quickFilterRow(icon: "star", name: "星标",
                                   isActive: vm.readFilter == .starred) {
                        vm.readFilter = vm.readFilter == .starred ? .all : .starred
                        vm.reload()
                    }
                    quickFilterRow(icon: "archivebox", name: "归档",
                                   isActive: vm.showArchived) {
                        vm.showArchived.toggle()
                        vm.reload()
                    }

                    Divider().padding(.vertical, 6)

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
        .onAppear {
            // 默认展开所有文件夹（用户能直接看到源，不用先点一下）
            expandedFolders = Set(vm.sidebarTree.filter { $0.isFolder }.map { $0.id })
        }
    }

    /// "全部"行（点击清空过滤）
    private var allRow: some View {
        Button {
            vm.selectFilter(nil)
            vm.readFilter = .all
            vm.showArchived = false
            vm.reload()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("全部")
                    .foregroundStyle(vm.selectedFilter == nil && vm.readFilter == .all && !vm.showArchived ? .white : .primary)
                Spacer()
                Text("\(vm.totalCount)")
                    .foregroundStyle(vm.selectedFilter == nil && vm.readFilter == .all && !vm.showArchived ? .white.opacity(0.8) : .secondary)
                    .font(.caption)
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(vm.selectedFilter == nil && vm.readFilter == .all && !vm.showArchived ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 固定分类快捷行（未读/星标/归档）
    private func quickFilterRow(icon: String, name: String, isActive: Bool,
                                action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(isActive ? .white : .secondary)
                    .frame(width: 16)
                Text(name)
                    .foregroundStyle(isActive ? .white : .primary)
                Spacer()
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? Color.accentColor : Color.clear)
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
                // 未读角标（未读 > 0 显示；否则显示总数）
                if node.unread > 0 {
                    Text("\(node.unread)")
                        .font(.system(size: 11 * scale).bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(vm.selectedFilter == node.filterKey ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.2))
                        .foregroundStyle(vm.selectedFilter == node.filterKey ? .white : .accentColor)
                        .clipShape(Capsule())
                } else {
                    Text("\(node.count)")
                        .foregroundStyle(vm.selectedFilter == node.filterKey ? .white.opacity(0.8) : .secondary)
                        .font(.system(size: 11 * scale))
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
            sourceStore.setPolicy(id: src.id, key: key, value: !on)
        } label: {
            Label(label, systemImage: on ? "checkmark" : "")
        }
    }

    /// 抓取设置菜单（fetch_mode + 频率）
    @ViewBuilder
    private func fetchSettingsMenu(src: FeedSource) -> some View {
        Menu("全文模式：\(src.fetchMode.displayName)") {
            ForEach(FetchMode.allCases, id: \.rawValue) { m in
                Button { sourceStore.setFetchMode(id: src.id, mode: m) } label: {
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
            sourceStore.setFolderPolicy(id: folder.id, key: key, value: !on)
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

            // 筛选条：评分(输入框) + 处理状态(选择框) + 未读/全部/星标(单选) + 归档
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

                // 处理状态选择框（打分/摘要/翻译/转录）
                Picker(selection: $vm.processedFilter) {
                    Text("处理: 全部").tag(nil as String?)
                    Text("已打分").tag("score" as String?)
                    Text("已摘要").tag("summary" as String?)
                    Text("已翻译").tag("translate" as String?)
                    Text("已转录").tag("transcribe" as String?)
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 110)
                .font(.caption)
                .controlSize(.small)
                .onChange(of: vm.processedFilter) { _, _ in vm.reload() }

                // 标签筛选
                Picker(selection: $vm.selectedTag) {
                    Text("标签: 全部").tag(nil as Tag?)
                    ForEach(vm.tags) { t in
                        Text("🏷 \(t.name)").tag(t as Tag?)
                    }
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 110)
                .font(.caption)
                .controlSize(.small)
                .onChange(of: vm.selectedTag) { _, _ in vm.reload() }

                Spacer()

                // 未读/全部/星标 三选一单选（分段控件）
                Picker("", selection: $vm.readFilter) {
                    ForEach(ContentViewModel.ReadFilter.allCases, id: \.self) { f in
                        Text(f.display).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
                .controlSize(.small)
                .onChange(of: vm.readFilter) { _, _ in vm.reload() }

                Toggle("归档", isOn: $vm.showArchived)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .controlSize(.small)
                    .onChange(of: vm.showArchived) { _, _ in vm.reload() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

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
                            Button("重新生成归档 md") {
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
                ReadingView(item: item, showTranslated: $vm.showTranslated)
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
    /// @AppStorage 让缩放值变化时行自动重建（静态 ReadingLayout.uiFontScale 不触发刷新）
    @AppStorage("reading.uiFontScale") private var scale: Double = 1.0

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 缩略图（有首图才显示，右侧 Follo 式）
            VStack(alignment: .leading, spacing: 5) {
                // 标题行
                HStack(alignment: .top, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 15 * scale, weight: item.isRead ? .regular : .semibold))
                        .foregroundStyle(isSelected ? .white : (item.isRead ? .secondary : .primary))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.starred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(isSelected ? .white : .yellow)
                            .font(.system(size: 11 * scale))
                    }
                    Spacer(minLength: 0)
                    if let s = item.llmScore {
                        Text("\(s)")
                            .font(.system(size: 11 * scale).bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(isSelected ? Color.white.opacity(0.25) : scoreColor(s).opacity(0.18))
                            .foregroundStyle(isSelected ? .white : scoreColor(s))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                // 摘要
                if let ex = item.excerpt, !ex.isEmpty {
                    Text(ex)
                        .font(.system(size: 12.5 * scale))
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                        .lineLimit(2)
                }
                // 来源 + 日期
                HStack(spacing: 8) {
                    Text(item.source)
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
                    if let pd = item.publishedAt, pd.count >= 10 {
                        Text(String(pd.prefix(10)))
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(isSelected ? .white.opacity(0.7) : Color(nsColor: .tertiaryLabelColor))
                    }
                    Spacer()
                    if !item.isRead && !isSelected {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    }
                }
            }
            // 右侧缩略图（有首图才显示）
            if let img = item.imageUrl, let url = URL(string: img) {
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
                .frame(width: 72 * scale, height: 72 * scale)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private func scoreColor(_ s: Int) -> Color {
        switch s {
        case 80...: return .green
        case 60..<80: return .orange
        case 40..<60: return .yellow
        default: return .gray
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
}

public struct ReadingView: View {
    let item: ContentItem
    @Binding var showTranslated: Bool

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

                    // ── 标签行 ──
                    TagEditorView(contentId: item.id)

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
                    if bilingualMode, let translated = item.llmTranslatedMd, !translated.isEmpty,
                       let original = item.contentMd, !original.isEmpty {
                        BilingualBodyView(
                            original: original,
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

    /// 正文视图模式：0=双语对照 / 1=仅原文 / 2=仅译文（默认双语，Follo 风格）
    @State private var viewMode = 0

    /// 双语对照模式（viewMode=0 且有译文）
    private var bilingualMode: Bool {
        viewMode == 0 && item.llmTranslatedMd != nil
    }

    private var bodyText: String {
        // 仅译文
        if viewMode == 2, let t = item.llmTranslatedMd, !t.isEmpty { return t }
        // 兼容旧 showTranslated 绑定
        if showTranslated, let t = item.llmTranslatedMd, !t.isEmpty { return t }
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
                    showTranslated = true
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
                    showTranslated = true
                    NotificationCenter.default.post(name: .contentUpdated, object: nil)
                }
            }
        }
    }
}

extension Notification.Name {
    static let contentUpdated = Notification.Name("contentUpdated")
}

// MARK: - 标签编辑（阅读区）
// 显示当前内容标签 + 输入新标签(回车添加) + 点标签移除

public struct TagEditorView: View {
    let contentId: Int64
    @State private var tags: [Tag] = []
    @State private var input = ""

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag").foregroundStyle(.secondary).font(.caption)
            ForEach(tags) { tag in
                Text(tag.name)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.blue.opacity(0.15)).foregroundStyle(.blue)
                    .clipShape(Capsule())
                    .onTapGesture {
                        TagService.shared.untag(contentId: contentId, tagId: tag.id)
                        reload()
                    }
                    .help("点击移除")
            }
            TextField("加标签", text: $input)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(minWidth: 60)
                .onSubmit {
                    let t = input.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty {
                        TagService.shared.tag(contentId: contentId, tagName: t)
                        input = ""
                        reload()
                    }
                }
        }
        .onAppear { reload() }
    }

    private func reload() { tags = TagService.shared.tagsFor(contentId: contentId) }
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
                    message = "✅ 已重新生成归档 md"
                } label: {
                    Label("重新生成归档文件", systemImage: "arrow.clockwise.doc")
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
