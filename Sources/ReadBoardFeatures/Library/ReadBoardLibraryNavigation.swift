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

    public func applying(to query: ContentQuery) -> ContentQuery {
        var value = query
        switch self {
        case .collection(.pending):
            value.filter.unmetProcessingOnly = true
        case .collection(.exported):
            value.filter.exportedOnly = true
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

public struct ReadBoardLibraryNavigationPane: View {
    @Binding private var selection: ReadBoardLibraryLocation?
    public let snapshot: LibrarySnapshot?
    private let environment: ReadBoardFeatureEnvironment?
    private let presentation: ReadBoardLibraryNavigationPresentation
    @State private var expandedFolders: Set<String> = []
    @State private var restoredExpansion = false
    @State private var renameLocation: ReadBoardLibraryLocation?
    @State private var renameName = ""
    @State private var deleteLocation: ReadBoardLibraryLocation?
    @State private var operationError: String?

    public init(
        selection: Binding<ReadBoardLibraryLocation?>,
        snapshot: LibrarySnapshot?,
        environment: ReadBoardFeatureEnvironment? = nil,
        presentation: ReadBoardLibraryNavigationPresentation = .full
    ) {
        _selection = selection
        self.snapshot = snapshot
        self.environment = environment
        self.presentation = presentation
    }

    public var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            if presentation == .full {
                ReadBoardSectionLabel(text: "资料库")
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
                    .padding(.bottom, 5)
            }

            ForEach(primaryCollections) { collection in
                collectionRow(collection)
            }

            if presentation == .readerSidebar {
                sidebarDivider
                ForEach(categoryCollections) { collection in
                    collectionRow(collection)
                }
                sidebarDivider
            } else {
                ReadBoardHairline().padding(.vertical, 5).padding(.horizontal, 8)
            }

            if let nodes = snapshot?.nodes, !nodes.isEmpty {
                if presentation == .full {
                    ReadBoardSectionLabel(text: "订阅")
                        .padding(.horizontal, 10)
                        .padding(.top, 12)
                        .padding(.bottom, 5)
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
    }

    private var primaryCollections: [ReadBoardLibraryCollection] {
        switch presentation {
        case .full:
            [.all, .unread, .starred, .pending, .exported, .articles, .podcasts, .videos]
        case .readerSidebar:
            [.all, .pending, .exported]
        }
    }

    private var categoryCollections: [ReadBoardLibraryCollection] {
        [.articles, .podcasts, .videos]
    }

    private var sidebarDivider: some View {
        ReadBoardHairline()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }

    private func collectionRow(_ collection: ReadBoardLibraryCollection) -> some View {
        let location = ReadBoardLibraryLocation.collection(collection)
        return ReadBoardLibrarySidebarRow(
            title: collection.title,
            icon: collection.icon,
            iconColor: iconColor(for: collection),
            isSelected: selection == location,
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
            HStack(spacing: 2) {
                Button {
                    if expandedFolders.contains(node.id) { expandedFolders.remove(node.id) }
                    else { expandedFolders.insert(node.id) }
                    persistExpansion()
                } label: {
                    Image(systemName: expandedFolders.contains(node.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(ReadBoardDesign.C.text3)
                        .frame(width: 12, height: 24)
                }
                .buttonStyle(.plain)

                ReadBoardLibrarySidebarRow(
                    title: node.name,
                    icon: "folder",
                    isSelected: selection == .folder(id: folderID, name: node.name),
                    action: { selection = .folder(id: folderID, name: node.name) }
                ) { countLabel(unread: node.unread, total: node.count) }
            }
            .padding(.leading, 2)
            .contextMenu { locationActions(.folder(id: folderID, name: node.name)) }

            if expandedFolders.contains(node.id) {
                ForEach(node.children) { child in
                    sourceRow(child, indentation: 20)
                }
            }
        } else {
            sourceRow(node, indentation: 2)
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
                    Task { await sync(location) }
                } label: {
                    Label("立即刷新", systemImage: "arrow.clockwise")
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
                Divider()
                Button {
                    renameName = location.title
                    renameLocation = location
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    deleteLocation = location
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
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
        .frame(minWidth: 44, idealWidth: 80, maxWidth: 96, alignment: .trailing)
        .layoutPriority(2)
        .accessibilityLabel("未读 \(unread)，全部 \(total)")
    }

    private func countPair(unread: String, total: String, hasUnread: Bool) -> some View {
        HStack(spacing: 3) {
            Text(unread)
                .foregroundStyle(hasUnread ? ReadBoardDesign.C.accent : ReadBoardDesign.C.text3)
            Text("/").foregroundStyle(ReadBoardDesign.C.text3.opacity(0.55))
            Text(total).foregroundStyle(ReadBoardDesign.C.text3)
        }
        .font(.system(size: ReadBoardDesign.F.count).monospacedDigit())
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
