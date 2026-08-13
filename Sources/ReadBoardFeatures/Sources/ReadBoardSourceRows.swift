import ReadBoardContract
import ReadBoardUI
import SwiftUI

private let sourcePolicyDefinitions: [(SourcePolicyKey, String)] = [
    (.score, "AI 评分"),
    (.summarize, "AI 摘要"),
    (.translate, "AI 翻译"),
    (.transcribe, "AI 转录"),
]

private enum SourceRowMetrics {
    static let baseControlWidth: CGFloat = 108
    static let policyControlWidth: CGFloat = 82
    static let controlSpacing: CGFloat = 7
    static let groupSpacing: CGFloat = 22
}

private struct SourceFetchModeSelection: Equatable {
    let automatic: Bool
    let mode: SourceFetchMode
}

/// 固定的八列只创建一次：宽度足够时单行，较窄时在基础设置与 AI 设置之间换行。
/// 相比 ViewThatFits，不会为了测量同时构造两套 Menu/Toggle 子树。
private struct SourceConfigurationLayout: Layout {
    let controlSpacing: CGFloat
    let groupSpacing: CGFloat
    let rowSpacing: CGFloat = 7

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let dimensions = subviews.map { $0.dimensions(in: .unspecified) }
        let single = singleRowSize(dimensions)
        guard (proposal.width ?? .infinity) < single.width else { return single }
        let split = min(4, dimensions.count)
        let top = rowSize(Array(dimensions[..<split]))
        let bottom = rowSize(Array(dimensions[split...]))
        return CGSize(
            width: max(top.width, bottom.width),
            height: top.height + rowSpacing + bottom.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let dimensions = subviews.map { $0.dimensions(in: .unspecified) }
        if bounds.width >= singleRowSize(dimensions).width {
            placeRow(
                subviews: subviews,
                dimensions: dimensions,
                indices: Array(subviews.indices),
                origin: bounds.origin,
                insertsGroupGap: true)
            return
        }

        let split = min(4, dimensions.count)
        let topIndices = Array(subviews.indices.prefix(split))
        let bottomIndices = Array(subviews.indices.dropFirst(split))
        placeRow(
            subviews: subviews,
            dimensions: dimensions,
            indices: topIndices,
            origin: bounds.origin,
            insertsGroupGap: false)
        let topHeight = topIndices.map { dimensions[$0].height }.max() ?? 0
        placeRow(
            subviews: subviews,
            dimensions: dimensions,
            indices: bottomIndices,
            origin: CGPoint(x: bounds.minX, y: bounds.minY + topHeight + rowSpacing),
            insertsGroupGap: false)
    }

    private func singleRowSize(_ dimensions: [ViewDimensions]) -> CGSize {
        guard !dimensions.isEmpty else { return .zero }
        let width = dimensions.enumerated().reduce(CGFloat.zero) { result, value in
            result + value.element.width + (value.offset == 0
                ? 0
                : (value.offset == 4 ? groupSpacing : controlSpacing))
        }
        return CGSize(width: width, height: dimensions.map(\.height).max() ?? 0)
    }

    private func rowSize(_ dimensions: [ViewDimensions]) -> CGSize {
        guard !dimensions.isEmpty else { return .zero }
        return CGSize(
            width: dimensions.map(\.width).reduce(0, +)
                + controlSpacing * CGFloat(max(0, dimensions.count - 1)),
            height: dimensions.map(\.height).max() ?? 0)
    }

    private func placeRow(
        subviews: Subviews,
        dimensions: [ViewDimensions],
        indices: [Subviews.Index],
        origin: CGPoint,
        insertsGroupGap: Bool
    ) {
        var x = origin.x
        let rowHeight = indices.map { dimensions[$0].height }.max() ?? 0
        for (offset, index) in indices.enumerated() {
            if offset > 0 {
                x += insertsGroupGap && offset == 4 ? groupSpacing : controlSpacing
            }
            let size = dimensions[index]
            subviews[index].place(
                at: CGPoint(x: x, y: origin.y + (rowHeight - size.height) / 2),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width
        }
    }
}

struct ReadBoardSourceFolderHeader: View {
    let folder: SourceFolderItem
    let sources: [SourceCatalogItem]
    let model: ReadBoardSourcesFeatureModel
    let isCollapsed: Bool
    let toggleCollapsed: () -> Void

    @State private var showRename = false
    @State private var renameName = ""
    @State private var showDelete = false
    @State private var pendingPolicy: SourcePolicyKey?

