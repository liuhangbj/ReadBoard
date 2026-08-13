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
    private let openSettings: (ReadBoardSettingsRoute) -> Void
    private let settingsContent: SettingsContent

    @State private var destination: ReadBoardDesktopDestination
    @State private var snapshot: LibrarySnapshot?
    @State private var sourcesModel: ReadBoardSourcesFeatureModel
    @State private var mediaPlayer: ReadBoardGlobalMediaPlayer
    @State private var playbackNavigationRequest: ReadBoardPlaybackNavigationRequest?
    @State private var showAddSource = false
    @State private var showInboxImport = false
    @State private var showCreateFolder = false
    @State private var folderName = ""
    @State private var showImporter = false
    @State private var showIssueCenter = false
    @State private var operationError: String?
    @State private var lastRevision: DataRevisionSnapshot?
    @AppStorage("reading.uiFontScale") private var uiFontScale: Double = 1
    @AppStorage("reading.interfaceFont") private var interfaceFontRaw = "system"

    public init(
        environment: ReadBoardFeatureEnvironment,
        initialLocation: ReadBoardLibraryLocation = .collection(.all),
        settingsTitle: String? = nil,
        settingsIcon: String = "network",
        openSettings: @escaping (ReadBoardSettingsRoute) -> Void = { _ in },
        @ViewBuilder settings: () -> SettingsContent
    ) {
        self.environment = environment
        self.settingsTitle = settingsTitle
        self.settingsIcon = settingsIcon
        self.openSettings = openSettings
        self.settingsContent = settings()
        _destination = State(initialValue: .library(initialLocation))
        _sourcesModel = State(initialValue: ReadBoardSourcesFeatureModel(environment: environment))
        _mediaPlayer = State(initialValue: ReadBoardGlobalMediaPlayer(
            mediaPlayback: environment.mediaPlayback))
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: ReadBoardLibraryColumnMetrics.scaledSidebarWidth(
                        ReadBoardLibraryColumnMetrics.sidebarMinimum,
                        interfaceScale: uiFontScale),
                    ideal: ReadBoardLibraryColumnMetrics.scaledSidebarWidth(
                        ReadBoardLibraryColumnMetrics.sidebarIdeal,
                        interfaceScale: uiFontScale),
                    max: ReadBoardLibraryColumnMetrics.scaledSidebarWidth(
                        ReadBoardLibraryColumnMetrics.sidebarMaximum,
                        interfaceScale: uiFontScale))
        } detail: {
            destinationContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ReadBoardDesign.C.bg)
        }
        .navigationTitle("ReadBoard")
        .tint(ReadBoardDesign.C.accent)
        .onAppear { ReadBoardDockIconController.shared.start() }
        .task { await reloadSidebar() }
        .task { await monitorRevisions() }
        .onReceive(NotificationCenter.default.publisher(
            for: .readBoardLibrarySnapshotChanged)) { _ in
                Task { await reloadSnapshot() }
            }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("readBoardInboxImportCompleted"))) { _ in
                destination = .library(.collection(.inbox))
                Task { await reloadSnapshot() }
            }
        .sheet(isPresented: $showAddSource) {
            ReadBoardAddSourceSheet(model: sourcesModel)
        }
        .sheet(isPresented: $showInboxImport) {
            ReadBoardInboxImportSheet(inbox: environment.inbox) { _ in
                destination = .library(.collection(.inbox))
                Task { await reloadSnapshot() }
            }
        }
        .sheet(isPresented: $showIssueCenter) {
            ReadBoardIssueCenterView(environment: environment, action: handleIssueAction)
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
        .readBoardInterfaceFont(size: 13 * uiFontScale)
        .readBoardInterfaceFontFamily(interfaceFontRaw)
        .readBoardInterfaceScale(uiFontScale)
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch destination {
        case .library(let location):
            ReadBoardLibraryFeatureView(
                environment: environment,
                location: location,
                automaticallyMarksRead: true,
                mediaPlayer: mediaPlayer,
                playbackNavigationRequest: playbackNavigationRequest)
                .id(location)
        case .sources:
            ReadBoardSourcesFeatureView(
                environment: environment,
                model: sourcesModel)
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
                    sourceModel: sourcesModel,
                    presentation: .readerSidebar,
                    scale: sidebarScale)
                    .padding(.horizontal, 6 * sidebarScale)
                    .padding(.vertical, 6 * sidebarScale)
            }

            if mediaPlayer.hasUserStartedPlayback, mediaPlayer.item != nil {
                ReadBoardMiniPlayerView(
                    player: mediaPlayer,
                    openCurrentItem: openCurrentlyPlayingItem)
                    .padding(.horizontal, 8 * sidebarScale)
                    .padding(.vertical, 7 * sidebarScale)
            }

            ReadBoardHairline()
            sidebarFooter
        }
        .background(ReadBoardDesign.C.bgSidebar)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 4) {
            if environment.permissions.allows(.manageOperations, capability: .administration) {
                ReadBoardServiceHealthButton(environment: environment, scale: sidebarScale) {
                    showIssueCenter = true
                }
            }

            ReadBoardSectionLabel(text: "资料库", scale: sidebarScale)
            Spacer(minLength: 4 * sidebarScale)

            if environment.permissions.allows(.manageSources, capability: .sourceManagement) {
                Button { showCreateFolder = true } label: {
                    Image(systemName: "folder.badge.plus")
                        .readBoardInterfaceFont(size: 13 * sidebarScale)
                        .frame(width: 24 * sidebarScale, height: 24 * sidebarScale)
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
                        .readBoardInterfaceFont(size: 13 * sidebarScale)
                        .frame(width: 24 * sidebarScale, height: 24 * sidebarScale)
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(ReadBoardQuietButtonStyle())
                .help("添加订阅源 / 导入 OPML")
            }
            if environment.permissions.allows(.updateReadingState, capability: .library) {
                Button { showInboxImport = true } label: {
                    Image(systemName: "tray.and.arrow.down")
                        .readBoardInterfaceFont(size: 13 * sidebarScale)
                        .frame(width: 24 * sidebarScale, height: 24 * sidebarScale)
                }
                .buttonStyle(ReadBoardQuietButtonStyle())
                .help("添加链接到收件箱")
            }
        }
        .padding(.horizontal, 10 * sidebarScale)
        .padding(.vertical, 8 * sidebarScale)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8 * sidebarScale) {
            if environment.permissions.allows(.manageSources, capability: .sourceManagement) {
                footerButton(
                    title: "订阅管理",
                    icon: "dot.radiowaves.left.and.right",
                    destination: .sources)
            }
            if environment.permissions.allows(.manageOperations, capability: .administration) {
                footerButton(
                    title: "运行状态",
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
        .padding(.horizontal, 10 * sidebarScale)
        .padding(.vertical, 8 * sidebarScale)
    }

    private func footerButton(
        title: String,
        icon: String,
        destination target: ReadBoardDesktopDestination
    ) -> some View {
        Button { destination = target } label: {
            ViewThatFits(in: .horizontal) {
                Label(title, systemImage: icon)
                    .readBoardInterfaceFont(size: 11 * sidebarScale)
                Image(systemName: icon)
                    .readBoardInterfaceFont(size: 12 * sidebarScale)
            }
            .foregroundStyle(destination == target
                ? ReadBoardDesign.C.accent
                : ReadBoardDesign.C.text2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5 * sidebarScale)
            .contentShape(Rectangle())
        }
        .buttonStyle(ReadBoardQuietButtonStyle())
        .help(title)
    }

    private var sidebarScale: Double {
        ReadBoardLibraryColumnMetrics.sidebarScale(for: uiFontScale)
    }

    private var librarySelection: Binding<ReadBoardLibraryLocation?> {
        Binding(
            get: {
                guard case .library(let location) = destination else { return nil }
                return location
            },
            set: { location in
                if let location {
                    playbackNavigationRequest = nil
                    destination = .library(location)
                }
            })
    }

    private func openCurrentlyPlayingItem() {
        guard let item = mediaPlayer.item else { return }
        playbackNavigationRequest = ReadBoardPlaybackNavigationRequest(summary: item.summary)
        destination = .library(.collection(.all))
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

    private func handleIssueAction(_ action: ReadBoardIssueAction) {
        switch action {
        case .openSources:
            destination = .sources
        case .openOperations:
            destination = .operations
        case .openSettings(let route):
            ReadBoardSettingsNavigationStore.shared.request(route)
            if settingsTitle != nil {
                destination = .settings
            } else {
                openSettings(route)
            }
        }
    }

    @MainActor
    private func monitorRevisions() async {
        while !Task.isCancelled {
            do {
                let current = try await environment.dataRevision.snapshot()
                if let previous = lastRevision {
                    if current.library != previous.library {
                        NotificationCenter.default.post(
                            name: .readBoardLibrarySnapshotChanged, object: nil)
                    }
                    if current.sources != previous.sources {
                        await sourcesModel.load()
                        await reloadSnapshot()
                    }
                }
                lastRevision = current
                try await Task.sleep(for: .seconds(2))
            } catch is CancellationError {
                return
            } catch {
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

public extension ReadBoardDesktopMainFeatureView where SettingsContent == EmptyView {
    init(
        environment: ReadBoardFeatureEnvironment,
        initialLocation: ReadBoardLibraryLocation = .collection(.all),
        openSettings: @escaping (ReadBoardSettingsRoute) -> Void = { _ in }
    ) {
        self.init(
            environment: environment,
            initialLocation: initialLocation,
            openSettings: openSettings
        ) {
            EmptyView()
        }
    }
}
#endif
