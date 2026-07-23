import SwiftUI

// MARK: - 订阅源管理界面

struct SourcesView: View {
    @StateObject private var store = SourceStore()
    @State private var showAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具条
            HStack {
                Text("订阅源")
                    .font(.title2.bold())
                Text("\(store.sources.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                if store.isSyncing {
                    ProgressView().scaleEffect(0.7)
                    Text("同步中…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button { Task { await store.syncAll() } } label: {
                        Label("全部刷新", systemImage: "arrow.clockwise")
                    }
                }
                Button { showAddSheet = true } label: {
                    Label("添加", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding()

            if !store.lastSyncMessage.isEmpty {
                Text(store.lastSyncMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            // 源列表
            List {
                ForEach(store.sources) { src in
                    SourceRow(src: src, store: store)
                }
            }
            .listStyle(.inset)
        }
        .onAppear { store.reload() }
        .sheet(isPresented: $showAddSheet) {
            AddSourceSheet(store: store)
        }
    }
}

// MARK: 单行

struct SourceRow: View {
    let src: FeedSource
    @ObservedObject var store: SourceStore

    var body: some View {
        HStack(spacing: 10) {
            Text(icon)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(src.name).font(.headline)
                Text(src.identifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(src.stype)
                        .font(.caption2)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 3))
                    if let t = src.lastFetchedAt {
                        Text("上次 \(String(t.prefix(16)))").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let err = src.error {
                        Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1)
                    }
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { src.enabled },
                set: { store.setEnabled(id: src.id, enabled: $0) }
            ))
            .labelsHidden()
            Button(role: .destructive) { store.removeSource(id: src.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch src.stype {
        case "podcast": return "🎙"
        case "youtube": return "▶️"
        case "wechat": return "💬"
        default: return "📰"
        }
    }
}

// MARK: 添加源

struct AddSourceSheet: View {
    @ObservedObject var store: SourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var stype = "rss"
    @State private var name = ""
    @State private var identifier = ""
    @State private var testing = false
    @State private var testResult = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加订阅源").font(.title3.bold())

            Picker("类型", selection: $stype) {
                Text("RSS 文章").tag("rss")
                Text("播客").tag("podcast")
                Text("YouTube").tag("youtube")
            }
            .pickerStyle(.segmented)

            TextField("名称（可选，留空自动用 feed 标题）", text: $name)
            TextField(stype == "youtube" ? "频道 URL 或 UC 开头 ID" : "Feed 地址 (https://…)", text: $identifier)
                .textFieldStyle(.roundedBorder)

            if !testResult.isEmpty {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(testResult.hasPrefix("✓") ? .green : .red)
            }

            HStack {
                Button(testing ? "检测中…" : "检测") { testFeed() }
                    .disabled(identifier.isEmpty || testing)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(identifier.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func testFeed() {
        testing = true
        testResult = ""
        let url = resolvedIdentifier()
        Task {
            do {
                let feed = try await FeedFetcher.fetch(urlString: url)
                await MainActor.run {
                    testResult = "✓ \(feed.title)：\(feed.entries.count) 条，类型 \(feed.kind.rawValue)"
                    if name.isEmpty { name = feed.title }
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testResult = "✗ \(error.localizedDescription)"
                    testing = false
                }
            }
        }
    }

    private func resolvedIdentifier() -> String {
        var id = identifier.trimmingCharacters(in: .whitespaces)
        if stype == "youtube" {
            if id.hasPrefix("UC") {
                return "https://www.youtube.com/feeds/videos.xml?channel_id=\(id)"
            }
            // 频道页 URL 暂存原始，抓取层后续可扩展解析 channel_id
        }
        return id
    }

    private func add() {
        let finalName = name.isEmpty ? identifier : name
        if store.addSource(stype: stype, name: finalName, identifier: resolvedIdentifier()) {
            dismiss()
        } else {
            testResult = "✗ 添加失败（可能已存在相同源）"
        }
    }
}