    private var scope: SourceScope { SourceScope(kind: .folder, id: folder.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: ReadBoardDesign.Space.sm) {
                Button(action: toggleCollapsed) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .readBoardInterfaceFont(size: 9, weight: .semibold)
                        .foregroundStyle(ReadBoardDesign.C.text3)
                        .frame(width: 16, height: 22)
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "展开文件夹" : "收起文件夹")

                Image(systemName: "folder.fill")
                    .foregroundStyle(ReadBoardDesign.C.accent)
                Text(folder.name)
                    .readBoardInterfaceFont(size: 13, weight: .semibold)
                    .foregroundStyle(ReadBoardDesign.C.text)
                    .textCase(nil)
                Text("\(sources.count)")
                    .readBoardInterfaceFont(size: 10)
                    .monospacedDigit()
                    .foregroundStyle(ReadBoardDesign.C.text3)
                Spacer()
                Menu {
                    Button("立即刷新", systemImage: "arrow.clockwise") {
                        Task { await model.sync(scope: scope) }
                    }
                    Button("重新提取近期全文", systemImage: "doc.text.magnifyingglass") {
                        Task { await model.refetchFulltext(scope: scope, fullHistory: false) }
                    }
                    Button("重新提取全部全文", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                        Task { await model.refetchFulltext(scope: scope, fullHistory: true) }
                    }
                    Divider()
                    Button("重命名", systemImage: "pencil") {
                        renameName = folder.name
                        showRename = true
                    }
                    Button("删除文件夹", systemImage: "trash", role: .destructive) {
                        showDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
            }

            ReadBoardSourceConfigurationStrip(
                scope: scope,
                sources: sources,
                source: nil,
                folders: [],
                folderPlaceholder: folder.name,
                model: model,
                pendingPolicy: $pendingPolicy)
                .padding(.leading, 24)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReadBoardDesign.C.accent.opacity(0.065))
        .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md))
        .textCase(nil)
        .alert("重命名文件夹", isPresented: $showRename) {
            TextField("文件夹名称", text: $renameName)
            Button("取消", role: .cancel) {}
            Button("保存") {
                Task { await model.rename(scope: scope, name: renameName) }
            }
        }
        .alert("删除文件夹“\(folder.name)”？", isPresented: $showDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await model.remove(scope: scope) }
            }
        } message: {
            Text("文件夹内的订阅源会移到未分组，内容不会删除。")
        }
        .alert("处理历史数据？", isPresented: Binding(
            get: { pendingPolicy != nil },
            set: { if !$0 { pendingPolicy = nil } }
        )) {
            Button("处理所有历史内容") {
                guard let key = pendingPolicy else { return }
                pendingPolicy = nil
                Task { await model.setPolicy(
                    scope: scope,
                    key: key,
                    enabled: true,
                    backfillHistory: true) }
            }
            Button("只处理新增", role: .cancel) {
                guard let key = pendingPolicy else { return }
                pendingPolicy = nil
                Task { await model.setPolicy(scope: scope, key: key, enabled: true) }
            }
        } message: {
            Text("可将文件夹内所有存量内容加入相应处理队列；这可能耗时较长并产生模型费用。")
        }
    }

}

struct ReadBoardSourceFeatureRow: View, Equatable {
    let source: SourceCatalogItem
    let folders: [SourceFolderItem]
    let model: ReadBoardSourcesFeatureModel

    @State private var showRename = false
    @State private var renameName = ""
    @State private var showDelete = false
    @State private var pendingPolicy: SourcePolicyKey?

