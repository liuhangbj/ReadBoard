import ReadBoardContract
import ReadBoardUI
import SwiftUI
import UniformTypeIdentifiers

/// 订阅管理的共享页面。Core 注入本地 gateway，Go 注入远程 gateway；页面、
/// 操作和状态处理保持同一份实现。
public struct ReadBoardSourcesFeatureView: View {
    @State private var model: ReadBoardSourcesFeatureModel
    @State private var showAddSource = false
    @State private var showCreateFolder = false
    @State private var folderName = ""
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument = ReadBoardOPMLDocument(text: "")

    private let environment: ReadBoardFeatureEnvironment

    public init(environment: ReadBoardFeatureEnvironment) {
        self.environment = environment
        _model = State(initialValue: ReadBoardSourcesFeatureModel(environment: environment))
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ReadBoardHairline()
            content
        }
        .background(ReadBoardDesign.C.bg)
        .task { await model.load() }
        .sheet(isPresented: $showAddSource) {
            ReadBoardAddSourceSheet(model: model)
        }
        .alert("新建文件夹", isPresented: $showCreateFolder) {
            TextField("文件夹名称", text: $folderName)
            Button("取消", role: .cancel) { folderName = "" }
            Button("创建") {
                let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                folderName = ""
                Task { await model.createFolder(name: name) }
            }
            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("好", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "请稍后重试")
        }
        .overlay(alignment: .bottom) { statusToast }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.xml, .data],
            allowsMultipleSelection: false,
            onCompletion: importOPML)
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: ReadBoardOPMLDocument.contentType,
            defaultFilename: "readboard-subscriptions.opml"
        ) { result in
            if case .failure(let error) = result {
                model.presentExternalError(error.localizedDescription)
            }
        }
    }

    private var header: some View {
        ReadBoardPageHeader(
            eyebrow: "服务",
            title: "订阅源",
            subtitle: headerSubtitle
        ) {
            Menu {
                Toggle("自动刷新", isOn: Binding(
                    get: { model.syncSettings.enabled },
                    set: { enabled in
                        Task { await model.updateSyncSettings(
                            enabled: enabled,
                            intervalMinutes: model.syncSettings.intervalMinutes) }
                    }))
                Picker("自动刷新间隔", selection: Binding(
                    get: { model.syncSettings.intervalMinutes },
                    set: { minutes in
                        Task { await model.updateSyncSettings(
                            enabled: model.syncSettings.enabled,
                            intervalMinutes: minutes) }
                    })) {
                    ForEach([5, 15, 30, 60, 360, 720], id: \.self) { minutes in
                        Text(intervalLabel(minutes)).tag(minutes)
                    }
                }
            } label: {
                Label("自动刷新", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(ReadBoardQuietButtonStyle())

            Button { Task { await model.syncAll() } } label: {
                Label("全部刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ReadBoardQuietButtonStyle())
            .disabled(model.isWorking("sync:all"))

            Menu {
                Button("新建文件夹", systemImage: "folder.badge.plus") {
                    showCreateFolder = true
                }
                Divider()
                Button("导入 OPML", systemImage: "square.and.arrow.down") {
                    showImporter = true
                }
                Button("导出 OPML", systemImage: "square.and.arrow.up") {
                    Task { await prepareExport() }
                }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .buttonStyle(ReadBoardQuietButtonStyle())

            Button { showAddSource = true } label: {
                Label("添加", systemImage: "plus")
            }
            .buttonStyle(ReadBoardPrimaryButtonStyle())
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(ReadBoardDesign.Space.md)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading, model.snapshot == nil {
            ReadBoardLibraryEmptyState(
                title: "正在读取订阅源",
                message: "正在连接内容服务…",
                icon: "arrow.triangle.2.circlepath")
        } else if let snapshot = model.snapshot {
            if snapshot.sources.isEmpty {
                ReadBoardLibraryEmptyState(
                    title: "还没有订阅源",
                    message: "添加 RSS、播客、YouTube、Bilibili 或其他支持的来源。",
                    icon: "dot.radiowaves.left.and.right",
                    actionTitle: "添加订阅源") {
                        showAddSource = true
                    }
            } else {
                sourceList(snapshot)
            }
        } else {
            ReadBoardLibraryEmptyState(
                title: "无法加载订阅源",
                message: model.errorMessage ?? "请检查服务连接后重试。",
                icon: "wifi.exclamationmark",
                actionTitle: "重试") {
                    Task { await model.load() }
                }
        }
    }

    private func sourceList(_ snapshot: SourceCatalogSnapshot) -> some View {
        List {
            if snapshot.isSyncing || snapshot.isExternalSyncing {
                Section {
                    HStack(spacing: ReadBoardDesign.Space.sm) {
                        ProgressView().controlSize(.small)
                        Text(snapshot.lastSyncMessage.isEmpty
                            ? "服务端正在刷新订阅内容"
                            : snapshot.lastSyncMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(ReadBoardDesign.C.text2)
                    }
                    .padding(.vertical, 4)
                }
            }

            ForEach(snapshot.folders) { folder in
                Section {
                    ForEach(snapshot.sources.filter { $0.folderID == folder.id }) { source in
                        ReadBoardSourceFeatureRow(
                            source: source,
                            folders: snapshot.folders,
                            model: model)
                            .padding(.leading, 18)
                    }
                } header: {
                    ReadBoardSourceFolderHeader(
                        folder: folder,
                        sources: snapshot.sources.filter { $0.folderID == folder.id },
                        model: model)
                }
            }

            let ungrouped = snapshot.sources.filter { $0.folderID == nil }
            if !ungrouped.isEmpty {
                Section(snapshot.folders.isEmpty ? "全部订阅源" : "未分组") {
                    ForEach(ungrouped) { source in
                        ReadBoardSourceFeatureRow(
                            source: source,
                            folders: snapshot.folders,
                            model: model)
                    }
                }
            }
        }
        .listStyle(.inset)
        .refreshable { await model.load() }
    }

    private var headerSubtitle: String {
        guard let snapshot = model.snapshot else { return "管理抓取、全文和自动处理策略" }
        let issues = snapshot.sources.filter { $0.hasError || $0.isStale }.count
        let base = "\(snapshot.sources.count) 个订阅源"
        return issues > 0 ? "\(base) · \(issues) 个需要关注" : "\(base) · 运行正常"
    }

    @ViewBuilder
    private var statusToast: some View {
        if let message = model.statusMessage, !message.isEmpty {
            HStack(spacing: ReadBoardDesign.Space.sm) {
                Image(systemName: "checkmark.circle")
                Text(message).lineLimit(2)
                Button { model.clearStatus() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 11))
            .foregroundStyle(ReadBoardDesign.C.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .padding(.bottom, 16)
        }
    }

    private func prepareExport() async {
        exportDocument = ReadBoardOPMLDocument(text: await model.exportedOPML())
        showExporter = true
    }

    private func importOPML(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            model.presentExternalError(error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let items = try ReadBoardOPMLParser.parse(data)
                Task { _ = await model.importSources(items, refreshAfterCreation: true) }
            } catch {
                model.presentExternalError(error.localizedDescription)
            }
        }
    }

    private func intervalLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时"
    }
}
