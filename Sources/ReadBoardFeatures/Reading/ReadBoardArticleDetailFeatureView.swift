import Foundation
import ReadBoardContract
import ReadBoardUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct ReadBoardArticleDetailFeatureView: View {
    public let summary: ContentSummary
    public let model: ReadBoardLibraryFeatureModel
    private let environment: ReadBoardFeatureEnvironment
    private let globalMediaPlayer: ReadBoardGlobalMediaPlayer?

    @Environment(\.colorScheme) private var colorScheme
    @State private var showReadingSettings = false
    @State private var showShareSheet = false
    @AppStorage("reading.viewMode") private var articleViewMode = 0
    @AppStorage("reading.mediaTab") private var mediaTab = 0
    @AppStorage("reading.theme") private var themeRaw = ReadBoardReadingTheme.claude.rawValue
    @AppStorage("reading.themeMode") private var themeModeRaw = ReadBoardReadingColorMode.system.rawValue
    @AppStorage("reading.font") private var fontRaw = "system"
    @AppStorage("reading.interfaceFont") private var interfaceFontRaw = "system"
    @AppStorage("reading.fontSize") private var readingFontSize: Double = 16
    @AppStorage("reading.titleFontSize") private var titleFontSize: Double = 24
    @AppStorage("reading.metaFontSize") private var metaFontSize: Double = 12
    @AppStorage("reading.summaryFontSize") private var summaryFontSize: Double = 14
    @AppStorage("reading.lineSpacing") private var readingLineSpacing: Double = 6
    @AppStorage("reading.contentWidth") private var readingContentWidth: Double = 720
    @AppStorage("reading.uiFontScale") private var uiFontScale: Double = 1

    public init(
        summary: ContentSummary,
        model: ReadBoardLibraryFeatureModel,
        environment: ReadBoardFeatureEnvironment,
        mediaPlayer: ReadBoardGlobalMediaPlayer? = nil
    ) {
        self.summary = summary
        self.model = model
        self.environment = environment
        self.globalMediaPlayer = mediaPlayer
    }

    private var currentSummary: ContentSummary {
        guard let value = model.selectedItem, value.id == summary.id else { return summary }
        return value
    }

    private var currentDetail: ContentDetail? {
        guard model.selection.selectedID == summary.id else { return nil }
        return model.selectedDetail
    }

    private var document: ReadBoardArticleDocument {
        ReadBoardArticleDocument(summary: currentSummary, detail: currentDetail)
    }

    public var body: some View {
        VStack(spacing: 0) {
            actionBar
            ReadBoardHairline()
            GeometryReader { geometry in
                let readingColumnWidth = Self.resolvedContentWidth(
                    availableWidth: geometry.size.width,
                    preferredWidth: readingContentWidth,
                    horizontalPadding: ReadBoardDesign.Space.xl)

                VStack(spacing: 0) {
                    if playbackItem != nil {
                        mediaPlayer
                            .frame(width: readingColumnWidth)
                            .padding(.vertical, ReadBoardDesign.Space.md)
                            .frame(width: geometry.size.width, alignment: .center)
                        ReadBoardHairline()
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: ReadBoardDesign.Space.xl) {
                            articleHeader
                            processingActions
                            detailContent
                        }
                        .frame(
                            width: readingColumnWidth,
                            alignment: .leading)
                        .padding(.vertical, ReadBoardDesign.Space.xl)
                        // ScrollView 对窄内容的默认横向定位在 macOS 上并不稳定。
                        // 显式占满可用宽度，确保正文列始终在阅读栏正中。
                        .frame(width: geometry.size.width, alignment: .center)
                    }
                }
            }
        }
        // NavigationSplitView 会按子视图固有宽度摆放详情。阅读根视图必须先占满
        // 整个右栏，内部 GeometryReader 才能拿到真实可用宽度并正确居中正文。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(readingPalette.background)
        #if os(iOS)
        .navigationTitle(currentSummary.sourceName ?? currentSummary.source)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showShareSheet) {
            ReadBoardArticleShareView(
                item: currentSummary,
                canExport: environment.permissions.allows(
                .manageExports, capability: .export),
                onExport: { await model.forceExport(contentID: currentSummary.id) })
        }
        .task(id: playbackItem?.id) {
            guard let item = playbackItem, let globalMediaPlayer else { return }
            globalMediaPlayer.prepare(item)
        }
        .onDisappear {
            guard let itemID = playbackItem?.id else { return }
            globalMediaPlayer?.discardPrepared(itemID: itemID)
        }
    }

    private var actionBar: some View {
        ReadBoardArticleActionBar(
            isRead: readBinding,
            isStarred: starredBinding,
            selectedMode: selectedModeBinding,
            showsSettings: $showReadingSettings,
            availableModes: document.availableModes,
            canUpdateReadingState: environment.permissions.allows(
                .updateReadingState, capability: .library),
            originalURL: nil,
            shareAction: { showShareSheet = true },
            previousAction: { Task { await model.selectAdjacent(offset: -1) } },
            nextAction: { Task { await model.selectAdjacent(offset: 1) } },
            canGoPrevious: model.canSelectAdjacent(offset: -1),
            canGoNext: model.canSelectAdjacent(offset: 1),
            onToggleRead: { Task { await model.setRead(!currentSummary.isRead) } },
            onToggleStarred: { Task { await model.setStarred(!currentSummary.isStarred) } }
        ) {
            ReadBoardReadingSettingsView()
        }
    }

    @ViewBuilder
    private var processingActions: some View {
        if environment.permissions.allows(.runProcessing, capability: .processing) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    processingButton("提取全文", icon: "doc.text.magnifyingglass", .fulltext)
                    processingButton("内容处理", icon: "sparkles", .allEnabled)
                    processingButton("AI 评分", icon: "number", .score)
                    processingButton("AI 摘要", icon: "text.quote", .summarize)
                    processingButton("AI 翻译", icon: "character.bubble", .translate)
                    if isMediaDocument {
                        processingButton("AI 转录", icon: "waveform", .transcribe)
                    }
                    if let message = model.operationStatusMessage, !message.isEmpty {
                        Divider().frame(height: 18)
                        Image(systemName: message.contains("失败")
                            ? "exclamationmark.circle"
                            : "checkmark.circle")
                            .foregroundStyle(message.contains("失败")
                                ? ReadBoardDesign.C.scoreLow
                                : ReadBoardDesign.C.scoreHigh)
                        Text(message)
                            .readBoardInterfaceFont(size: 11)
                            .foregroundStyle(ReadBoardDesign.C.text2)
                            .lineLimit(1)
                        Button { model.clearOperationStatus() } label: {
                            Image(systemName: "xmark")
                                .readBoardInterfaceFont(size: 9, weight: .semibold)
                        }
                        .buttonStyle(.plain)
                        .help("关闭状态提示")
                    }
                }
            }
        }
    }

    /// 把用户设置的内容宽度约束在阅读栏安全区内。返回精确宽度而不是 maxWidth，
    /// 避免短标题或正文让整个内容列按固有宽度向右漂移。
    nonisolated public static func resolvedContentWidth(
        availableWidth: CGFloat,
        preferredWidth: Double,
        horizontalPadding: CGFloat
    ) -> CGFloat {
        let safeAvailableWidth = max(1, availableWidth - horizontalPadding * 2)
        return min(max(1, CGFloat(preferredWidth)), safeAvailableWidth)
    }

    private func processingButton(
        _ title: String,
        icon: String,
        _ operation: ProcessingOperation
    ) -> some View {
        Button {
            Task { await model.submitProcessing(operation, contentID: currentSummary.id) }
        } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(ReadBoardSecondaryButtonStyle())
    }

    private var articleHeader: some View {
        VStack(alignment: .leading, spacing: ReadBoardDesign.Space.md) {
            ReadBoardArticleHeader(
                translatedTitle: document.translatedTitle,
                metadataParts: document.metadataParts,
                kind: document.kind,
                badges: document.badges,
                translatedTitleFont: interfaceFont(
                    size: titleFontSize * 0.72, weight: .medium),
                translatedTitleColor: readingPalette.textSecondary,
                metadataFont: interfaceFont(size: metaFontSize),
                metadataColor: readingPalette.textFaint
            ) {
                if let originalURL {
                    #if os(macOS)
                    ReadBoardSelectableLinkTitle(
                        text: currentSummary.title,
                        destination: originalURL,
                        font: ReadBoardInterfaceFont.nsFont(
                            rawValue: interfaceFontRaw,
                            size: titleFontSize * uiFontScale,
                            weight: .semibold),
                        normalColor: NSColor(readingPalette.text),
                        hoverColor: NSColor(ReadBoardDesign.C.accent))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("点击在浏览器打开原文；拖动可选择标题")
                    #else
                    Link(destination: originalURL) { articleTitle }
                        .buttonStyle(.plain)
                        .help("点击在浏览器打开原文")
                    #endif
                } else {
                    articleTitle
                }
            }
            if let summaryText = document.summaryText {
                ReadBoardArticleSummaryCard(
                    text: summaryText,
                    font: interfaceFont(size: summaryFontSize),
                    textColor: readingPalette.textSecondary,
                    backgroundColor: readingPalette.markdown.backgroundAlt)
            }
        }
    }

    private var articleTitle: some View {
        Text(currentSummary.title)
            .font(interfaceFont(size: titleFontSize, weight: .semibold))
            .foregroundStyle(readingPalette.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var detailContent: some View {
        if currentDetail != nil {
            let markdown = document.markdown(for: selectedMode)
            if markdown.isEmpty {
                ReadBoardArticleEmptyState(
                    title: "暂无正文",
                    message: "这个内容版本还没有可显示的文本。",
                    icon: "doc.text")
            } else {
                ReadBoardMarkdownBodyView(
                    markdown: markdown,
                    baseURL: originalURL,
                    style: ReadBoardMarkdownStyle(
                        fontSize: readingFontSize,
                        lineSpacing: readingLineSpacing,
                        palette: readingPalette.markdown,
                        layoutRevision: markdownLayoutRevision,
                        fontProvider: { size, weight, design in
                            ReadBoardReadingFont.font(
                                rawValue: fontRaw,
                                size: size,
                                weight: weight,
                                design: design)
                        }))
                    .textSelection(.enabled)
            }
        } else if let error = model.detailErrorMessage {
            ReadBoardArticleEmptyState(
                title: "正文加载失败",
                message: error,
                icon: "doc.text.magnifyingglass",
                retry: { Task { await model.open(
                    currentSummary, automaticallyMarksRead: false, loadsDetail: true) } })
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<9, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ReadBoardDesign.C.surface)
                        .frame(height: 13)
                        .frame(
                            maxWidth: index % 3 == 2 ? 480 : .infinity,
                            alignment: .leading)
                }
            }
            .redacted(reason: .placeholder)
        }
    }

    @ViewBuilder
    private var mediaPlayer: some View {
        if let item = playbackItem {
            if let globalMediaPlayer {
                ReadBoardGlobalMediaPlayerView(item: item, player: globalMediaPlayer)
            } else if let detail = currentDetail {
                if item.kind == .audio,
                   let rawURL = detail.audioURL,
                   let url = playableURL(rawURL) {
                    ReadBoardAudioPlayerView(url: url, title: currentSummary.title)
                } else if let videoID = item.videoID {
                    if item.kind == .bilibili {
                        ReadBoardBilibiliPlayerView(bvid: videoID, pageURL: originalURL)
                    } else {
                        ReadBoardYouTubePlayerView(
                            videoID: videoID,
                            title: currentSummary.title,
                            gateway: environment.mediaPlayback)
                    }
                }
            }
        }
    }

    private var playbackItem: ReadBoardPlaybackItem? {
        guard let detail = currentDetail else { return nil }
        return ReadBoardPlaybackItem.make(summary: currentSummary, detail: detail)
    }

    private var readBinding: Binding<Bool> {
        Binding(get: { currentSummary.isRead }, set: { _ in })
    }

    private var starredBinding: Binding<Bool> {
        Binding(get: { currentSummary.isStarred }, set: { _ in })
    }

    private var originalURL: URL? {
        guard let url = URL(string: currentSummary.url),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    private var isVideoContent: Bool {
        ["video", "youtube"].contains(currentSummary.contentType.lowercased())
            || currentSummary.sourceType?.lowercased().contains("bilibili") == true
            || currentSummary.sourceType?.lowercased().contains("youtube") == true
    }

    private var videoPlatform: ReadBoardVideoPlayerPlatform {
        ReadBoardVideoPlayerPlatform.resolve(
            source: currentSummary.sourceType ?? currentSummary.source,
            pageURL: originalURL)
    }

    private var readingPalette: ReadBoardReadingPalette {
        ReadBoardReadingPalette.resolve(
            theme: ReadBoardReadingTheme(rawValue: themeRaw) ?? .claude,
            mode: ReadBoardReadingColorMode(rawValue: themeModeRaw) ?? .system,
            systemColorScheme: colorScheme)
    }

    /// 标题、元信息和摘要属于阅读器界面层，只响应各自字号与界面缩放；
    /// 用户选择的 reading.font 仅交给正文 Markdown 的 fontProvider。
    private func interfaceFont(
        size: Double,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        ReadBoardInterfaceFont.font(
            rawValue: interfaceFontRaw,
            size: size * uiFontScale,
            weight: weight,
            design: design)
    }

    /// AttributedString 的字体属性嵌在正文渲染树中。macOS 不总会在这些偏好
    /// 改变时主动丢弃旧布局，因此提供一个纯外观版本号给共享 Markdown 内核。
    private var markdownLayoutRevision: String {
        [
            fontRaw,
            interfaceFontRaw,
            String(readingFontSize),
            String(titleFontSize),
            String(metaFontSize),
            String(summaryFontSize),
            String(readingLineSpacing),
            String(readingContentWidth),
            String(uiFontScale),
            themeRaw,
            themeModeRaw,
            colorScheme == .dark ? "dark" : "light",
        ].joined(separator: "|")
    }

    private var isMediaDocument: Bool {
        document.kind == .podcast || document.kind == .video
    }

    private var selectedMode: ReadBoardArticleContentMode {
        ReadBoardReadingModePreference.selectedMode(
            isMedia: isMediaDocument,
            articleViewMode: articleViewMode,
            mediaTab: mediaTab,
            availableModes: document.availableModes,
            preferredMode: document.preferredMode)
    }

    private var selectedModeBinding: Binding<ReadBoardArticleContentMode> {
        Binding(
            get: { selectedMode },
            set: { value in
                if isMediaDocument {
                    mediaTab = ReadBoardReadingModePreference.mediaTab(for: value)
                } else {
                    articleViewMode = ReadBoardReadingModePreference.articleViewMode(for: value)
                }
            })
    }

    private func playableURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme) else {
            return nil
        }
        return url
    }

}