    private var scope: SourceScope { SourceScope(kind: .source, id: source.id) }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source
            && lhs.folders == rhs.folders
            && lhs.model === rhs.model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: ReadBoardDesign.Space.md) {
                Image(systemName: sourceIcon)
                    .readBoardInterfaceFont(size: 13)
                    .foregroundStyle(sourceColor)
                    .frame(width: 25, height: 25)
                    .background(sourceColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(source.name)
                            .readBoardInterfaceFont(size: 13, weight: .medium)
                            .foregroundStyle(source.enabled
                                ? ReadBoardDesign.C.text
                                : ReadBoardDesign.C.text3)
                            .lineLimit(1)
                        ReadBoardBadge(text: statusText, color: statusColor)
                        Text("\(source.contentCount) 项")
                            .readBoardInterfaceFont(size: 10)
                            .monospacedDigit()
                            .foregroundStyle(ReadBoardDesign.C.text3)
                    }
                    Text(source.identifier)
                        .font(.system(size: 9).monospaced())
                        .foregroundStyle(ReadBoardDesign.C.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Toggle("启用", isOn: Binding(
                    get: { source.enabled },
                    set: { value in Task { await model.setEnabled(
                        sourceID: source.id,
                        enabled: value) } }))
                    .labelsHidden()
                    .controlSize(.small)
                    .help(source.enabled ? "停用订阅源" : "启用订阅源")
                actionMenu
            }

            ReadBoardSourceConfigurationStrip(
                scope: scope,
                sources: [source],
                source: source,
                folders: folders,
                folderPlaceholder: nil,
                model: model,
                pendingPolicy: $pendingPolicy)
                .padding(.leading, 37)

            if let error = source.error, !error.isEmpty {
                Label(error, systemImage: source.isRecovering
                    ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                    .readBoardInterfaceFont(size: 10)
                    .foregroundStyle(source.isRecovering
                        ? ReadBoardDesign.C.scoreMid : ReadBoardDesign.C.scoreLow)
                    .lineLimit(2)
                    .padding(.leading, 37)
            }
        }
        .padding(.vertical, 7)
        .contextMenu { sourceContextMenu }
        .alert("重命名订阅源", isPresented: $showRename) {
            TextField("订阅源名称", text: $renameName)
            Button("取消", role: .cancel) {}
            Button("保存") { Task { await model.rename(scope: scope, name: renameName) } }
        }
        .alert("删除订阅源？", isPresented: $showDelete) {
            Button("取消", role: .cancel) {}
            Button("永久删除", role: .destructive) {
                Task { await model.remove(scope: scope) }
            }
        } message: {
            Text("将永久删除“\(source.name)”及其全部内容、AI 处理结果和应用内导出记录。此操作无法撤销。")
        }
        .alert("处理历史数据？", isPresented: Binding(
            get: { pendingPolicy != nil },
            set: { if !$0 { pendingPolicy = nil } }
        )) {
            Button("处理所有历史内容") {
                guard let key = pendingPolicy else { return }
                pendingPolicy = nil
                Task { await model.setPolicy(
                    scope: scope,
                    key: key,
                    enabled: true,
                    backfillHistory: true) }
            }
            Button("只处理新增", role: .cancel) {
                guard let key = pendingPolicy else { return }
                pendingPolicy = nil
                Task { await model.setPolicy(scope: scope, key: key, enabled: true) }
            }
        } message: {
            Text("可将这个订阅源的存量内容加入相应处理队列；这可能耗时较长并产生模型费用。")
        }
    }

    private var actionMenu: some View {
        Menu {
            sourceContextMenu
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
    }

    @ViewBuilder
    private var sourceContextMenu: some View {
        Button("立即刷新", systemImage: "arrow.clockwise") {
            Task { await model.sync(scope: scope) }
        }
        Button("重新提取近期全文", systemImage: "doc.text.magnifyingglass") {
            Task { await model.refetchFulltext(scope: scope, fullHistory: false) }
        }
        Button("重新提取全部全文", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
            Task { await model.refetchFulltext(scope: scope, fullHistory: true) }
        }
        Divider()
        Button("重命名", systemImage: "pencil") {
            renameName = source.name
            showRename = true
        }
        Button("删除订阅源", systemImage: "trash", role: .destructive) {
            showDelete = true
        }
    }

    private var statusText: String {
        if !source.enabled { return "已停用" }
        if source.isRecovering { return "恢复中" }
        if source.hasError { return "异常" }
        if source.isStale { return "待更新" }
        return "正常"
    }

    private var statusColor: Color {
        if !source.enabled { return ReadBoardDesign.C.text3 }
        if source.isRecovering { return ReadBoardDesign.C.scoreMid }
        if source.hasError { return ReadBoardDesign.C.scoreLow }
        if source.isStale { return ReadBoardDesign.C.scoreMid }
        return ReadBoardDesign.C.scoreHigh
    }

    private var sourceIcon: String {
        let type = source.sourceType.lowercased()
        if type.contains("youtube") { return "play.rectangle.fill" }
        if type.contains("bilibili") { return "play.tv.fill" }
        if type.contains("wechat") { return "message.fill" }
        if type.contains("podcast") { return "mic.fill" }
        return "dot.radiowaves.left.and.right"
    }

    private var sourceColor: Color {
        let type = source.sourceType.lowercased()
        if type.contains("youtube") { return ReadBoardDesign.C.youtube }
        if type.contains("bilibili") { return ReadBoardDesign.C.bilibili }
        if type.contains("wechat") { return ReadBoardDesign.C.wechat }
        if type.contains("podcast") { return ReadBoardDesign.C.podcast }
        return ReadBoardDesign.C.rss
    }

}

