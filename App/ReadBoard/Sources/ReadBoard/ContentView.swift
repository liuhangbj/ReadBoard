import SwiftUI

struct ContentView: View {
    @StateObject private var vm = ContentViewModel()

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
            // 评分筛选条
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
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            List(vm.items, selection: $vm.selectedItem) { item in
                ArticleRow(item: item)
                    .tag(item)
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
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
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
                    if !pipeline.isAvailable {
                        Label("未配置 LLM Key", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        if item.llmScore == nil {
                            Button {
                                runScore()
                            } label: {
                                Label("AI 评分", systemImage: "star")
                            }
                            .disabled(busy)
                        }
                        if item.llmTranslatedMd == nil {
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
}

extension Notification.Name {
    static let contentUpdated = Notification.Name("contentUpdated")
}
