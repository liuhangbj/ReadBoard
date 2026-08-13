import ReadBoardContract
import ReadBoardUI
import SwiftUI

public enum ReadBoardLibraryLocation: Hashable, Identifiable, Sendable {
    case collection(ReadBoardLibraryCollection)
    case folder(id: Int64, name: String)
    case source(id: Int64, name: String)

    public var id: String {
        switch self {
        case .collection(let value): "collection:\(value.rawValue)"
        case .folder(let id, _): "folder:\(id)"
        case .source(let id, _): "source:\(id)"
        }
    }

    public var title: String {
        switch self {
        case .collection(let value): value.title
        case .folder(_, let name), .source(_, let name): name
        }
    }

    public var icon: String {
        switch self {
        case .collection(let value): value.icon
        case .folder: "folder"
        case .source: "dot.radiowaves.left.and.right"
        }
    }

    public var baseCollection: ReadBoardLibraryCollection {
        switch self {
        case .collection(let value): value
        case .folder, .source: .all
        }
    }

    fileprivate var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    public func applying(to query: ContentQuery) -> ContentQuery {
        var value = query
        switch self {
        case .collection(.pending):
            value.filter.unmetProcessingOnly = true
        case .collection(.exported):
            value.filter.exportedOnly = true
        case .collection(.inbox), .collection(.inboxArticles),
             .collection(.inboxPodcasts), .collection(.inboxVideos):
            value.filter.inboxOnly = true
        case .collection:
            break
        case .folder(let id, _):
            value.filter.folderID = id
        case .source(let id, _):
            value.filter.sourceID = id
        }
        return value
    }
}

/// “资料库”整块导航的唯一实现：固定分类、文件夹和订阅源都由同一份 LibrarySnapshot 驱动。
public enum ReadBoardLibraryNavigationPresentation: Equatable, Sendable {
    /// 独立资料库导航，显示“资料库 / 订阅”分区和所有快捷入口。
    case full
    /// 与 Core 阅读主界面一致：未读和收藏放在中栏筛选，左栏只保留内容范围。
    case readerSidebar
}

private struct PendingHistoryAction {
    enum Operation {
        case processing(SourcePolicyKey)
        case fulltext
    }

    let scope: SourceScope
    let name: String
    let label: String
    let operation: Operation
}

private struct FetchModeSelection: Equatable {
    let automatic: Bool
    let mode: SourceFetchMode
}

public struct ReadBoardLibraryNavigationPane: View {
    @Binding private var selection: ReadBoardLibraryLocation?
    public let snapshot: LibrarySnapshot?
    private let environment: ReadBoardFeatureEnvironment?
    private let sourceModel: ReadBoardSourcesFeatureModel?
    private let presentation: ReadBoardLibraryNavigationPresentation
    private let scale: Double
    @State private var expandedFolders: Set<String> = []
    @State private var restoredExpansion = false
    @State private var renameLocation: ReadBoardLibraryLocation?
    @State private var renameName = ""
    @State private var deleteLocation: ReadBoardLibraryLocation?
    @State private var operationError: String?
    @State private var pendingHistory: PendingHistoryAction?

    public init(
        selection: Binding<ReadBoardLibraryLocation?>,
        snapshot: LibrarySnapshot?,
        environment: ReadBoardFeatureEnvironment? = nil,
        sourceModel: ReadBoardSourcesFeatureModel? = nil,
        presentation: ReadBoardLibraryNavigationPresentation = .full,
        scale: Double = 1
    ) {
        _selection = selection
        self.snapshot = snapshot
        self.environment = environment
        self.sourceModel = sourceModel
        self.presentation = presentation
        self.scale = scale
    }

