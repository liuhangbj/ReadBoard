import ReadBoardContract
import ReadBoardUI
import SwiftUI

private let sourcePolicyDefinitions: [(SourcePolicyKey, String)] = [
    (.score, "AI 评分"),
    (.translate, "翻译"),
    (.summarize, "摘要"),
    (.transcribe, "转录"),
]

struct ReadBoardSourceFolderHeader: View {
    let folder: SourceFolderItem
    let sources: [SourceCatalogItem]
    let model: ReadBoardSourcesFeatureModel

    @State private var showRename = false
    @State private var renameName = ""
    @State private var showDelete = false
    @State private var pendingPolicy: SourcePolicyKey?

    private var scope: SourceScope { SourceScope(kind: .folder, id: folder.id) }

    var body: some View {
        HStack(spacing: ReadBoardDesign.Space.sm) {
            Image(systemName: "folder.fill")
                .foregroundStyle(ReadBoardDesign.C.text3)
            Text(folder.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ReadBoardDesign.C.text)
                .textCase(nil)
            Text("\(sources.count)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(ReadBoardDesign.C.text3)
            Spacer()
            ForEach(sourcePolicyDefinitions, id: \.0.rawValue) { key, title in
                if key != .transcribe || sources.contains(where: \.transcribable) {
                    policyToggle(title, key: key)
                }
            }
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
            .frame(width: 24)
        }
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

    private func policyToggle(_ title: String, key: SourcePolicyKey) -> some View {
        let uniform = uniformPolicy(key)
        return Toggle(title, isOn: Binding(
            get: { uniform ?? false },
            set: { enabled in
                if enabled { pendingPolicy = key }
                else { Task { await model.setPolicy(scope: scope, key: key, enabled: false) } }
            }))
            .readBoardPolicyToggleStyle()
            .controlSize(.small)
            .font(.system(size: 10))
            .foregroundStyle(uniform == nil ? ReadBoardDesign.C.text3 : ReadBoardDesign.C.text2)
            .help(uniform == nil ? "组内设置不一致，点击后统一" : title)
    }

    private func uniformPolicy(_ key: SourcePolicyKey) -> Bool? {
        let values = sources.map { $0.policy.value(for: key) }
        guard let first = values.first else { return false }
        return values.allSatisfy { $0 == first } ? first : nil
    }
}

struct ReadBoardSourceFeatureRow: View {
    let source: SourceCatalogItem
    let folders: [SourceFolderItem]
    let model: ReadBoardSourcesFeatureModel

    @State private var showRename = false
    @State private var renameName = ""
    @State private var showDelete = false
    @State private var pendingPolicy: SourcePolicyKey?

    private var scope: SourceScope { SourceScope(kind: .source, id: source.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: ReadBoardDesign.Space.md) {
                Image(systemName: sourceIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(sourceColor)
                    .frame(width: 25, height: 25)
                    .background(sourceColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(source.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(source.enabled
                                ? ReadBoardDesign.C.text
                                : ReadBoardDesign.C.text3)
                            .lineLimit(1)
                        ReadBoardBadge(text: statusText, color: statusColor)
                        Text("\(source.contentCount) 项")
                            .font(.system(size: 10).monospacedDigit())
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

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { configurationControls }
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) { fetchModeMenu; intervalMenu; retentionMenu; folderMenu }
                    HStack(spacing: 7) { policyControls }
                }
            }
            .padding(.leading, 37)

            if let error = source.error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(ReadBoardDesign.C.scoreLow)
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

    @ViewBuilder
    private var configurationControls: some View {
        fetchModeMenu
        intervalMenu
        retentionMenu
        folderMenu
        policyControls
    }

    @ViewBuilder
    private var policyControls: some View {
        ForEach(sourcePolicyDefinitions, id: \.0.rawValue) { key, title in
            if key != .transcribe || source.transcribable {
                Toggle(title, isOn: Binding(
                    get: { source.policy.value(for: key) },
                    set: { enabled in
                        if enabled { pendingPolicy = key }
                        else { Task { await model.setPolicy(
                            scope: scope,
                            key: key,
                            enabled: false) } }
                    }))
                    .readBoardPolicyToggleStyle()
                    .controlSize(.small)
                    .font(.system(size: 10))
            }
        }
    }

    private var fetchModeMenu: some View {
        Menu {
            Button("自动检测", systemImage: source.fetchModeAutomatic ? "checkmark" : "wand.and.stars") {
                Task { await model.setFetchMode(scope: scope, mode: .automatic) }
            }
            if !source.availableFetchModes.isEmpty { Divider() }
            ForEach(source.availableFetchModes, id: \.rawValue) { mode in
                Button {
                    Task { await model.setFetchMode(scope: scope, mode: mode) }
                } label: {
                    if !source.fetchModeAutomatic, source.fetchMode == mode {
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
        } label: {
            Label(source.fulltextDisplayName ?? fetchModeName(source.fetchMode), systemImage: "doc.text")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .font(.system(size: 10))
        .fixedSize()
        .help("全文提取方式")
    }

    private var intervalMenu: some View {
        Menu {
            ForEach([5, 15, 30, 60, 360, 720], id: \.self) { minutes in
                Button {
                    Task { await model.setFetchInterval(scope: scope, minutes: minutes) }
                } label: {
                    if source.fetchIntervalMinutes == minutes {
                        Label(intervalName(minutes), systemImage: "checkmark")
                    } else {
                        Text(intervalName(minutes))
                    }
                }
            }
        } label: {
            Label(intervalName(source.fetchIntervalMinutes), systemImage: "clock")
        }
        .menuStyle(.borderlessButton)
        .font(.system(size: 10))
        .fixedSize()
        .help("抓取频率")
    }

    private var retentionMenu: some View {
        Menu {
            ForEach([0, 50, 100, 200, 500], id: \.self) { count in
                Button {
                    Task { await model.setMaximumRetainedContent(
                        sourceID: source.id,
                        count: count) }
                } label: {
                    let title = count == 0 ? "不限制" : "\(count) 条"
                    if source.maximumRetainedContent == count {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Label(source.maximumRetainedContent == 0
                ? "不限制"
                : "\(source.maximumRetainedContent) 条", systemImage: "tray.full")
        }
        .menuStyle(.borderlessButton)
        .font(.system(size: 10))
        .fixedSize()
        .help("最多保留内容")
    }

    private var folderMenu: some View {
        Menu {
            Button("未分组") {
                Task { await model.assignSource(sourceID: source.id, folderID: nil) }
            }
            if !folders.isEmpty { Divider() }
            ForEach(folders) { folder in
                Button {
                    Task { await model.assignSource(sourceID: source.id, folderID: folder.id) }
                } label: {
                    if source.folderID == folder.id { Label(folder.name, systemImage: "checkmark") }
                    else { Text(folder.name) }
                }
            }
        } label: {
            Label(folderName, systemImage: "folder")
        }
        .menuStyle(.borderlessButton)
        .font(.system(size: 10))
        .fixedSize()
        .help("移动到文件夹")
    }

    private var actionMenu: some View {
        Menu {
            sourceContextMenu
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
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

    private var folderName: String {
        folders.first(where: { $0.id == source.folderID })?.name ?? "未分组"
    }

    private var statusText: String {
        if !source.enabled { return "已停用" }
        if source.hasError { return "异常" }
        if source.isStale { return "待更新" }
        return "正常"
    }

    private var statusColor: Color {
        if !source.enabled { return ReadBoardDesign.C.text3 }
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