private struct ReadBoardSourceConfigurationStrip: View {
    let scope: SourceScope
    let sources: [SourceCatalogItem]
    let source: SourceCatalogItem?
    let folders: [SourceFolderItem]
    let folderPlaceholder: String?
    let model: ReadBoardSourcesFeatureModel
    @Binding var pendingPolicy: SourcePolicyKey?

    var body: some View {
        SourceConfigurationLayout(
            controlSpacing: SourceRowMetrics.controlSpacing,
            groupSpacing: SourceRowMetrics.groupSpacing
        ) {
            baseControls
            policyControls
        }
    }

    @ViewBuilder
    private var baseControls: some View {
        fetchModeMenu
        intervalControl
        retentionMenu
        folderControl
    }

    @ViewBuilder
    private var policyControls: some View {
        ForEach(sourcePolicyDefinitions, id: \.0.rawValue) { key, title in
            if key != .transcribe || supportsTranscription {
                let uniform = uniformPolicy(key)
                Toggle(title, isOn: Binding(
                    get: { uniform ?? false },
                    set: { enabled in
                        if enabled {
                            pendingPolicy = key
                        } else {
                            Task { await model.setPolicy(
                                scope: scope,
                                key: key,
                                enabled: false) }
                        }
                    }))
                    .readBoardPolicyToggleStyle()
                    .controlSize(.small)
                    .readBoardInterfaceFont(size: 10)
                    .foregroundStyle(uniform == nil
                        ? ReadBoardDesign.C.text3
                        : ReadBoardDesign.C.text2)
                    .frame(
                        width: SourceRowMetrics.policyControlWidth,
                        alignment: .leading)
                    .help(uniform == nil ? "组内设置不一致，点击后统一" : title)
            } else {
                Color.clear
                    .frame(width: SourceRowMetrics.policyControlWidth, height: 1)
                    .accessibilityHidden(true)
            }
        }
    }

    private var fetchModeMenu: some View {
        Menu {
            Button("自动检测", systemImage: fetchModeSelection?.automatic == true
                ? "checkmark" : "wand.and.stars") {
                Task { await model.setFetchMode(scope: scope, mode: .automatic) }
            }
            if !availableFetchModes.isEmpty { Divider() }
            ForEach(availableFetchModes, id: \.rawValue) { mode in
                Button {
                    Task { await model.setFetchMode(scope: scope, mode: mode) }
                } label: {
                    if fetchModeSelection == SourceFetchModeSelection(
                        automatic: false,
                        mode: mode) {
                        Label(fetchModeName(mode), systemImage: "checkmark")
                    } else {
                        Text(fetchModeName(mode))
                    }
                }
            }
            Divider()
            Button("重新检测", systemImage: "arrow.triangle.2.circlepath") {
                Task { await model.redetectFetchMode(scope: scope) }
            }
            if source == nil, fetchModeSelection == nil {
                Divider()
                Button("按订阅源设置", systemImage: "checkmark") {}
                    .disabled(true)
            }
        } label: {
            controlLabel(fetchModeDisplayName, systemImage: "doc.text")
        }
        .menuStyle(.borderlessButton)
        .readBoardInterfaceFont(size: 10)
        .frame(width: SourceRowMetrics.baseControlWidth)
        .help("全文提取方式")
    }

    @ViewBuilder
    private var intervalControl: some View {
        if let source, let adaptiveName = source.adaptiveFetchDisplayName {
            controlLabel(adaptiveName, systemImage: "clock.badge.checkmark")
                .readBoardInterfaceFont(size: 10)
                .frame(width: SourceRowMetrics.baseControlWidth)
                .help("系统根据历史发布时间、平台风控和每日请求预算安排抓取")
        } else {
            Menu {
                ForEach([5, 15, 30, 60, 360, 720], id: \.self) { minutes in
                    Button {
                        Task { await model.setFetchInterval(scope: scope, minutes: minutes) }
                    } label: {
                        if fetchInterval == minutes {
                            Label(intervalName(minutes), systemImage: "checkmark")
                        } else {
                            Text(intervalName(minutes))
                        }
                    }
                }
                if source == nil, fetchInterval == nil {
                    Divider()
                    Button("按订阅源设置", systemImage: "checkmark") {}
                        .disabled(true)
                }
            } label: {
                controlLabel(fetchInterval.map(intervalName) ?? "按订阅源设置", systemImage: "clock")
            }
            .menuStyle(.borderlessButton)
            .readBoardInterfaceFont(size: 10)
            .frame(width: SourceRowMetrics.baseControlWidth)
            .help("抓取频率")
        }
    }