    public var body: some View {
        LazyVStack(alignment: .leading, spacing: 2 * scale) {
            if presentation == .full {
                ReadBoardSectionLabel(text: "资料库", scale: scale)
                    .padding(.horizontal, 10 * scale)
                    .padding(.top, 12 * scale)
                    .padding(.bottom, 5 * scale)
            }

            ForEach(primaryCollections) { collection in
                collectionRow(collection)
            }

            if presentation == .readerSidebar {
                ForEach(inboxCollections) { collection in
                    collectionRow(collection)
                        .padding(.leading, 18 * scale)
                }
            }

            if presentation == .readerSidebar {
                sidebarDivider
                ForEach(categoryCollections) { collection in
                    collectionRow(collection)
                }
                sidebarDivider
            } else {
                ReadBoardHairline()
                    .padding(.vertical, 5 * scale)
                    .padding(.horizontal, 8 * scale)
            }

            if let nodes = snapshot?.nodes, !nodes.isEmpty {
                if presentation == .full {
                    ReadBoardSectionLabel(text: "订阅", scale: scale)
                        .padding(.horizontal, 10 * scale)
                        .padding(.top, 12 * scale)
                        .padding(.bottom, 5 * scale)
                }

                ForEach(nodes) { node in
                    nodeRow(node)
                }
            }
        }
        .onAppear { restoreExpansionIfNeeded(nodes: snapshot?.nodes ?? []) }
        .onChange(of: snapshot?.nodes ?? []) { _, nodes in
            restoreExpansionIfNeeded(nodes: nodes)
        }
        .alert("重命名", isPresented: Binding(
            get: { renameLocation != nil },
            set: { if !$0 { renameLocation = nil } }
        )) {
            TextField("名称", text: $renameName)
            Button("取消", role: .cancel) { renameLocation = nil }
            Button("保存") { Task { await commitRename() } }
                .disabled(renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("修改后会同步更新所有连接到当前服务端的阅读器。")
        }
        .alert(deleteAlertTitle, isPresented: Binding(
            get: { deleteLocation != nil },
            set: { if !$0 { deleteLocation = nil } }
        )) {
            Button("取消", role: .cancel) { deleteLocation = nil }
            Button("删除", role: .destructive) { Task { await commitDelete() } }
        } message: {
            Text(deleteAlertMessage)
        }
        .alert("操作失败", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("好", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "请稍后重试")
        }
        .alert("处理历史数据？", isPresented: Binding(
            get: { pendingHistory != nil },
            set: { if !$0 { pendingHistory = nil } }
        )) {
            Button(pendingHistoryButtonTitle) {
                guard let pendingHistory, let sourceModel else { return }
                let action = pendingHistory
                self.pendingHistory = nil
                Task {
                    switch action.operation {
                    case .processing(let key):
                        await sourceModel.backfillProcessing(scope: action.scope, key: key)
                    case .fulltext:
                        await sourceModel.refetchFulltext(scope: action.scope, fullHistory: true)
                    }
                }
            }
            Button("只处理新增", role: .cancel) { pendingHistory = nil }
        } message: {
            if let pendingHistory {
                Text(pendingHistoryMessage(pendingHistory))
            }
        }
    }

    private var primaryCollections: [ReadBoardLibraryCollection] {
        switch presentation {
        case .full:
            [.all, .unread, .starred, .pending, .exported, .inbox,
             .inboxArticles, .inboxPodcasts, .inboxVideos,
             .articles, .podcasts, .videos]
        case .readerSidebar:
            [.all, .pending, .exported, .inbox]
        }
    }

    private var inboxCollections: [ReadBoardLibraryCollection] {
        [.inboxArticles, .inboxPodcasts, .inboxVideos]
    }

    private var categoryCollections: [ReadBoardLibraryCollection] {
        [.articles, .podcasts, .videos]
    }

    private var sidebarDivider: some View {
        ReadBoardHairline()
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 5 * scale)
    }

    private func collectionRow(_ collection: ReadBoardLibraryCollection) -> some View {
        let location = ReadBoardLibraryLocation.collection(collection)
        return ReadBoardLibrarySidebarRow(
            title: collection.title,
            icon: collection.icon,
            iconColor: iconColor(for: collection),
            isSelected: selection == location,
            scale: scale,
            action: { selection = location }
        ) {
            if let counts = snapshot?.counts,
               let pair = collection.countPair(in: counts) {
                countLabel(unread: pair.unread, total: pair.total)
            }
        }
    }

    @ViewBuilder
    private func nodeRow(_ node: LibraryNode) -> some View {
        if node.kind == .folder, let folderID = node.folderID {
            HStack(spacing: 2 * scale) {
                Button {
                    if expandedFolders.contains(node.id) { expandedFolders.remove(node.id) }
                    else { expandedFolders.insert(node.id) }
                    persistExpansion()
                } label: {
                    Image(systemName: expandedFolders.contains(node.id) ? "chevron.down" : "chevron.right")
                        .readBoardInterfaceFont(size: 8 * scale, weight: .semibold)
                        .foregroundStyle(ReadBoardDesign.C.text3)
                        .frame(width: 12 * scale, height: 24 * scale)
                }
                .buttonStyle(.plain)

                ReadBoardLibrarySidebarRow(
                    title: node.name,
                    icon: "folder",
                    isSelected: selection == .folder(id: folderID, name: node.name),
                    scale: scale,
                    action: { selection = .folder(id: folderID, name: node.name) }
                ) { countLabel(unread: node.unread, total: node.count) }
            }
            .padding(.leading, 2 * scale)
            .contextMenu { locationActions(.folder(id: folderID, name: node.name)) }

            if expandedFolders.contains(node.id) {
                ForEach(node.children) { child in
                    sourceRow(child, indentation: 20 * scale)
                }
            }
        } else {
            sourceRow(node, indentation: 2 * scale)
        }
    }

