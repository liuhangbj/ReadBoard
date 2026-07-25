import SwiftUI
import UniformTypeIdentifiers

// MARK: - 订阅源管理界面

public struct SourcesView: View {
    // @StateObject 而非 @ObservedObject——SourcesView 在 RootView switch 里反复创建，
    // @ObservedObject 不持所有权语义错误（虽是单例不泄漏，但 StateObject 才正确）
    @StateObject private var store = SourceStore.shared
    @StateObject private var worker = PipelineWorker.shared
    @EnvironmentObject private var appTab: AppTab
    @State private var showAddSheet = false
    @State private var showAddFolder = false
    @State private var newFolderName = ""
    @State private var opmlMessage = ""
    // SwiftUI 原生文件导入/导出面板（.fileImporter/.fileExporter）——
    // Apple 官方在 SwiftUI App 打开文件的唯一正确姿势，不碰 NSOpenPanel
    // （NSOpenPanel.runModal/begin 在 SwiftUI 事件循环下会卡死/不弹，踩了几次坑）
    @State private var showImportPanel = false
    @State private var showExportPanel = false

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部工具条（统一到 RB token：quiet 按钮、text 三级、墨蓝 tint）
            HStack(spacing: 10) {
                // 返回阅读（左栏底部导航切过来的入口）
                Button { appTab.selection = 0 } label: {
                    Label("阅读", systemImage: "chevron.left")
                }
                .buttonStyle(.quiet)
                .help("返回阅读")
                Text("订阅源")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.rbText)
                Text("\(store.sources.count)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.rbText3)
                Spacer()
                if store.isSyncing {
                    ProgressView().scaleEffect(0.7)
                    Text("同步中…").font(.caption).foregroundStyle(Color.rbText3)
                } else {
                    Button { Task { await store.syncAll() } } label: {
                        Label("全部刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.quiet)
                }
                Button { showAddFolder = true } label: {
                    Label("文件夹", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.quiet)
                Button { showAddSheet = true } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.quiet)
                .keyboardShortcut("n", modifiers: .command)
                // OPML 导入/导出（SwiftUI 原生 fileImporter/fileExporter）
                Button { showImportPanel = true } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.quiet)
                Button { showExportPanel = true } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.quiet)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if !store.lastSyncMessage.isEmpty {
                Text(store.lastSyncMessage)
                    .font(.caption)
                    .foregroundStyle(Color.rbText3)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !opmlMessage.isEmpty {
                Text(opmlMessage)
                    .font(.caption)
                    .foregroundStyle(Color.rbAccent)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // ── 后台管线 worker 状态条 ──
            HStack(spacing: 8) {
                Image(systemName: "gearshape.2")
                    .foregroundStyle(Color.rbText3)
                if worker.isRunning {
                    ProgressView().scaleEffect(0.6)
                    Text("管线运行中…").font(.caption).foregroundStyle(Color.rbText2)
                } else {
                    Text("管线空闲").font(.caption).foregroundStyle(Color.rbText2)
                }
                if let t = worker.lastRunAt {
                    Text("上次 \(t)").font(.caption2).foregroundStyle(Color.rbText3)
                }
                if !worker.lastSummary.isEmpty {
                    Text(worker.lastSummary).font(.caption2).foregroundStyle(Color.rbText3).lineLimit(1)
                }
                Text("累计 \(worker.processedTotal)").font(.caption2).foregroundStyle(Color.rbText3)
                Spacer()
                Button {
                    Task { await worker.runOnce() }
                } label: {
                    Label("立即扫描", systemImage: "play")
                }
                .disabled(worker.isRunning)
                .controlSize(.small)
                .buttonStyle(.quiet)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Hairline()

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
        // SwiftUI 原生文件导入面板（OPML）
        .fileImporter(isPresented: $showImportPanel,
                      allowedContentTypes: [.init(filenameExtension: "opml") ?? .xml, .xml],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        // SwiftUI 原生文件导出面板（OPML）
        .fileExporter(isPresented: $showExportPanel,
                      document: OPMLDocument(text: OPMLService.shared.exportOPML()),
                      contentType: .xml,
                      defaultFilename: "readboard-subscriptions") { result in
            switch result {
            case .success(let url):
                opmlMessage = "已导出 \(store.sources.count) 源到 \(url.lastPathComponent)"
            case .failure(let err):
                opmlMessage = "导出失败：\(err.localizedDescription)"
            }
        }
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

    // MARK: OPML 导入/导出（SwiftUI 原生 fileImporter/fileExporter）

    /// 处理 fileImporter 选中的 OPML 文件：读文件 + 后台解析写库 + 回主线程刷新
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            opmlMessage = "打开文件失败：\(err.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            // 沙箱下需 startAccessingSecurityScopedResource 才能读用户选的文件
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let xml = try? String(contentsOf: url, encoding: .utf8) else {
                opmlMessage = "读取文件失败：\(url.lastPathComponent)"
                return
            }
            // 解析 + 写库放后台线程——importOPML 里 db.execute 走 writeQueue.sync，
            // 主线程同步跑若 writeQueue 有等主线程的任务就死锁卡死界面。
            opmlMessage = "导入中…"
            DispatchQueue.global(qos: .userInitiated).async {
                let result = OPMLService.shared.importOPML(xml)
                DispatchQueue.main.async {
                    store.reload()
                    var msg = "导入完成：新增 \(result.sourcesAdded) 源"
                    if result.foldersCreated > 0 { msg += "，\(result.foldersCreated) 文件夹" }
                    if result.sourcesSkipped > 0 { msg += "，跳过已存在 \(result.sourcesSkipped)" }
                    if !result.errors.isEmpty { msg += "，\(result.errors.count) 错误" }
                    opmlMessage = msg
                }
            }
        }
    }
}

/// OPML 导出文档（fileExporter 需要的 FileDocument 包装）
struct OPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.xml] }
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: 文件夹分组头（含文件夹级管线总开关）

public struct FolderHeader: View {
    let folder: Folder
    @ObservedObject var store: SourceStore
    @State private var showDeleteConfirm = false
    /// 开总开关后弹"处理历史数据"选项
    @State private var pendingBackfillKey: String? = nil

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.rbText3)
            Text(folder.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.rbText)
            Spacer()
            // 文件夹级总开关(开 = 该组全生效)
            folderToggle("打分", key: "auto_score", on: folder.policy.autoScore)
            folderToggle("翻译", key: "auto_translate", on: folder.policy.autoTranslate)
            folderToggle("摘要", key: "auto_summarize", on: folder.policy.autoSummarize)
            folderToggle("转录", key: "auto_transcribe", on: folder.policy.autoTranscribe)
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
            Button("删除", role: .destructive) { store.removeFolder(id: folder.id) }
        } message: {
            Text("文件夹内的源不会被删除，只是移出分组（folder_id 置空）。")
        }
        .alert("处理历史数据？", isPresented: Binding(
            get: { pendingBackfillKey != nil },
            set: { if !$0 { pendingBackfillKey = nil } }
        )) {
            Button("处理所有历史并重新生成 md") {
                Task { await PipelineWorker.shared.backfillHistoryForFolder(folderId: folder.id) }
                pendingBackfillKey = nil
            }
            Button("只处理新增", role: .cancel) { pendingBackfillKey = nil }
        } message: {
            Text("「\(folder.name)」整组的\(pendingBackfillKey ?? "")已开启。\n\n• 处理历史：组内所有源的存量文章补跑管线并刷新已生成的 md 文件（耗时很长，按量计费）\n• 只处理新增：历史不动，新抓的自动走管线")
        }
    }

    private func folderToggle(_ label: String, key: String, on: Bool) -> some View {
        Toggle(label, isOn: Binding(
            get: { on },
            set: { newValue in
                store.setFolderPolicy(id: folder.id, key: key, value: newValue)
                if newValue { pendingBackfillKey = label }
            }
        ))
        .toggleStyle(.checkbox)
        .font(.caption)
        .controlSize(.small)
        .tint(Color.rbAccent)
    }
}

