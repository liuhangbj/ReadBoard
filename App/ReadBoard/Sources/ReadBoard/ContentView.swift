import SwiftUI

struct ContentView: View {
    @StateObject private var vm = ContentViewModel()
    @FocusState private var listFocused: Bool

    var body: some View {
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
    }

    // MARK: 快捷键（隐藏按钮承载键盘事件）
    // j/k 上下篇, s 星标, a 归档, 空格已读切换, v 开原文
    private var shortcutHandlers: some View {
        Group {
            Button("") { vm.selectNext() }.keyboardShortcut("j", modifiers: [])
            Button("") { vm.selectPrev() }.keyboardShortcut("k", modifiers: [])
            Button("") { if let it = vm.selectedItem { vm.toggleStar(it) } }.keyboardShortcut("s", modifiers: [])
            Button("") { if let it = vm.selectedItem { vm.toggleArchive(it) } }.keyboardShortcut("a", modifiers: [])
            Button("") { if let it = vm.selectedItem { vm.toggleRead(it) } }.keyboardShortcut(.space, modifiers: [])
            Button("") { openOriginal() }.keyboardShortcut("v", modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    private func openOriginal() {
        guard let item = vm.selectedItem, let url = URL(string: item.url), !item.url.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }
    // MARK: 左栏
    private var sourceSidebar: some View {
        List(selection: Binding(
            get: { vm.selectedSource },
            set: { vm.selectSource($0) }
        )) {
            Section("来源") {
                HStack {
                    Text("全部")
                    Spacer()
                    Text("\(vm.totalCount)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .tag(nil as String?)
                ForEach(vm.sourceGroups) { g in
                    HStack {
                        Text(iconFor(g.kind))
                        Text(g.name)
                            .lineLimit(1)
                        Spacer()
                        Text("\(g.count)")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .tag(g.kind as String?)
                }
            }
        }
        .listStyle(.sidebar)
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
                    .onChange(of: vm.keyword) { _, _ in vm.reload() }
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

            // 筛选条：评分 + 未读 + 星标 + 归档
            HStack {
                Text("评分 ≥")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $vm.minScore) {
                    Text("不限").tag(0)
                    Text("40").tag(40)
                    Text("60").tag(60)
                    Text("80").tag(80)
                }
                .pickerStyle(.segmented)
                .onChange(of: vm.minScore) { _, _ in vm.reload() }
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
            } else {
                ContentUnavailableView(
                    "选择一篇文章",
                    systemImage: "doc.text",
                    description: Text("共 \(vm.totalCount) 条内容 · \(vm.sourceGroups.count) 个来源")
                )
            }
        }
    }

    private func iconFor(_ kind: String) -> String {
        switch kind {
        case "podcast": return "🎙"
        case "youtube": return "▶️"
        case "wechat":  return "💬"
        default:        return "📰"
        }
    }
}

// MARK: - 文章行

struct ArticleRow: View {
    let item: ContentItem

    var body: some View {
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

struct ReadingView: View {
    let item: ContentItem
    @Binding var showTranslated: Bool

    @State private var pipeline = LLMPipeline()
    @State private var transcriber = TranscribePipeline()
    @State private var busy = false
    @State private var statusMsg: String?

    var body: some View {
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

                // ── LLM 操作条 ──
                HStack(spacing: 10) {
                    // 转录不依赖 LLM key（whisper 本地），单独判断
                    if isMediaItem, item.llmTranslatedMd == nil {
                        Button {
                            runTranscribe()
                        } label: {
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
                        if item.llmScore == nil {
                            Button {
                                runScore()
                            } label: {
                                Label("AI 评分", systemImage: "star")
                            }
                            .disabled(busy)
                        }
                        if item.llmSummary == nil {
                            Button {
                                runSummarize()
                            } label: {
                                Label("摘要", systemImage: "text.quote")
                            }
                            .disabled(busy)
                        }
                        if !isMediaItem, item.llmTranslatedMd == nil {
                            Button {
                                runTranslate()
                            } label: {
                                Label("AI 翻译", systemImage: "character.bubble")
                            }
                            .disabled(busy)
                        }
                        if busy {
                            ProgressView()
                                .scaleEffect(0.7)
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

                // 原文/翻译切换（有翻译时才显示）
                if item.llmTranslatedMd != nil {
                    Picker("", selection: $showTranslated) {
                        Text("原文").tag(false)
                        Text("翻译").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
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

                // 正文
                Text(bodyText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
        }
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
        statusMsg = "评分中…"
        Task {
            let ok = await pipeline.score(contentId: cid, title: item.title, body: contentBody)
            await MainActor.run {
                busy = false
                statusMsg = ok ? "✅ 评分完成" : "❌ 评分失败"
                if ok { NotificationCenter.default.post(name: .contentUpdated, object: nil) }
            }
        }
    }

    private func runTranslate() {
        let cid = item.id
        busy = true
        statusMsg = "翻译中…"
        Task {
            let ok = await pipeline.translate(contentId: cid, title: item.title, body: contentBody)
            await MainActor.run {
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
        statusMsg = "摘要中…"
        Task {
            let ok = await pipeline.summarize(contentId: cid, title: item.title, body: contentBody)
            await MainActor.run {
                busy = false
                statusMsg = ok ? "✅ 摘要完成" : "❌ 摘要失败"
                if ok { NotificationCenter.default.post(name: .contentUpdated, object: nil) }
            }
        }
    }

    private func runTranscribe() {
        let cid = item.id
        busy = true
        statusMsg = "转录中（下载+识别，较长）…"
        Task {
            let ok = await transcriber.transcribe(
                contentId: cid, title: item.title, audioUrl: item.audioUrl, pageUrl: item.url, language: item.language)
            await MainActor.run {
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
