import SwiftUI

// MARK: - 订阅源管理界面

struct SourcesView: View {
    @StateObject private var store = SourceStore()
    @ObservedObject private var worker = PipelineWorker.shared
    @State private var showAddSheet = false
    @State private var showAddFolder = false
    @State private var newFolderName = ""

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
                Button { showAddFolder = true } label: {
                    Label("文件夹", systemImage: "folder.badge.plus")
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

            // ── 后台管线 worker 状态条 ──
            HStack(spacing: 8) {
                Image(systemName: "gearshape.2")
                    .foregroundStyle(.secondary)
                if worker.isRunning {
                    ProgressView().scaleEffect(0.6)
                    Text("管线运行中…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("管线空闲").font(.caption).foregroundStyle(.secondary)
                }
                if let t = worker.lastRunAt {
                    Text("上次 \(t)").font(.caption2).foregroundStyle(.tertiary)
                }
                if !worker.lastSummary.isEmpty {
                    Text(worker.lastSummary).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text("累计 \(worker.processedTotal)").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task { await worker.runOnce() }
                } label: {
                    Label("立即扫描", systemImage: "play")
                }
                .disabled(worker.isRunning)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            // 源列表（文件夹 → 源 两级分组）
            List {
                // 各文件夹分组
                ForEach(store.folders) { folder in
                    Section {
                        ForEach(sources(in: folder.id)) { src in
                            SourceRow(src: src, store: store)
                        }
                    } header: {
                        FolderHeader(folder: folder, store: store)
                    }
                }
                // 未分组
                let ungrouped = sources(in: nil)
                if !ungrouped.isEmpty {
                    Section(store.folders.isEmpty ? "全部源" : "未分组") {
                        ForEach(ungrouped) { src in
                            SourceRow(src: src, store: store)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .onAppear { store.reload() }
        .sheet(isPresented: $showAddSheet) {
            AddSourceSheet(store: store)
        }
        .alert("新建文件夹", isPresented: $showAddFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") {
                if !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.addFolder(name: newFolderName.trimmingCharacters(in: .whitespaces))
                }
                newFolderName = ""
            }
        }
    }

    /// 某文件夹下的源(nil = 未分组)
    private func sources(in folderId: Int64?) -> [FeedSource] {
        store.sources.filter { $0.folderId == folderId }
    }
}

// MARK: 文件夹分组头（含文件夹级管线总开关）

struct FolderHeader: View {
    let folder: Folder
    @ObservedObject var store: SourceStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            Text(folder.name)
                .font(.headline)
            Spacer()
            // 文件夹级总开关(开 = 该组全生效)
            folderToggle("打分", key: "auto_score", on: folder.policy.autoScore)
            folderToggle("翻译", key: "auto_translate", on: folder.policy.autoTranslate)
            folderToggle("摘要", key: "auto_summarize", on: folder.policy.autoSummarize)
            folderToggle("转录", key: "auto_transcribe", on: folder.policy.autoTranscribe)
            Button(role: .destructive) { store.removeFolder(id: folder.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .textCase(nil)
    }

    private func folderToggle(_ label: String, key: String, on: Bool) -> some View {
        Toggle(label, isOn: Binding(
            get: { on },
            set: { store.setFolderPolicy(id: folder.id, key: key, value: $0) }
        ))
        .toggleStyle(.checkbox)
        .font(.caption)
        .controlSize(.small)
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
                    // 全文模式徽标（仅文章类源显示）
                    if src.stype == "rss" {
                        Menu {
                            ForEach(FetchMode.allCases, id: \.rawValue) { m in
                                Button {
                                    store.setFetchMode(id: src.id, mode: m)
                                } label: {
                                    if src.fetchMode == m { Label(m.displayName, systemImage: "checkmark") }
                                    else { Text(m.displayName) }
                                }
                            }
                            Divider()
                            Button("重新探测") { Task { await store.reprobeFetchMode(id: src.id) } }
                        } label: {
                            Text(src.fetchMode.displayName)
                                .font(.caption2)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(fetchModeColor.opacity(0.18))
                                .foregroundStyle(fetchModeColor)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        .menuStyle(.borderlessButton)
                        .help("全文获取方式（点击可修改）")
                    }
                    if let t = src.lastFetchedAt {
                        Text("上次 \(String(t.prefix(16)))").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let err = src.error {
                        Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1)
                    }
                }
                // ── 管线开关（生效 = 源 OR 文件夹；文件夹已开的项标蓝）──
                HStack(spacing: 14) {
                    pipelineToggle("打分", key: "auto_score", on: src.policy.autoScore, inherited: fp.autoScore)
                    pipelineToggle("翻译", key: "auto_translate", on: src.policy.autoTranslate, inherited: fp.autoTranslate)
                    pipelineToggle("摘要", key: "auto_summarize", on: src.policy.autoSummarize, inherited: fp.autoSummarize)
                    if src.transcribable {
                        pipelineToggle("转录", key: "auto_transcribe", on: src.policy.autoTranscribe, inherited: fp.autoTranscribe)
                    }
                }
                .padding(.top, 2)
            }
            Spacer()
            // 指派到文件夹
            Menu {
                Button("未分组") { store.assignSource(sourceId: src.id, folderId: nil) }
                Divider()
                ForEach(store.folders) { f in
                    Button {
                        store.assignSource(sourceId: src.id, folderId: f.id)
                    } label: {
                        if src.folderId == f.id { Label(f.name, systemImage: "checkmark") }
                        else { Text(f.name) }
                    }
                }
            } label: {
                Image(systemName: "folder")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
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

    /// 该源所属文件夹的开关（用于"已继承"高亮）
    private var fp: PipelinePolicy { store.folderPolicy(for: src) }

    /// 单个管线开关（打分/翻译/转录）。inherited=true 表示文件夹层已开，标蓝提示。
    private func pipelineToggle(_ label: String, key: String, on: Bool, inherited: Bool) -> some View {
        Toggle(label, isOn: Binding(
            get: { on },
            set: { store.setPolicy(id: src.id, key: key, value: $0) }
        ))
        .toggleStyle(.checkbox)
        .font(.caption)
        .controlSize(.small)
        .foregroundStyle(inherited ? .blue : .primary)
        .help(inherited ? "文件夹层已开启此项，对本源生效" : "")
    }

    private var icon: String {
        switch src.stype {
        case "podcast": return "🎙"
        case "youtube": return "▶️"
        case "wechat": return "💬"
        default: return "📰"
        }
    }

    private var fetchModeColor: Color {
        switch src.fetchMode {
        case .feedFull: return .green
        case .defuddle: return .blue
        case .cdp: return .orange
        case .summary: return .gray
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
                var msg = "✓ \(feed.title)：\(feed.entries.count) 条，类型 \(feed.kind.rawValue)"
                // RSS 文章类: 探测全文模式
                if stype == "rss" {
                    let mode = await FullTextFetcher.shared.probeMode(feedUrl: url)
                    msg += "，全文 \(mode.displayName)"
                }
                await MainActor.run {
                    testResult = msg
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
        testing = true
        testResult = ""
        Task {
            let ok = await store.addSource(stype: stype, name: finalName, identifier: resolvedIdentifier())
            await MainActor.run {
                testing = false
                if ok {
                    dismiss()
                } else {
                    testResult = "✗ 添加失败（可能已存在相同源）"
                }
            }
        }
    }
}
