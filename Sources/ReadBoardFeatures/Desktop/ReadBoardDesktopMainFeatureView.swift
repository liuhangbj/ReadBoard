import Foundation
import ReadBoardContract
import ReadBoardUI
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
public enum ReadBoardDesktopDestination: Hashable, Sendable {
    case library(ReadBoardLibraryLocation)
    case sources
    case operations
    case settings
}

/// Core 与 Go 共用的完整 macOS 主界面。产品壳只注入本地或远程环境，
/// 以及产品特有的设置页；三栏结构和功能导航不得在产品仓库里复制。
public struct ReadBoardDesktopMainFeatureView<SettingsContent: View>: View {
    private let environment: ReadBoardFeatureEnvironment
    private let settingsTitle: String?
    private let settingsIcon: String
    private let settingsContent: SettingsContent

    @State private var destination: ReadBoardDesktopDestination
    @State private var snapshot: LibrarySnapshot?
    @State private var sourcesModel: ReadBoardSourcesFeatureModel
    @State private var showAddSource = false
    @State private var showCreateFolder = false
    @State private var folderName = ""
    @State private var showImporter = false
    @State private var operationError: String?

    public init(
        environment: ReadBoardFeatureEnvironment,
        initialLocation: ReadBoardLibraryLocation = .collection(.all),
        settingsTitle: String? = nil,
        settingsIcon: String = "network",
        @ViewBuilder settings: () -> SettingsContent
    ) {
        self.environment = environment
        self.settingsTitle = settingsTitle
        self.settingsIcon = settingsIcon
        self.settingsContent = settings()
        _destination = State(initialValue: .library(initialLocation))
        _sourcesModel = State(initialValue: ReadBoardSourcesFeatureModel(environment: environment))
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: ReadBoardLibraryColumnMetrics.sidebarMinimum,
                    ideal: ReadBoardLibraryColumnMetrics.sidebarIdeal,
                    max: ReadBoardLibraryColumnMetrics.sidebarMaximum)
        } detail: {
            destinationContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ReadBoardDesign.C.bg)
        }
        .navigationTitle("ReadBoard")
        .tint(ReadBoardDesign.C.accent)
        .task { await reloadSidebar() }
        .onReceive(NotificationCenter.default.publisher(
            for: .readBoardLibrarySnapshotChanged)) { _ in
                Task { await reloadSnapshot() }
            }
        .sheet(isPresented: $showAddSource) {
            ReadBoardAddSourceSheet(model: sourcesModel)
        }
        .alert("新建文件夹", isPresented: $showCreateFolder) {
            TextField("文件夹名称", text: $folderName)
            Button("取消", role: .cancel) { folderName = "" }
            Button("创建") {
                let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                folderName = ""
                Task { await sourcesModel.createFolder(name: name) }
            }
            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("文件夹用于给订阅源分组，并可统一管理组内内容处理策略。")
        }
        .alert("操作失败", isPresented: Binding(
            get: { operationError != nil || sourcesModel.errorMessage != nil },
            set: { if !$0 {
                operationError = nil
                sourcesModel.clearError()
            } }
        )) {
            Button("好", role: .cancel) {
                operationError = nil
                sourcesModel.clearError()
            }
        } message: {
            Text(operationError ?? sourcesModel.errorMessage ?? "请稍后重试")
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.xml, .data],
            allowsMultipleSelection: false,
            onCompletion: importOPML)
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch destination {
        case .library(let location):
            ReadBoardLibraryFeatureView(
                environment: environment,
                location: location,
                automaticallyMarksRead: true)
                .id(location)
        case .sources:
            ReadBoardSourcesFeatureView(environment: environment)
        case .operations:
            ReadBoardOperationsFeatureView(environment: environment)
        case .settings:
            settingsContent
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            ReadBoardHairline()

            ScrollView {
                ReadBoardLibraryNavigationPane(
                    selection: librarySelection,
                    snapshot: snapshot,
                    environment: environment,
                    presentation: .readerSidebar)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
            }

            ReadBoardHairline()
            sidebarFooter
        }
        .background(ReadBoardDesign.C.bgSidebar)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 4) {
            if environment.permissions.allows(.manageOperations, capability: .administration) {
                ReadBoardServiceHealthButton(environment: environment) {
                    destination = .operations
                }
            }

            ReadBoardSectionLabel(text: "订阅源")
            Spacer(minLength: 4)

            if environment.permissions.allows(.manageSources, capability: .sourceManagement) {
                Button { showCreateFolder = true } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ReadBoardQuietButtonStyle())
                .help("新建文件夹")

                Menu {
                    Button("添加订阅源", systemImage: "plus") {
                        showAddSource = true
                    }
                    Button("导入 OPML", systemImage: "square.and.arrow.down") {
                        showImporter = true
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13))
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(ReadBoardQuietButtonStyle())
                .help("添加订阅源 / 导入 OPML")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            if environment.permissions.allows(.manageSources, capability: .sourceManagement) {
                footerButton(
                    title: "订阅管理",
                    icon: "dot.radiowaves.left.and.right",
                    destination: .sources)
            }
            if environment.permissions.allows(.manageOperations, capability: .administration) {
                footerButton(
                    title: "数据看板",
                    icon: "chart.bar.doc.horizontal",
                    destination: .operations)
            }
            if let settingsTitle {
                footerButton(
                    title: settingsTitle,
                    icon: settingsIcon,
                    destination: .settings)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func footerButton(
        title: String,
        icon: String,
        destination target: ReadBoardDesktopDestination
    ) -> some View {
        Button { destination = target } label: {
            ViewThatFits(in: .horizontal) {
                Label(title, systemImage: icon)
                    .font(.system(size: 11))
                Image(systemName: icon)
                    .font(.system(size: 12))
            }
            .foregroundStyle(destination == target
                ? ReadBoardDesign.C.accent
                : ReadBoardDesign.C.text2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(ReadBoardQuietButtonStyle())
        .help(title)
    }

    private var librarySelection: Binding<ReadBoardLibraryLocation?> {
        Binding(
            get: {
                guard case .library(let location) = destination else { return nil }
                return location
            },
            set: { location in
                if let location { destination = .library(location) }
            })
    }

    private func reloadSidebar() async {
        async let navigation: Void = reloadSnapshot()
        async let sourceCatalog: Void = sourcesModel.load()
        _ = await (navigation, sourceCatalog)
    }

    private func reloadSnapshot() async {
        do {
            snapshot = try await environment.library.snapshot()
        } catch is CancellationError {
            return
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func importOPML(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            operationError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let items = try ReadBoardOPMLParser.parse(data)
                Task { _ = await sourcesModel.importSources(
                    items, refreshAfterCreation: true) }
            } catch {
                operationError = error.localizedDescription
            }
        }
    }
}

public extension ReadBoardDesktopMainFeatureView where SettingsContent == EmptyView {
    init(
        environment: ReadBoardFeatureEnvironment,
        initialLocation: ReadBoardLibraryLocation = .collection(.all)
    ) {
        self.init(environment: environment, initialLocation: initialLocation) {
            EmptyView()
        }
    }
}
#endif