    private var retentionMenu: some View {
        Menu {
            ForEach([0, 50, 100, 200, 500], id: \.self) { count in
                Button {
                    Task { await model.setMaximumRetainedContent(scope: scope, count: count) }
                } label: {
                    let title = retentionName(count)
                    if maximumRetainedContent == count {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
            if source == nil, maximumRetainedContent == nil {
                Divider()
                Button("按订阅源设置", systemImage: "checkmark") {}
                    .disabled(true)
            }
        } label: {
            controlLabel(
                maximumRetainedContent.map(retentionName) ?? "按订阅源设置",
                systemImage: "tray.full")
        }
        .menuStyle(.borderlessButton)
        .readBoardInterfaceFont(size: 10)
        .frame(width: SourceRowMetrics.baseControlWidth)
        .help("最多保留内容")
    }

    @ViewBuilder
    private var folderControl: some View {
        if let source {
            Menu {
                Button("未分组") {
                    Task { await model.assignSource(sourceID: source.id, folderID: nil) }
                }
                if !folders.isEmpty { Divider() }
                ForEach(folders) { folder in
                    Button {
                        Task { await model.assignSource(sourceID: source.id, folderID: folder.id) }
                    } label: {
                        if source.folderID == folder.id {
                            Label(folder.name, systemImage: "checkmark")
                        } else {
                            Text(folder.name)
                        }
                    }
                }
            } label: {
                controlLabel(folderName(for: source), systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .readBoardInterfaceFont(size: 10)
            .frame(width: SourceRowMetrics.baseControlWidth)
            .help("移动到文件夹")
        } else {
            controlLabel(folderPlaceholder ?? "当前文件夹", systemImage: "folder.fill")
                .readBoardInterfaceFont(size: 10)
                .foregroundStyle(ReadBoardDesign.C.text3)
                .frame(width: SourceRowMetrics.baseControlWidth)
                .help("当前文件夹")
        }
    }

    private func controlLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(
                width: SourceRowMetrics.baseControlWidth,
                alignment: .leading)
    }

    private var supportsTranscription: Bool {
        sources.contains(where: \.transcribable)
    }

    private func uniformPolicy(_ key: SourcePolicyKey) -> Bool? {
        let values = sources.map { $0.policy.value(for: key) }
        guard let first = values.first else { return false }
        return values.allSatisfy { $0 == first } ? first : nil
    }

    private var fetchModeSelection: SourceFetchModeSelection? {
        let values = sources.map {
            SourceFetchModeSelection(automatic: $0.fetchModeAutomatic, mode: $0.fetchMode)
        }
        guard let first = values.first else { return nil }
        return values.allSatisfy { $0 == first } ? first : nil
    }

    private var fetchModeDisplayName: String {
        guard let selection = fetchModeSelection else { return "按订阅源设置" }
        if let source, let displayName = source.fulltextDisplayName {
            return displayName
        }
        return selection.automatic
            ? "自动（\(fetchModeName(selection.mode))）"
            : fetchModeName(selection.mode)
    }

    private var availableFetchModes: [SourceFetchMode] {
        if let source { return source.availableFetchModes }
        return [.feedFull, .defuddle, .summary]
    }

    private var fetchInterval: Int? {
        uniformValue(sources.map(\.fetchIntervalMinutes))
    }

    private var maximumRetainedContent: Int? {
        uniformValue(sources.map(\.maximumRetainedContent))
    }

    private func uniformValue<T: Equatable>(_ values: [T]) -> T? {
        guard let first = values.first else { return nil }
        return values.allSatisfy { $0 == first } ? first : nil
    }

    private func folderName(for source: SourceCatalogItem) -> String {
        folders.first(where: { $0.id == source.folderID })?.name ?? "未分组"
    }

    private func fetchModeName(_ mode: SourceFetchMode) -> String {
        switch mode {
        case .automatic: "自动"
        case .feedFull: "Feed 全文"
        case .defuddle: "网页正文"
        case .youtubeSubtitle: "YouTube 字幕"
        case .bilibiliSubtitle: "Bilibili 字幕"
        case .externalFulltext: "外部全文"
        case .summary: "摘要"
        }
    }

    private func intervalName(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时"
    }

    private func retentionName(_ count: Int) -> String {
        count == 0 ? "不限制" : "\(count) 条"
    }
}

private extension View {
    @ViewBuilder
    func readBoardPolicyToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(.switch)
        #endif
    }
}

private extension SourcePolicySnapshot {
    func value(for key: SourcePolicyKey) -> Bool {
        switch key {
        case .score: autoScore
        case .translate: autoTranslate
        case .summarize: autoSummarize
        case .transcribe: autoTranscribe
        }
    }
}