// MARK: 单行

public struct SourceRow: View {
    let src: FeedSource
    @ObservedObject var store: SourceStore
    @State private var showDeleteConfirm = false
    /// 开管线后弹"处理历史数据"选项（key = 刚打开的管线）
    @State private var pendingBackfillKey: String? = nil

    public var body: some View {
        HStack(spacing: 10) {
            Text(icon)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(src.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.rbText)
                Text(src.identifier)
                    .font(.caption)
                    .foregroundStyle(Color.rbText3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    RBadge(text: src.stype, color: .rbText3)
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
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(fetchModeColor.opacity(0.12))
                                .foregroundStyle(fetchModeColor)
                                .clipShape(RoundedRectangle(cornerRadius: RB.Radius.sm))
                        }
                        .menuStyle(.borderlessButton)
                        .help("全文获取方式（点击可修改）")
                    }
                    if let t = src.lastFetchedAt {
                        Text("上次 \(String(t.prefix(16)))").font(.caption2).foregroundStyle(Color.rbText3)
                    }
                    // 抓取频率徽标
                    Menu {
                        ForEach([5, 15, 30, 60, 360, 720], id: \.self) { m in
                            Button {
                                store.setFetchInterval(id: src.id, minutes: m)
                            } label: {
                                let label = m < 60 ? "\(m) 分钟" : "\(m/60) 小时"
                                if src.fetchIntervalMin == m { Label(label, systemImage: "checkmark") }
                                else { Text(label) }
                            }
                        }
                    } label: {
                        Text("⏱ \(intervalLabel(src.fetchIntervalMin))")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.rbSurface)
                            .foregroundStyle(Color.rbText3)
                            .clipShape(RoundedRectangle(cornerRadius: RB.Radius.sm))
                    }
                    .menuStyle(.borderlessButton)
                    .help("自动抓取间隔（点击可修改）")
                    if let err = src.error {
                        Text(err).font(.caption2).foregroundStyle(Color.rbScoreLow).lineLimit(1)
                    }
                }
                // ── 管线开关（生效 = 源 OR 文件夹；文件夹已开的项标墨蓝）──
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
                    .foregroundStyle(Color.rbText3)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            Toggle("", isOn: Binding(
                get: { src.enabled },
                set: { store.setEnabled(id: src.id, enabled: $0) }
            ))
            .labelsHidden()
            .tint(Color.rbAccent)
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.rbText3)
            }
            .buttonStyle(.quiet)
            .alert("删除订阅源？", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { store.removeSource(id: src.id) }
            } message: {
                Text("「\(src.name)」将被移除。\n已抓取的内容会保留，但不再更新此源。")
            }
        }
        .padding(.vertical, 4)
    }

    /// 该源所属文件夹的开关（用于"已继承"高亮）
    private var fp: PipelinePolicy { store.folderPolicy(for: src) }

    /// 单个管线开关（打分/翻译/转录）。inherited=true 表示文件夹层已开，标蓝提示。
    /// 打开时弹选项：处理所有历史数据并重新归档（该源存量入管线刷新归档）/ 只处理新增。
    private func pipelineToggle(_ label: String, key: String, on: Bool, inherited: Bool) -> some View {
        Toggle(label, isOn: Binding(
            get: { on },
            set: { newValue in
                store.setPolicy(id: src.id, key: key, value: newValue)
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
            Button("处理所有历史并重新生成 md") {
                Task { await PipelineWorker.shared.backfillHistory(onlySourceId: src.id) }
                pendingBackfillKey = nil
            }
            Button("只处理新增", role: .cancel) { pendingBackfillKey = nil }
        } message: {
            Text("「\(src.name)」的\(label)已开启。\n\n• 处理历史：存量文章补跑管线并刷新已生成的 md 文件（耗时较长，按量计费）\n• 只处理新增：历史不动，新抓的自动走管线")
        }
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
        case .feedFull: return .rbScoreHigh
        case .defuddle: return .rbAccent
        case .cdp: return .rbScoreMid
        case .summary: return .rbScoreNone
        }
    }

    private func intervalLabel(_ m: Int) -> String {
        m < 60 ? "\(m)分钟" : "\(m/60)小时"
    }
}