    @ViewBuilder
    private func sourceRow(_ node: LibraryNode, indentation: CGFloat) -> some View {
        if let sourceID = node.sourceID {
            ReadBoardLibrarySidebarRow(
                title: node.name,
                icon: "dot.radiowaves.left.and.right",
                iconColor: ReadBoardDesign.C.rss,
                isSelected: selection == .source(id: sourceID, name: node.name),
                scale: scale,
                action: { selection = .source(id: sourceID, name: node.name) }
            ) { countLabel(unread: node.unread, total: node.count) }
            .padding(.leading, indentation)
            .contextMenu { locationActions(.source(id: sourceID, name: node.name)) }
        }
    }

    @ViewBuilder
    private func locationActions(_ location: ReadBoardLibraryLocation) -> some View {
        if let environment {
            if environment.permissions.allows(.manageSources, capability: .sourceManagement) {
                Button {
                    renameName = location.title
                    renameLocation = location
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button {
                    Task {
                        if let sourceModel, let scope = sourceScope(for: location) {
                            await sourceModel.sync(scope: scope)
                        } else {
                            await sync(location)
                        }
                    }
                } label: {
                    Label(
                        location.isFolder ? "立即刷新全部" : "立即刷新",
                        systemImage: "arrow.clockwise")
                }
            }
            if environment.permissions.allows(.updateReadingState, capability: .library) {
                Button {
                    Task { await markRead(location) }
                } label: {
                    Label("全部标为已读", systemImage: "checkmark.circle")
                }
            }
            if environment.permissions.allows(.manageSources, capability: .sourceManagement) {
                if let sourceModel {
                    Divider()
                    Menu("内容处理", systemImage: "gearshape.2") {
                        processingMenu(location, model: sourceModel)
                    }
                    Menu("抓取设置", systemImage: "arrow.down.circle") {
                        fetchMenu(location, model: sourceModel)
                    }
                    Button {
                        guard let scope = sourceScope(for: location) else { return }
                        Task { await sourceModel.refetchFulltext(
                            scope: scope,
                            fullHistory: true) }
                    } label: {
                        Label("重新提取全文", systemImage: "arrow.triangle.2.circlepath")
                    }
                    if case .source(let sourceID, _) = location {
                        Divider()
                        Menu("移动到文件夹", systemImage: "folder") {
                            Button("无文件夹") {
                                Task { await sourceModel.assignSource(
                                    sourceID: sourceID,
                                    folderID: nil) }
                            }
                            Divider()
                            ForEach(sourceModel.snapshot?.folders ?? []) { folder in
                                Button {
                                    Task { await sourceModel.assignSource(
                                        sourceID: sourceID,
                                        folderID: folder.id) }
                                } label: {
                                    Label(
                                        folder.name,
                                        systemImage: sourceItem(sourceID, model: sourceModel)?.folderID == folder.id
                                            ? "checkmark" : "")
                                }
                            }
                        }
                    }
                }
                Divider()
                Button(role: .destructive) {
                    deleteLocation = location
                } label: {
                    Label(
                        location.isFolder ? "删除文件夹" : "永久删除此源",
                        systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func processingMenu(
        _ location: ReadBoardLibraryLocation,
        model: ReadBoardSourcesFeatureModel
    ) -> some View {
        if let scope = sourceScope(for: location) {
            Button {
                Task { await model.backfillProcessing(scope: scope, key: nil) }
            } label: {
                Label(
                    scope.kind == .folder ? "重新处理本夹全部" : "重新处理本源全部",
                    systemImage: "arrow.triangle.2.circlepath")
            }
            Divider()
            processingPolicyButton("AI 评分", key: .score, location: location, model: model)
            processingPolicyButton("AI 摘要", key: .summarize, location: location, model: model)
            processingPolicyButton("AI 翻译", key: .translate, location: location, model: model)
            if supportsTranscription(location, model: model) {
                processingPolicyButton("AI 转录", key: .transcribe, location: location, model: model)
            }
        }
    }

    private func processingPolicyButton(
        _ label: String,
        key: SourcePolicyKey,
        location: ReadBoardLibraryLocation,
        model: ReadBoardSourcesFeatureModel
    ) -> some View {
        let state = policyState(location, key: key, model: model)
        return Button {
            guard let scope = sourceScope(for: location) else { return }
            let turningOn = state != true
            Task {
                await model.setPolicy(
                    scope: scope,
                    key: key,
                    enabled: turningOn)
                if turningOn, model.errorMessage == nil {
                    pendingHistory = PendingHistoryAction(
                        scope: scope,
                        name: location.title,
                        label: label,
                        operation: .processing(key))
                }
            }
        } label: {
            if state == nil {
                Label("\(label)（按订阅源设置）", systemImage: "")
            } else {
                Label(label, systemImage: state == true ? "checkmark" : "")
            }
        }
    }

    @ViewBuilder
    private func fetchMenu(
        _ location: ReadBoardLibraryLocation,
        model: ReadBoardSourcesFeatureModel
    ) -> some View {
        if let scope = sourceScope(for: location) {
            let currentMode = fetchModeState(location, model: model)
            Menu("提取全文：\(fetchModeLabel(currentMode, location: location, model: model))") {
                Button {
                    Task {
                        await model.setFetchMode(scope: scope, mode: .automatic)
                        if model.errorMessage == nil {
                            pendingHistory = PendingHistoryAction(
                                scope: scope,
                                name: location.title,
                                label: "自动检测",
                                operation: .fulltext)
                        }
                    }
                } label: {
                    Label(
                        automaticFetchModeTitle(location, model: model),
                        systemImage: currentMode?.automatic == true ? "checkmark" : "")
                }
                Button("重新检测") {
                    Task { await model.redetectFetchMode(scope: scope) }
                }
                Divider()
                ForEach(fetchModes(location, model: model), id: \.rawValue) { mode in
                    Button {
                        Task {
                            await model.setFetchMode(scope: scope, mode: mode)
                            if model.errorMessage == nil {
                                pendingHistory = PendingHistoryAction(
                                    scope: scope,
                                    name: location.title,
                                    label: fetchModeName(mode, location: location, model: model),
                                    operation: .fulltext)
                            }
                        }
                    } label: {
                        Label(
                            fetchModeName(mode, location: location, model: model),
                            systemImage: currentMode == FetchModeSelection(
                                automatic: false, mode: mode) ? "checkmark" : "")
                    }
                }
                if case .folder = location, currentMode == nil {
                    Divider()
                    Button("按订阅源设置", systemImage: "checkmark") {}
                        .disabled(true)
                }
            }

            let interval = fetchIntervalState(location, model: model)
            Menu("抓取频率：\(interval.map(intervalName) ?? "按订阅源设置")") {
                ForEach([5, 15, 30, 60, 120, 360, 720], id: \.self) { minutes in
                    Button {
                        Task { await model.setFetchInterval(
                            scope: scope,
                            minutes: minutes) }
                    } label: {
                        Label(
                            intervalName(minutes),
                            systemImage: interval == minutes ? "checkmark" : "")
                    }
                }
                if case .folder = location, interval == nil {
                    Divider()
                    Button("按订阅源设置", systemImage: "checkmark") {}
                        .disabled(true)
                }
            }
        }
    }

    private func sourceItem(
        _ id: Int64,
        model: ReadBoardSourcesFeatureModel
    ) -> SourceCatalogItem? {
        model.snapshot?.sources.first { $0.id == id }
    }

    private func sources(
        in location: ReadBoardLibraryLocation,
        model: ReadBoardSourcesFeatureModel
    ) -> [SourceCatalogItem] {
        switch location {
        case .source(let id, _):
            return model.snapshot?.sources.filter { $0.id == id } ?? []
        case .folder(let id, _):
            return model.snapshot?.sources.filter { $0.folderID == id } ?? []
        case .collection:
            return []
        }
    }

    private func policyState(
        _ location: ReadBoardLibraryLocation,
        key: SourcePolicyKey,
        model: ReadBoardSourcesFeatureModel
    ) -> Bool? {
        let values = sources(in: location, model: model).map { item in
            switch key {
            case .score: item.policy.autoScore
            case .translate: item.policy.autoTranslate
            case .summarize: item.policy.autoSummarize
            case .transcribe: item.policy.autoTranscribe
            }
        }
        guard let first = values.first else { return false }
        return values.allSatisfy { $0 == first } ? first : nil
    }

    private func supportsTranscription(
        _ location: ReadBoardLibraryLocation,
        model: ReadBoardSourcesFeatureModel
    ) -> Bool {
        sources(in: location, model: model).contains(where: \.transcribable)
    }

    private func fetchModeState(
        _ location: ReadBoardLibraryLocation,
        model: ReadBoardSourcesFeatureModel
    ) -> FetchModeSelection? {
        let values = sources(in: location, model: model).map {
            FetchModeSelection(automatic: $0.fetchModeAutomatic, mode: $0.fetchMode)
        }
        guard let first = values.first else { return nil }
        return values.allSatisfy { $0 == first } ? first : nil
    }

    private func fetchIntervalState(
        _ location: ReadBoardLibraryLocation,
        model: ReadBoardSourcesFeatureModel
    ) -> Int? {
        let values = sources(in: location, model: model).map(\.fetchIntervalMinutes)
        guard let first = values.first else { return nil }
        return values.allSatisfy { $0 == first } ? first : nil
    }

    private func fetchModes(
        _ location: ReadBoardLibraryLocation,
        model: ReadBoardSourcesFeatureModel
    ) -> [SourceFetchMode] {
        switch location {
        case .source:
            return sources(in: location, model: model)
                .flatMap(\.availableFetchModes)
                .filter { $0 != .automatic }
        case .folder:
            return [.feedFull, .defuddle, .summary]
        case .collection:
            return []
        }
    }

    private func fetchModeName(
        _ mode: SourceFetchMode,
        location: ReadBoardLibraryLocation,
        model: ReadBoardSourcesFeatureModel
    ) -> String {
        if mode == .externalFulltext,
           let title = sources(in: location, model: model)
            .compactMap(\.fulltextDisplayName).first {
            return title
        }
        switch mode {
        case .automatic: return "自动检测"
        case .feedFull: return "Feed 全文"
        case .defuddle: return "网页正文提取"
        case .youtubeSubtitle: return "YouTube 字幕"
        case .bilibiliSubtitle: return "Bilibili 字幕"
        case .externalFulltext: return "平台全文"
        case .summary: return "仅摘要"
        }
    }

    private func fetchModeLabel(
        _ selection: FetchModeSelection?,
        location: ReadBoardLibraryLocation,
        model: ReadBoardSourcesFeatureModel
    ) -> String {
        guard let selection else { return "按订阅源设置" }
        let modeName = fetchModeName(selection.mode, location: location, model: model)
        return selection.automatic ? "自动（\(modeName)）" : modeName
    }

    private func automaticFetchModeTitle(
        _ location: ReadBoardLibraryLocation,
        model: ReadBoardSourcesFeatureModel
    ) -> String {
        guard let mode = fetchModeState(location, model: model), mode.automatic else {
            return "自动检测"
        }
        return "自动（\(fetchModeName(mode.mode, location: location, model: model))）"
    }

    private func intervalName(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时"
    }

    private var pendingHistoryButtonTitle: String {
        guard let pendingHistory else { return "处理所有历史内容" }
        switch pendingHistory.operation {
        case .processing: return "处理所有历史内容"
        case .fulltext: return "重提所有历史全文"
        }
    }

    private func pendingHistoryMessage(_ action: PendingHistoryAction) -> String {
        switch action.operation {
        case .processing:
            return "“\(action.name)”的\(action.label)已开启。\n\n• 处理历史：存量内容补做相应处理（耗时较长，可能产生模型费用）\n• 只处理新增：历史不动，新抓内容按新设置处理"
        case .fulltext:
            return "“\(action.name)”的全文提取模式已切换为\(action.label)。\n\n• 重提历史：存量文章按新模式重新提取全文（耗时较长）\n• 只处理新增：历史不动，新抓内容按新模式抓取"
        }
    }

    private func sync(_ location: ReadBoardLibraryLocation) async {
        guard let environment, let scope = sourceScope(for: location) else { return }
        do {
            _ = try await environment.sourceManagement.sync(scope: scope)
            notifySnapshotChanged()
        } catch is CancellationError {
            return
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func markRead(_ location: ReadBoardLibraryLocation) async {
        guard let environment else { return }
        var filter = ContentFilter()
        switch location {
        case .folder(let id, _): filter.folderID = id
        case .source(let id, _): filter.sourceID = id
        case .collection: return
        }
        do {
            _ = try await environment.library.markRead(filter: filter)
            notifySnapshotChanged()
        } catch is CancellationError {
            return
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func commitRename() async {
        guard let environment, let location = renameLocation,
              let scope = sourceScope(for: location) else { return }
        let name = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            _ = try await environment.sourceManagement.rename(scope: scope, name: name)
            renameLocation = nil
            notifySnapshotChanged()
        } catch is CancellationError {
            return
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func commitDelete() async {
        guard let environment, let location = deleteLocation,
              let scope = sourceScope(for: location) else { return }
        do {
            _ = try await environment.sourceManagement.remove(scope: scope)
            if selection == location { selection = .collection(.all) }
            deleteLocation = nil
            notifySnapshotChanged()
        } catch is CancellationError {
            return
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func sourceScope(for location: ReadBoardLibraryLocation) -> SourceScope? {
        switch location {
        case .folder(let id, _): SourceScope(kind: .folder, id: id)
        case .source(let id, _): SourceScope(kind: .source, id: id)
        case .collection: nil
        }
    }

    private func notifySnapshotChanged() {
        NotificationCenter.default.post(name: .readBoardLibrarySnapshotChanged, object: nil)
    }

    private var deleteAlertTitle: String {
        guard let deleteLocation else { return "删除订阅？" }
        return "删除“\(deleteLocation.title)”？"
    }

    private var deleteAlertMessage: String {
        guard let deleteLocation else { return "" }
        switch deleteLocation {
        case .folder:
            return "文件夹内的订阅源会移到未分组，内容不会删除。"
        case .source:
            return "该订阅源及其内容和处理结果会被永久删除，此操作无法撤销。"
        case .collection:
            return ""
        }
    }

    private func countLabel(unread: Int, total: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            countPair(unread: "\(unread)", total: "\(total)", hasUnread: unread > 0)
            countPair(
                unread: Self.compactCount(unread),
                total: Self.compactCount(total),
                hasUnread: unread > 0)
        }
        .frame(
            minWidth: 44 * scale,
            idealWidth: 80 * scale,
            maxWidth: 96 * scale,
            alignment: .trailing)
        .layoutPriority(2)
        .accessibilityLabel("未读 \(unread)，全部 \(total)")
    }

    private func countPair(unread: String, total: String, hasUnread: Bool) -> some View {
        HStack(spacing: 3 * scale) {
            Text(unread)
                .foregroundStyle(hasUnread ? ReadBoardDesign.C.accent : ReadBoardDesign.C.text3)
            Text("/").foregroundStyle(ReadBoardDesign.C.text3.opacity(0.55))
            Text(total).foregroundStyle(ReadBoardDesign.C.text3)
        }
        .readBoardInterfaceFont(size: ReadBoardDesign.F.count * scale)
        .monospacedDigit()
        .lineLimit(1)
    }

    nonisolated static func compactCount(_ count: Int) -> String {
        guard count >= 10_000 else { return String(count) }
        let value = Double(count) / 10_000
        if value >= 10 || value.rounded() == value { return "\(Int(value.rounded()))万" }
        return String(format: "%.1f万", value)
    }

    private func restoreExpansionIfNeeded(nodes: [LibraryNode]) {
        guard !restoredExpansion, !nodes.isEmpty else { return }
        if let saved = UserDefaults.standard.array(forKey: expandedKey) as? [String] {
            expandedFolders = Set(saved)
        } else {
            expandedFolders = presentation == .readerSidebar
                ? []
                : Set(nodes.filter { $0.kind == .folder }.map(\.id))
        }
        restoredExpansion = true
    }

    private func persistExpansion() {
        UserDefaults.standard.set(Array(expandedFolders).sorted(), forKey: expandedKey)
    }

    private var expandedKey: String {
        switch presentation {
        case .full: "sidebar.expandedFolders"
        case .readerSidebar: "sidebar.expandedFolders.sharedReader"
        }
    }

    private func iconColor(for collection: ReadBoardLibraryCollection) -> Color {
        switch collection {
        case .starred: ReadBoardDesign.C.star
        case .pending: ReadBoardDesign.C.scoreMid
        case .exported: ReadBoardDesign.C.translate
        case .podcasts: ReadBoardDesign.C.podcast
        case .videos: ReadBoardDesign.C.video
        default: ReadBoardDesign.C.accent
        }
    }
}
