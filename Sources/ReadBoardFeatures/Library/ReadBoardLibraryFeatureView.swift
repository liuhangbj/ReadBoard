import ReadBoardContract
import ReadBoardUI
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 资料库列表与阅读区的完整共享页面。产品壳只提供环境和暂存期详情插槽。
public struct ReadBoardLibraryFeatureView<Detail: View>: View {
    @State private var model: ReadBoardLibraryFeatureModel
    @State private var showShortcutHelp = false
    @FocusState private var searchFocused: Bool
    @AppStorage("reading.uiFontScale") private var uiFontScale: Double = 1
    @AppStorage("list.density") private var listDensity = "comfortable"
    @AppStorage("list.showSource") private var listShowSource = true
    @AppStorage("list.showDate") private var listShowDate = true
    @AppStorage("list.unreadBold") private var listUnreadBold = true
    @AppStorage("list.dateFormat") private var listDateFormat = "absolute"
    @AppStorage("list.excerptLines") private var listExcerptLines = 0

    private let automaticallyMarksRead: Bool
    private let loadsDetail: Bool
    private let playbackNavigationRequest: ReadBoardPlaybackNavigationRequest?
    private let detail: (
        ContentSummary,
        ReadBoardLibraryFeatureModel,
        @escaping (Bool, Bool) -> Void
    ) -> Detail

    public init(
        environment: ReadBoardFeatureEnvironment,
        location: ReadBoardLibraryLocation = .collection(.all),
        automaticallyMarksRead: Bool = true,
        loadsDetail: Bool = true,
        playbackNavigationRequest: ReadBoardPlaybackNavigationRequest? = nil,
        @ViewBuilder detail: @escaping (
            ContentSummary,
            ReadBoardLibraryFeatureModel,
            @escaping (Bool, Bool) -> Void
        ) -> Detail
    ) {
        _model = State(initialValue: ReadBoardLibraryFeatureModel(
            environment: environment, location: location))
        self.automaticallyMarksRead = automaticallyMarksRead
        self.loadsDetail = loadsDetail
        self.playbackNavigationRequest = playbackNavigationRequest
        self.detail = detail
    }