// MARK: 添加源

public struct AddSourceSheet: View {
    @ObservedObject var store: SourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var stype = "rss"
    @State private var name = ""
    @State private var identifier = ""
    @State private var testing = false
    @State private var testResult = ""
    @State private var resolvedFeedURL: String? = nil   // testFeed 成功后定稿（自动发现可能改写）
    @State private var testedOK = false                  // 必须先检测通过才能添加

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加订阅源").font(.title3.bold())

            Picker("类型", selection: $stype) {
                Text("RSS 文章").tag("rss")
                Text("播客").tag("podcast")
                Text("YouTube").tag("youtube")
            }
            .pickerStyle(.segmented)

            TextField("名称（可选，留空自动用 feed 标题）", text: $name)
            TextField(stype == "youtube" ? "频道 URL / @handle / UC 开头 ID" : "Feed 地址或网站主页 (https://…)", text: $identifier)
                .textFieldStyle(.roundedBorder)
                .onChange(of: identifier) { _, _ in
                    // 输入变了必须重新检测
                    testedOK = false
                    resolvedFeedURL = nil
                    testResult = ""
                }

            if !testResult.isEmpty {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(testResult.hasPrefix("✓") ? Color.rbScoreHigh : Color.rbScoreLow)
            }

            HStack {
                Button(testing ? "检测中…" : "检测") { testFeed() }
                    .disabled(identifier.isEmpty || testing)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(identifier.isEmpty || !testedOK || testing)
            }
            Text("添加前请先「检测」通过——确认源可抓取，避免加了死源。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460)
    }

