import Foundation
import ReadBoardContract
import ReadBoardUI
import SwiftUI

public struct ReadBoardArticleDetailFeatureView: View {
    public let summary: ContentSummary
    public let model: ReadBoardLibraryFeatureModel
    private let environment: ReadBoardFeatureEnvironment

    @Environment(\.colorScheme) private var colorScheme
    @State private var showReadingSettings = false
    @State private var showShareSheet = false
    @AppStorage("reading.viewMode") private var articleViewMode = 0
    @AppStorage("reading.mediaTab") private var mediaTab = 0
    @AppStorage("reading.theme") private var themeRaw = ReadBoardReadingTheme.claude.rawValue
    @AppStorage("reading.themeMode") private var themeModeRaw = ReadBoardReadingColorMode.system.rawValue
    @AppStorage("reading.font") private var fontRaw = "system"
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
        environment: ReadBoardFeatureEnvironment
    ) {
        self.summary = summary
        self.model = model
        self.environment = environment
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
            ScrollView {
                VStack(alignment: .leading, spacing: ReadBoardDesign.Space.xl) {
                    articleHeader
                    processingActions
                    mediaPlayer
                    detailContent
                }
                .frame(maxWidth: readingContentWidth, alignment: .leading)
                .padding(.horizontal, ReadBoardDesign.Space.xl)
                .padding(.vertical, ReadBoardDesign.Space.xl)
                .frame(maxWidth: .infinity)
            }
        }
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
                }
            }
        }
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
                translatedTitleFont: readingFont(
                    size: titleFontSize * 0.72, weight: .medium, design: .serif),
                translatedTitleColor: readingPalette.textSecondary,
                metadataFont: readingFont(size: metaFontSize),
                metadataColor: readingPalette.textFaint
            ) {
                if let originalURL {
                    Link(destination: originalURL) { articleTitle }
                        .buttonStyle(.plain)
                        .help("点击在浏览器打开原文")
                } else {
                    articleTitle
                }
            }
            if let summaryText = document.summaryText {
                ReadBoardArticleSummaryCard(
                    text: summaryText,
                    font: readingFont(size: summaryFontSize),
                    textColor: readingPalette.textSecondary,
                    backgroundColor: readingPalette.markdown.backgroundAlt)
            }
        }
    }

    private var articleTitle: some View {
        Text(currentSummary.title)
            .font(readingFont(size: titleFontSize, weight: .semibold, design: .serif))
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
        if let detail = currentDetail {
            if currentSummary.contentType == "podcast",
               let rawURL = detail.audioURL,
               let url = playableURL(rawURL) {
                ReadBoardAudioPlayerView(url: url, title: currentSummary.title)
            } else if isVideoContent,
                      let videoID = detail.videoID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !videoID.isEmpty {
                if videoPlatform == .bilibili {
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

    private func readingFont(
        size: Double,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        ReadBoardReadingFont.font(
            rawValue: fontRaw,
            size: size * uiFontScale,
            weight: weight,
            design: design)
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