    public var body: some View {
        Group {
        #if os(macOS)
        desktopBody
        #else
        mobileBody
        #endif
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .readBoardLibrarySnapshotChanged)) { _ in
                Task {
                    await model.reload()
                    await model.refreshNavigation()
                }
            }
        .task(id: playbackNavigationRequest?.id) {
            guard let request = playbackNavigationRequest else { return }
            await model.open(
                request.summary,
                automaticallyMarksRead: automaticallyMarksRead,
                loadsDetail: loadsDetail)
        }
    }

    #if os(macOS)
    private var desktopBody: some View {
        ReadBoardLibraryDesktopColumns {
            VStack(spacing: 0) {
                listHeader
                ReadBoardHairline()
                feedContent
            }
        } detail: {
            if let selectedItem = model.selectedItem {
                detail(selectedItem, model) { isRead, isStarred in
                    model.acceptAuthoritativeState(
                        contentID: selectedItem.id,
                        isRead: isRead,
                        isStarred: isStarred)
                }
                .id(selectedItem.id)
            } else {
                ReadBoardReaderPlaceholder(count: model.navigationSnapshot?.counts.total)
            }
        }
        .task(id: model.identity) { await model.searchAndReload() }
        .task { await model.refreshNavigation() }
        .background(shortcutHandlers)
        .sheet(isPresented: $showShortcutHelp) { ReadBoardShortcutHelpView() }
        .alert("操作失败", isPresented: operationErrorPresented) {
            Button("好", role: .cancel) { model.clearOperationError() }
        } message: {
            Text(model.operationErrorMessage ?? "请稍后重试")
        }
        // 阅读器内的处理状态由详情页放在操作按钮右侧；未选择文章时才使用
        // 资料库级提示，避免“全文提取完成”落到长文章最底部。
        .overlay(alignment: .topTrailing) {
            if model.selectedItem == nil { operationToast }
        }
    }
    #endif

    #if os(macOS)
    private var shortcutHandlers: some View {
        Group {
            Button("") {
                guard !searchFocused else { return }
                Task { await model.selectAdjacent(offset: 1) }
            }
            .keyboardShortcut("j", modifiers: [])
            Button("") {
                guard !searchFocused else { return }
                Task { await model.selectAdjacent(offset: -1) }
            }
            .keyboardShortcut("k", modifiers: [])
            Button("") {
                guard let item = model.selectedItem else { return }
                Task { await model.setStarred(!item.isStarred, contentID: item.id) }
            }
            .keyboardShortcut("s", modifiers: [])
            Button("") {
                guard let item = model.selectedItem else { return }
                Task { await model.setRead(!item.isRead, contentID: item.id) }
            }
            .keyboardShortcut(.space, modifiers: [])
            Button("", action: openSelectedOriginal)
                .keyboardShortcut("v", modifiers: [])
            Button("") { Task { await model.markCurrentLocationRead() } }
                .keyboardShortcut("e", modifiers: [])
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: [])
            Button("") { showShortcutHelp = true }
                .keyboardShortcut("?", modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    private func openSelectedOriginal() {
        guard let value = model.selectedItem?.url,
              let url = URL(string: value), !value.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }
    #endif

    #if os(iOS)
    private var mobileBody: some View {
        feedContent
            .background(ReadBoardDesign.C.bg)
            .navigationTitle(model.location.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: searchBinding, prompt: "搜索标题、摘要和正文")
            .toolbar { mobileToolbar }
            .task(id: model.identity) { await model.searchAndReload() }
            .alert("操作失败", isPresented: operationErrorPresented) {
                Button("好", role: .cancel) { model.clearOperationError() }
            } message: {
                Text(model.operationErrorMessage ?? "请稍后重试")
            }
            .overlay(alignment: .bottom) { operationToast }
    }
    #endif

    #if os(macOS)
    private var listHeader: some View {
        VStack(spacing: 0) {
            ReadBoardLibrarySearchField(
                text: searchBinding,
                isFocused: $searchFocused,
                placeholder: "搜索标题 / 正文")
                .padding(.horizontal, 12)
                .padding(.top, 10)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    scoreFilterControls
                    Spacer(minLength: 8)
                    readAndSortControls
                }
                VStack(alignment: .leading, spacing: 6) {
                    scoreFilterControls
                    HStack(spacing: 8) {
                        readAndSortControls
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ReadBoardFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                Text("处理")
                    .readBoardInterfaceFont(size: 11)
                    .foregroundStyle(ReadBoardDesign.C.text3)
                processingFilterChip(.fulltext)
                processingFilterChip(.score)
                processingFilterChip(.summary)
                processingFilterChip(.translate)
                processingFilterChip(.transcribe)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ReadBoardHairline()

            HStack {
                ReadBoardSectionLabel(text: "\(model.items.count) 条")
                Spacer()
                Button { Task { await model.markCurrentLocationRead() } } label: {
                    Label("全部已读", systemImage: "checkmark.circle")
                        .readBoardInterfaceFont(size: 11)
                }
                .buttonStyle(ReadBoardQuietButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
    }

    private var scoreFilterControls: some View {
        HStack(spacing: 5) {
            Text("评分")
                .readBoardInterfaceFont(size: 11)
                .foregroundStyle(ReadBoardDesign.C.text3)
            scoreField(placeholder: "0", value: minimumScoreBinding)
            Text("–")
                .readBoardInterfaceFont(size: 11)
                .foregroundStyle(ReadBoardDesign.C.text3)
            scoreField(placeholder: "100", value: maximumScoreBinding)
            if model.queryState.minimumScore > 0 || model.queryState.maximumScore < 100 {
                filterChip(
                    label: "含未评分",
                    match: model.queryState.includeUnscored ? .complete : nil
                ) {
                    model.queryState.includeUnscored.toggle()
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func scoreField(placeholder: String, value: Binding<Int>) -> some View {
        TextField(placeholder, value: value, format: .number)
            .textFieldStyle(.plain)
            .readBoardInterfaceFont(size: 11)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(width: 30)
            .padding(.horizontal, 6)
            .padding(.vertical, 3.5)
            .background {
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md)
                    .fill(ReadBoardDesign.C.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md)
                    .strokeBorder(ReadBoardDesign.C.hairline, lineWidth: 0.5)
            }
    }

    private var readAndSortControls: some View {
        HStack(spacing: 8) {
            ReadBoardArticleModePicker(
                items: ReadBoardLibraryReadFilter.allCases.map { ($0, $0.compactTitle) },
                selection: readFilterBinding,
                fontSize: 11)

            Menu {
                Picker("排序", selection: sortBinding) {
                    ForEach(ReadBoardLibrarySortOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .readBoardInterfaceFont(size: 9)
                        .foregroundStyle(ReadBoardDesign.C.text3)
                    Text(model.queryState.sortOption.compactTitle)
                        .readBoardInterfaceFont(size: 11)
                    Image(systemName: "chevron.down")
                        .readBoardInterfaceFont(size: 7, weight: .bold)
                        .foregroundStyle(ReadBoardDesign.C.text3)
                }
                .foregroundStyle(ReadBoardDesign.C.text2)
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(ReadBoardDesign.C.surface))
                .overlay {
                    Capsule().strokeBorder(ReadBoardDesign.C.hairline, lineWidth: 0.5)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func processingFilterChip(_ kind: ProcessingKind) -> some View {
        let match = model.queryState.processing[kind]
        return filterChip(label: processingTitle(kind), match: match) {
            switch match {
            case nil:
                model.queryState.processing[kind] = .complete
            case .complete:
                model.queryState.processing[kind] = .incomplete
            case .incomplete:
                model.queryState.processing.removeValue(forKey: kind)
            }
        }
    }

    private func filterChip(
        label: String,
        match: ProcessingMatch?,
        action: @escaping () -> Void
    ) -> some View {
        let background: Color
        let foreground: Color
        let border: Color
        switch match {
        case .complete:
            background = ReadBoardDesign.C.accent.opacity(0.14)
            foreground = ReadBoardDesign.C.accent
            border = ReadBoardDesign.C.accent.opacity(0.35)
        case .incomplete:
            background = ReadBoardDesign.C.scoreLow.opacity(0.16)
            foreground = ReadBoardDesign.C.scoreLow
            border = ReadBoardDesign.C.scoreLow.opacity(0.40)
        case nil:
            background = ReadBoardDesign.C.surface
            foreground = ReadBoardDesign.C.text2
            border = ReadBoardDesign.C.hairline
        }
        return Button(action: action) {
            Text(label)
                .readBoardInterfaceFont(size: 11)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(background)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md))
                .overlay {
                    RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md)
                        .strokeBorder(border, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }
    #endif

    @ViewBuilder
    private var feedContent: some View {
        if model.pagination.isInitialLoading && model.items.isEmpty {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { _ in
                        ReadBoardLibraryRowPlaceholder()
                        ReadBoardHairline().padding(.leading, 28)
                    }
                }
            }
        } else if let error = model.pagination.errorMessage, model.items.isEmpty {
            ReadBoardLibraryEmptyState(
                title: "无法加载内容",
                message: error,
                icon: "wifi.exclamationmark",
                actionTitle: "重试"
            ) { Task { await model.reload() } }
        } else if model.items.isEmpty {
            let empty = model.queryState.emptyPresentation
            ReadBoardLibraryEmptyState(
                title: empty.title, message: empty.message, icon: empty.systemImage)
        } else {
            #if os(macOS)
            desktopFeed
            #else
            mobileFeed
            #endif
        }
    }

    #if os(macOS)
    private var desktopFeed: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let error = model.pagination.errorMessage {
                    retryBanner(error)
                }
                ForEach(model.items) { item in
                    Button { Task { await model.open(
                        item,
                        automaticallyMarksRead: automaticallyMarksRead,
                        loadsDetail: loadsDetail) } } label: {
                        ReadBoardLibraryRow(
                            item: item,
                            isSelected: model.selection.isSelected(item.id),
                            style: rowStyle)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { rowContextMenu(item) }
                    ReadBoardHairline().padding(.leading, 28)
                }
                loadMoreRow
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    private func retryBanner(_ message: String) -> some View {
        Button { Task { await model.reload() } } label: {
            HStack(spacing: ReadBoardDesign.Space.sm) {
                Image(systemName: "arrow.clockwise.circle")
                Text(message).lineLimit(2)
                Spacer()
            }
            .readBoardInterfaceFont(size: 11)
            .foregroundStyle(ReadBoardDesign.C.scoreMid)
            .padding(ReadBoardDesign.Space.md)
        }
        .buttonStyle(.plain)
    }
    #endif

    #if os(iOS)
    private var mobileFeed: some View {
        List {
            if let error = model.pagination.errorMessage {
                Button { Task { await model.reload() } } label: {
                    Label(error, systemImage: "arrow.clockwise.circle")
                        .font(.caption)
                        .foregroundStyle(ReadBoardDesign.C.scoreMid)
                }
            }
            ForEach(model.items) { item in
                NavigationLink {
                    detail(item, model) { isRead, isStarred in
                        model.acceptAuthoritativeState(
                            contentID: item.id, isRead: isRead, isStarred: isStarred)
                    }
                    .task { await model.open(
                        item,
                        automaticallyMarksRead: automaticallyMarksRead,
                        loadsDetail: loadsDetail) }
                } label: {
                    ReadBoardLibraryRow(item: item, style: rowStyle)
                }
                .listRowInsets(.init(top: 0, leading: 4, bottom: 0, trailing: 10))
                .listRowBackground(ReadBoardDesign.C.bg)
            }
            loadMoreRow
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.reload() }
    }
    #endif

    @ViewBuilder
    private var loadMoreRow: some View {
        if model.pagination.hasMore {
            ReadBoardLibraryPaginationFooter(isLoading: model.pagination.isLoadingMore)
                .task { await model.loadMore() }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("阅读状态", selection: readFilterBinding) {
                ForEach(ReadBoardLibraryReadFilter.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            Picker("内容类型", selection: categoryFilterBinding) {
                ForEach(ReadBoardLibraryCategoryFilter.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            Divider()
            scoreFilterMenu
            processingFilterMenu
        } label: {
            Label("筛选", systemImage: model.queryState.hasActiveFilter
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .buttonStyle(ReadBoardSecondaryButtonStyle())
    }

    private var scoreFilterMenu: some View {
        Menu("评分") {
            Picker("最低评分", selection: minimumScoreBinding) {
                Text("不限").tag(0)
                ForEach([40, 50, 60, 70, 75, 80, 85, 90], id: \.self) { value in
                    Text("\(value) 分及以上").tag(value)
                }
            }
            Picker("最高评分", selection: maximumScoreBinding) {
                Text("不限").tag(100)
                ForEach([90, 80, 75, 70, 60, 50, 40], id: \.self) { value in
                    Text("\(value) 分及以下").tag(value)
                }
            }
            if model.queryState.minimumScore > 0 || model.queryState.maximumScore < 100 {
                Toggle("包含未评分", isOn: includeUnscoredBinding)
            }
        }
    }

    private var processingFilterMenu: some View {
        Menu("处理状态") {
            ForEach(ProcessingKind.allCases, id: \.rawValue) { kind in
                Picker(processingTitle(kind), selection: processingBinding(kind)) {
                    Text("不限").tag(Optional<ProcessingMatch>.none)
                    Text("已完成").tag(Optional(ProcessingMatch.complete))
                    Text("未完成").tag(Optional(ProcessingMatch.incomplete))
                }
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: sortBinding) {
                ForEach(ReadBoardLibrarySortOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            Label(model.queryState.sortOption.title, systemImage: "arrow.up.arrow.down")
        }
        .buttonStyle(ReadBoardSecondaryButtonStyle())
    }

    private var listAppearanceMenu: some View {
        Menu {
            Picker("列表密度", selection: $listDensity) {
                Text("舒适").tag("comfortable")
                Text("紧凑").tag("compact")
            }
            Picker("摘要行数", selection: $listExcerptLines) {
                Text("不显示").tag(0)
                Text("1 行").tag(1)
                Text("2 行").tag(2)
                Text("3 行").tag(3)
            }
            Toggle("显示来源", isOn: $listShowSource)
            Toggle("显示日期", isOn: $listShowDate)
            Toggle("未读标题加粗", isOn: $listUnreadBold)
            Picker("日期格式", selection: $listDateFormat) {
                Text("绝对日期").tag("absolute")
                Text("相对时间").tag("relative")
            }
        } label: {
            Label("列表", systemImage: "list.bullet")
        }
        .buttonStyle(ReadBoardSecondaryButtonStyle())
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var mobileToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            filterMenu
            sortMenu
            listAppearanceMenu
        }
    }
    #endif

    private var searchBinding: Binding<String> {
        Binding(
            get: { model.queryState.searchText },
            set: { model.queryState.searchText = $0 })
    }

    private var readFilterBinding: Binding<ReadBoardLibraryReadFilter> {
        Binding(
            get: { model.queryState.readFilter },
            set: { model.queryState.readFilter = $0 })
    }

    private var categoryFilterBinding: Binding<ReadBoardLibraryCategoryFilter> {
        Binding(
            get: { model.queryState.categoryFilter },
            set: { model.queryState.categoryFilter = $0 })
    }

    private var sortBinding: Binding<ReadBoardLibrarySortOption> {
        Binding(
            get: { model.queryState.sortOption },
            set: { model.queryState.sortOption = $0 })
    }

    private var minimumScoreBinding: Binding<Int> {
        Binding(
            get: { model.queryState.minimumScore },
            set: { model.queryState.minimumScore = min($0, model.queryState.maximumScore) })
    }

    private var maximumScoreBinding: Binding<Int> {
        Binding(
            get: { model.queryState.maximumScore },
            set: { model.queryState.maximumScore = max($0, model.queryState.minimumScore) })
    }

    private var includeUnscoredBinding: Binding<Bool> {
        Binding(
            get: { model.queryState.includeUnscored },
            set: { model.queryState.includeUnscored = $0 })
    }

    private func processingBinding(_ kind: ProcessingKind) -> Binding<ProcessingMatch?> {
        Binding(
            get: { model.queryState.processing[kind] },
            set: { value in
                if let value { model.queryState.processing[kind] = value }
                else { model.queryState.processing.removeValue(forKey: kind) }
            })
    }

    private func processingTitle(_ kind: ProcessingKind) -> String {
        switch kind {
        case .fulltext: "全文提取"
        case .score: "AI 评分"
        case .summary: "AI 摘要"
        case .translate: "AI 翻译"
        case .transcribe: "AI 转录"
        }
    }

    private var rowStyle: ReadBoardLibraryRowStyle {
        ReadBoardLibraryRowStyle(
            scale: uiFontScale,
            density: listDensity == "compact" ? .compact : .comfortable,
            showSource: listShowSource,
            showDate: listShowDate,
            unreadBold: listUnreadBold,
            dateStyle: listDateFormat == "relative" ? .relative : .absolute,
            excerptLines: listExcerptLines)
    }

    private var operationErrorPresented: Binding<Bool> {
        Binding(
            get: { model.operationErrorMessage != nil },
            set: { if !$0 { model.clearOperationError() } })
    }

    @ViewBuilder
    private func rowContextMenu(_ item: ContentSummary) -> some View {
        Button {
            Task { await model.setRead(!item.isRead, contentID: item.id) }
        } label: {
            Label(item.isRead ? "标为未读" : "标为已读",
                  systemImage: item.isRead ? "envelope.badge" : "envelope.open")
        }
        Button {
            Task { await model.setStarred(!item.isStarred, contentID: item.id) }
        } label: {
            Label(item.isStarred ? "取消星标" : "加星标",
                  systemImage: item.isStarred ? "star.slash" : "star")
        }

        Divider()
        Button { copyLink(item.url) } label: {
            Label("复制链接", systemImage: "link")
        }
        if let url = URL(string: item.url) {
            Link(destination: url) { Label("浏览器打开原文", systemImage: "safari") }
        }

        if model.permissions.allows(.runProcessing, capability: .processing) {
            Divider()
            Menu("内容处理", systemImage: "gearshape.2") {
                processingButton("重新处理", icon: "arrow.triangle.2.circlepath", operation: .allEnabled, item: item)
                Divider()
                processingButton("AI 评分", icon: "number", operation: .score, item: item)
                processingButton("AI 摘要", icon: "text.quote", operation: .summarize, item: item)
                processingButton("AI 翻译", icon: "character.bubble", operation: .translate, item: item)
                if item.isMedia {
                    processingButton("AI 转录", icon: "waveform", operation: .transcribe, item: item)
                }
                if item.hasTranscript {
                    Divider()
                    processingButton("删除转录稿", icon: "trash", operation: .deleteTranscript, item: item)
                }
            }
            processingButton(
                "重新提取全文",
                icon: "doc.text.magnifyingglass",
                operation: .fulltext,
                item: item)
        }

        if model.permissions.allows(.manageExports, capability: .export) {
            Button {
                Task { await model.forceExport(contentID: item.id) }
            } label: {
                Label("触发导出规则", systemImage: "square.and.arrow.up.on.square")
            }
        }
    }

    private func processingButton(
        _ title: String,
        icon: String,
        operation: ProcessingOperation,
        item: ContentSummary
    ) -> some View {
        Button {
            Task { await model.submitProcessing(operation, contentID: item.id) }
        } label: {
            Label(title, systemImage: icon)
        }
    }

    @ViewBuilder
    private var operationToast: some View {
        if let message = model.operationStatusMessage, !message.isEmpty {
            HStack(spacing: ReadBoardDesign.Space.sm) {
                Image(systemName: "checkmark.circle")
                Text(message).lineLimit(2)
                Button { model.clearOperationStatus() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .readBoardInterfaceFont(size: 11)
            .foregroundStyle(ReadBoardDesign.C.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .padding(.bottom, 16)
        }
    }

    private func copyLink(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #else
        UIPasteboard.general.string = value
        #endif
    }
}

public extension ReadBoardLibraryFeatureView where Detail == ReadBoardArticleDetailFeatureView {
    init(
        environment: ReadBoardFeatureEnvironment,
        location: ReadBoardLibraryLocation = .collection(.all),
        automaticallyMarksRead: Bool = true,
        mediaPlayer: ReadBoardGlobalMediaPlayer? = nil,
        playbackNavigationRequest: ReadBoardPlaybackNavigationRequest? = nil
    ) {
        self.init(
            environment: environment,
            location: location,
            automaticallyMarksRead: automaticallyMarksRead,
            loadsDetail: true,
            playbackNavigationRequest: playbackNavigationRequest
        ) { summary, model, _ in
            ReadBoardArticleDetailFeatureView(
                summary: summary,
                model: model,
                environment: environment,
                mediaPlayer: mediaPlayer)
        }
    }
}
