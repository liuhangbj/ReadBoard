import SwiftUI

public struct ContentView: View {
    @StateObject private var vm = ContentViewModel()
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool

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

            List(selection: Binding(
                get: { vm.selectedFilter },
                set: { vm.selectFilter($0) }
            )) {
                // 全部
                HStack {
                    Image(systemName: "tray.full")
                        .foregroundStyle(.secondary)
                    Text("全部")
                    Spacer()
                    Text("\(vm.totalCount)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .tag(nil as String?)

                // 文件夹（可展开）→ 源
                ForEach(vm.sidebarTree) { node in
                    if node.isFolder {
                        DisclosureGroup {
                            ForEach(node.children ?? []) { child in
                                sidebarRow(child)
                                    .tag(child.filterKey as String?)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.secondary)
                                Text(node.name)
                                Spacer()
                                Text("\(node.count)")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                    } else {
                        sidebarRow(node)
                            .tag(node.filterKey as String?)
                    }
                }
            }
            .listStyle(.sidebar)
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
    }

    private func sidebarRow(_ node: SidebarNode) -> some View {
        HStack {
            if node.isFolder {
                Image(systemName: "folder").foregroundStyle(.secondary)
            }
            Text(node.name)
                .lineLimit(1)
            Spacer()
            Text("\(node.count)")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
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

            // 筛选条：评分(输入框) + 标签 + 未读 + 星标 + 归档
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
                // 标签筛选
                Picker(selection: $vm.selectedTag) {
                    Text("标签: 全部").tag(nil as Tag?)
                    ForEach(vm.tags) { t in
                        Text("🏷 \(t.name)").tag(t as Tag?)
                    }
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 130)
                .font(.caption)
                .controlSize(.small)
                .onChange(of: vm.selectedTag) { _, _ in vm.reload() }
                Toggle("未读", isOn: $vm.unreadOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .controlSize(.small)
                    .onChange(of: vm.unreadOnly) { _, _ in vm.reload() }
                Toggle("星标", isOn: $vm.starredOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .controlSize(.small)
                    .onChange(of: vm.starredOnly) { _, _ in vm.reload() }
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
                    ArticleRow(item: item)
                        .tag(item)
                        .contextMenu {
                            Button(item.isRead ? "标为未读" : "标为已读") { vm.toggleRead(item) }
                            Button(item.starred ? "取消星标" : "加星标") { vm.toggleStar(item) }
                            Button(item.archived ? "取消归档" : "归档") { vm.toggleArchive(item) }
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

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                if !item.isRead {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                }
                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(item.isRead ? .secondary : .primary)
                    .lineLimit(2)
                if item.starred {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
                Spacer()
                if let s = item.llmScore {
                    Text("\(s)")
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(scoreColor(s).opacity(0.2))
                        .foregroundStyle(scoreColor(s))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            HStack(spacing: 6) {
                Text(item.source)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                if let author = item.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let lang = item.language {
                    Text(lang)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let ex = item.excerpt, !ex.isEmpty {
                Text(ex)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
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

                // 原文/翻译切换（有翻译时）
                if item.llmTranslatedMd != nil {
                    Picker("", selection: $showTranslated) {
                        Text("原文").tag(false)
                        Text("翻译").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 140)
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
                    // 标题 + 元信息
                    Text(item.title)
                        .font(.title2.bold())
                    HStack(spacing: 10) {
                        if let a = item.author, !a.isEmpty { Label(a, systemImage: "person") }
                        if let p = item.publishedAt { Label(String(p.prefix(10)), systemImage: "calendar") }
                        if let s = item.llmScore { Label("评分 \(s)", systemImage: "star.fill") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

                    // 摘要
                    if let sum = item.llmSummary, !sum.isEmpty {
                        Text(sum)
                            .font(.callout)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // 正文（版面设置生效）
                    Text(bodyText)
                        .font(.system(size: fontSize))
                        .lineSpacing(lineSpacing)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(24)
                .frame(maxWidth: contentWidth)
                .frame(maxWidth: .infinity)   // 内容限宽后居中
            }
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
            HStack {
                Text("字号").frame(width: 60, alignment: .leading)
                Button { adjustFont(-1) } label: { Image(systemName: "textformat.size.smaller") }
                Text("\(Int(fontSize))").frame(width: 30).font(.callout.monospacedDigit())
                Button { adjustFont(1) } label: { Image(systemName: "textformat.size.larger") }
            }
            HStack {
                Text("行距").frame(width: 60, alignment: .leading)
                Slider(value: $lineSpacing, in: 0...16, step: 1) { _ in
                    ReadingLayout.lineSpacing = lineSpacing
                }
                Text("\(Int(lineSpacing))").frame(width: 24).font(.callout.monospacedDigit())
            }
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
        .frame(width: 300)
    }

    private func adjustFont(_ delta: Double) {
        fontSize = max(12, min(28, fontSize + delta))
        ReadingLayout.fontSize = fontSize
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

    private var bodyText: String {
        if showTranslated, let t = item.llmTranslatedMd, !t.isEmpty { return t }
        if let md = item.contentMd, !md.isEmpty { return md }
        return item.excerpt ?? "(无内容)"
    }

    /// 是否媒体项（播客/视频，可转录）
    private var isMediaItem: Bool {
        item.ctype == "podcast" || item.ctype == "video" || item.audioUrl != nil
    }

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