    /// 解析用户输入为最终 identifier（YouTube 异步解析 channel_id，其余同步返回）
    private func resolveIdentifier() async throws -> String {
        let id = identifier.trimmingCharacters(in: .whitespaces)
        if stype == "youtube" {
            return try await YouTubeResolver.resolveFeedURL(id)
        }
        return id
    }

    private func testFeed() {
        testing = true
        testResult = ""
        testedOK = false
        resolvedFeedURL = nil
        Task {
            do {
                if stype == "rss" {
                    // RSS: 自动发现——输入可以是 feed URL 也可以是网站主页
                    let (feedURL, feed) = try await FeedFetcher.discoverAndFetch(urlString: identifier.trimmingCharacters(in: .whitespaces))
                    var msg = "✓ \(feed.title)：\(feed.entries.count) 条，类型 \(feed.kind.rawValue)"
                    if feedURL != identifier.trimmingCharacters(in: .whitespaces) {
                        msg += "\n（主页自动发现 feed: \(feedURL)）"
                    }
                    let mode = await FullTextFetcher.shared.probeMode(feedUrl: feedURL)
                    msg += "，全文 \(mode.displayName)"
                    await MainActor.run {
                        testResult = msg
                        resolvedFeedURL = feedURL
                        testedOK = true
                        if name.isEmpty { name = feed.title }
                        testing = false
                    }
                } else if stype == "podcast" {
                    // 播客也支持主页自动发现（很多播客给的是节目主页而非 feed URL）
                    let input = identifier.trimmingCharacters(in: .whitespaces)
                    let (feedURL, feed) = try await FeedFetcher.discoverAndFetch(urlString: input)
                    var msg = "✓ \(feed.title)：\(feed.entries.count) 条，类型 \(feed.kind.rawValue)"
                    if feedURL != input { msg += "\n（主页自动发现 feed: \(feedURL)）" }
                    await MainActor.run {
                        testResult = msg
                        resolvedFeedURL = feedURL
                        testedOK = true
                        if name.isEmpty { name = feed.title }
                        testing = false
                    }
                } else {
                    let url = try await resolveIdentifier()
                    let feed = try await FeedFetcher.fetch(urlString: url)
                    await MainActor.run {
                        testResult = "✓ \(feed.title)：\(feed.entries.count) 条，类型 \(feed.kind.rawValue)"
                        resolvedFeedURL = url
                        testedOK = true
                        if name.isEmpty { name = feed.title }
                        testing = false
                    }
                }
            } catch {
                await MainActor.run {
                    testResult = "✗ \(error.localizedDescription)"
                    testing = false
                }
            }
        }
    }

    private func add() {
        // 必须用检测时定稿的 URL（自动发现可能改写过），防止重复解析不一致
        guard let url = resolvedFeedURL else {
            testResult = "✗ 请先检测"
            return
        }
        let finalName = name.isEmpty ? identifier : name
        testing = true
        testResult = ""
        Task {
            let ok = await store.addSource(stype: stype, name: finalName, identifier: url)
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
