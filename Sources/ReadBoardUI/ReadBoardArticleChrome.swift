import ReadBoardContract
import SwiftUI

public enum ReadBoardArticleContentMode: String, CaseIterable, Identifiable, Sendable {
    case original
    case translated
    case transcript

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: "原文"
        case .translated: "译文"
        case .transcript: "转录"
        }
    }
}

public enum ReadBoardArticleKind: Equatable, Sendable {
    case rss
    case podcast
    case video
    case other
}

public struct ReadBoardArticleBadgeValue: Identifiable, Sendable {
    public let id: String
    public let text: String
    public let color: Color

    public init(id: String, text: String, color: Color) {
        self.id = id
        self.text = text
        self.color = color
    }
}

/// Contract 数据到共享详情页的纯展示模型；Core 与 Go 不再分别判断正文版本。
public struct ReadBoardArticleDocument: Sendable {
    public let summary: ContentSummary
    public let detail: ContentDetail?

    public init(summary: ContentSummary, detail: ContentDetail? = nil) {
        self.summary = summary
        self.detail = detail
    }

    public var availableModes: [ReadBoardArticleContentMode] {
        var result: [ReadBoardArticleContentMode] = []
        if detail?.contentMarkdown?.isEmpty == false { result.append(.original) }
        if detail?.translatedMarkdown?.isEmpty == false { result.append(.translated) }
        if detail?.transcriptMarkdown?.isEmpty == false { result.append(.transcript) }
        return result.isEmpty ? [.original] : result
    }

    public var preferredMode: ReadBoardArticleContentMode {
        if detail?.translatedMarkdown?.isEmpty == false { return .translated }
        if detail?.contentMarkdown?.isEmpty == false { return .original }
        if detail?.transcriptMarkdown?.isEmpty == false { return .transcript }
        return .original
    }

    public func markdown(for mode: ReadBoardArticleContentMode) -> String {
        switch mode {
        case .original: detail?.contentMarkdown ?? ""
        case .translated: detail?.translatedMarkdown ?? ""
        case .transcript: detail?.transcriptMarkdown ?? ""
        }
    }

    public var translatedTitle: String? {
        let value = detail?.translatedTitle ?? summary.translatedTitle
        guard let value, !value.isEmpty, value != summary.title else { return nil }
        return value
    }

    public var summaryText: String? {
        let value = detail?.summary ?? summary.summary
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    public var score: Int? { detail?.score ?? summary.score }

    public var originalURL: URL? {
        guard let url = URL(string: summary.url), ["http", "https"].contains(url.scheme) else {
            return nil
        }
        return url
    }

    public var kind: ReadBoardArticleKind {
        if summary.contentType == "podcast" { return .podcast }
        if summary.isMedia || ["video", "youtube"].contains(summary.contentType.lowercased()) {
            return .video
        }
        return summary.contentType == "rss" ? .rss : .other
    }

    public var metadataParts: [String] {
        var result: [String] = []
        let source = summary.sourceName ?? summary.source
        if !source.isEmpty { result.append(source) }
        if let author = summary.author, !author.isEmpty { result.append(author) }
        if let publishedAt = summary.publishedAt {
            result.append(Date(timeIntervalSince1970: TimeInterval(publishedAt)).formatted(
                .dateTime.year().month().day()))
        }
        if let score { result.append("评分 \(score)") }
        return result
    }

    public var badges: [ReadBoardArticleBadgeValue] {
        var result: [ReadBoardArticleBadgeValue] = []
        if summary.hasFulltext {
            result.append(.init(id: "fulltext", text: "全文", color: ReadBoardDesign.C.scoreHigh))
        }
        if summary.hasTranslation {
            result.append(.init(id: "translation", text: "翻译", color: ReadBoardDesign.C.translate))
        }
        if summary.hasTranscript {
            result.append(.init(id: "transcript", text: "转录", color: ReadBoardDesign.C.summary))
        }
        return result
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 90...: ReadBoardDesign.C.scoreHigh
        case 75..<90: ReadBoardDesign.C.scoreGood
        case 60..<75: ReadBoardDesign.C.scoreMid
        case 1..<60: ReadBoardDesign.C.scoreLow
        default: ReadBoardDesign.C.scoreNone
        }
    }
}

public struct ReadBoardArticleModePicker<Item: Hashable>: View {
    public let items: [(Item, String)]
    @Binding public var selection: Item
    public let fontSize: CGFloat
    public let fillsAvailableWidth: Bool

    public init(
        items: [(Item, String)],
        selection: Binding<Item>,
        fontSize: CGFloat = 11,
        fillsAvailableWidth: Bool = false
    ) {
        self.items = items
        _selection = selection
        self.fontSize = fontSize
        self.fillsAvailableWidth = fillsAvailableWidth
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                let (item, label) = items[index]
                let isSelected = selection == item
                Button { selection = item } label: {
                    Text(label)
                        .font(.system(size: fontSize, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(
                            isSelected ? ReadBoardDesign.C.accent : ReadBoardDesign.C.text2)
                        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background {
                            Capsule().fill(
                                isSelected ? ReadBoardDesign.C.accent.opacity(0.12) : Color.clear)
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
            }
        }
        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
        .padding(2)
        .background(Capsule().fill(ReadBoardDesign.C.surface))
        .overlay {
            Capsule().strokeBorder(
                ReadBoardDesign.C.hairline, lineWidth: ReadBoardDesign.Line.hair)
        }
    }
}

public struct ReadBoardArticleActionBar<SettingsContent: View>: View {
    @Binding public var isRead: Bool
    @Binding public var isStarred: Bool
    @Binding public var selectedMode: ReadBoardArticleContentMode
    @Binding public var showsSettings: Bool
    public let availableModes: [ReadBoardArticleContentMode]
    public let canUpdateReadingState: Bool
    public let originalURL: URL?
    public let shareAction: (() -> Void)?
    public let previousAction: (() -> Void)?
    public let nextAction: (() -> Void)?
    public let canGoPrevious: Bool
    public let canGoNext: Bool
    public let onToggleRead: () -> Void
    public let onToggleStarred: () -> Void
    private let settingsContent: SettingsContent

    public init(
        isRead: Binding<Bool>,
        isStarred: Binding<Bool>,
        selectedMode: Binding<ReadBoardArticleContentMode>,
        showsSettings: Binding<Bool>,
        availableModes: [ReadBoardArticleContentMode],
        canUpdateReadingState: Bool = true,
        originalURL: URL? = nil,
        shareAction: (() -> Void)? = nil,
        previousAction: (() -> Void)? = nil,
        nextAction: (() -> Void)? = nil,
        canGoPrevious: Bool = false,
        canGoNext: Bool = false,
        onToggleRead: @escaping () -> Void,
        onToggleStarred: @escaping () -> Void,
        @ViewBuilder settingsContent: () -> SettingsContent
    ) {
        _isRead = isRead
        _isStarred = isStarred
        _selectedMode = selectedMode
        _showsSettings = showsSettings
        self.availableModes = availableModes
        self.canUpdateReadingState = canUpdateReadingState
        self.originalURL = originalURL
        self.shareAction = shareAction
        self.previousAction = previousAction
        self.nextAction = nextAction
        self.canGoPrevious = canGoPrevious
        self.canGoNext = canGoNext
        self.onToggleRead = onToggleRead
        self.onToggleStarred = onToggleStarred
        self.settingsContent = settingsContent()
    }

    public var body: some View {
        HStack(spacing: ReadBoardDesign.Space.md) {
            HStack(spacing: 2) {
                quietButton(
                    icon: isStarred ? "star.fill" : "star",
                    help: isStarred ? "取消收藏" : "收藏",
                    color: isStarred ? ReadBoardDesign.C.star : ReadBoardDesign.C.text2,
                    disabled: !canUpdateReadingState,
                    action: onToggleStarred)
                quietButton(
                    icon: isRead ? "envelope.open" : "envelope",
                    help: isRead ? "标为未读" : "标为已读",
                    color: ReadBoardDesign.C.text2,
                    disabled: !canUpdateReadingState,
                    action: onToggleRead)
                if let shareAction {
                    quietButton(
                        icon: "square.and.arrow.up", help: "分享 / 后处理",
                        color: ReadBoardDesign.C.text2, action: shareAction)
                }
                if let originalURL {
                    Link(destination: originalURL) {
                        Image(systemName: "safari").frame(width: 24, height: 24)
                    }
                    .buttonStyle(ReadBoardQuietButtonStyle())
                    .help("打开原文")
                }
            }

            Spacer(minLength: 0)

            if availableModes.count > 1 {
                ReadBoardArticleModePicker(
                    items: availableModes.map { ($0, $0.title) },
                    selection: $selectedMode)
                    .frame(maxWidth: 340)
            } else {
                Text(availableModes.first?.title ?? "正文")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ReadBoardDesign.C.text3)
            }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                if let previousAction {
                    quietButton(
                        icon: "chevron.up", help: "上一篇（K）",
                        color: ReadBoardDesign.C.text2,
                        disabled: !canGoPrevious,
                        action: previousAction)
                }
                if let nextAction {
                    quietButton(
                        icon: "chevron.down", help: "下一篇（J）",
                        color: ReadBoardDesign.C.text2,
                        disabled: !canGoNext,
                        action: nextAction)
                }
                Button { showsSettings = true } label: {
                    Text("Aa")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ReadBoardQuietButtonStyle())
                .help("阅读版式")
                .popover(isPresented: $showsSettings, arrowEdge: .bottom) { settingsContent }
            }
        }
        .padding(.horizontal, ReadBoardDesign.Space.md)
        .padding(.vertical, 7)
        .background(ReadBoardDesign.C.surface.opacity(0.32))
    }

    private func quietButton(
        icon: String,
        help: String,
        color: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 24, height: 24)
        }
        .buttonStyle(ReadBoardQuietButtonStyle())
        .disabled(disabled)
        .help(help)
    }
}

public struct ReadBoardArticleHeader<TitleContent: View>: View {
    public let translatedTitle: String?
    public let metadataParts: [String]
    public let kind: ReadBoardArticleKind
    public let badges: [ReadBoardArticleBadgeValue]
    public let translatedTitleFont: Font
    public let translatedTitleColor: Color
    public let metadataFont: Font
    public let metadataColor: Color
    private let titleContent: TitleContent

    public init(
        translatedTitle: String?,
        metadataParts: [String],
        kind: ReadBoardArticleKind,
        badges: [ReadBoardArticleBadgeValue] = [],
        translatedTitleFont: Font = .system(size: 16, weight: .medium, design: .serif),
        translatedTitleColor: Color = ReadBoardDesign.C.text2,
        metadataFont: Font = .system(size: 11),
        metadataColor: Color = ReadBoardDesign.C.text3,
        @ViewBuilder title: () -> TitleContent
    ) {
        self.translatedTitle = translatedTitle
        self.metadataParts = metadataParts
        self.kind = kind
        self.badges = badges
        self.translatedTitleFont = translatedTitleFont
        self.translatedTitleColor = translatedTitleColor
        self.metadataFont = metadataFont
        self.metadataColor = metadataColor
        self.titleContent = title()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ReadBoardDesign.Space.md) {
            VStack(alignment: .leading, spacing: ReadBoardDesign.Space.sm) {
                titleContent
                if let translatedTitle, !translatedTitle.isEmpty {
                    Text(translatedTitle)
                        .font(translatedTitleFont)
                        .foregroundStyle(translatedTitleColor)
                        .textSelection(.enabled)
                }
            }
            if !metadataParts.isEmpty {
                HStack(spacing: 6) {
                    kindIcon
                    Text(metadataParts.joined(separator: "  ·  "))
                }
                .font(metadataFont)
                .foregroundStyle(metadataColor)
            }
            if !badges.isEmpty {
                HStack(spacing: 6) {
                    ForEach(badges) { badge in
                        ReadBoardBadge(text: badge.text, color: badge.color)
                    }
                }
            }
        }
    }

    @ViewBuilder private var kindIcon: some View {
        switch kind {
        case .podcast:
            Image(systemName: "mic.fill").foregroundStyle(ReadBoardDesign.C.podcast)
        case .video:
            Image(systemName: "play.rectangle.fill").foregroundStyle(ReadBoardDesign.C.video)
        case .rss:
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(ReadBoardDesign.C.rss)
        case .other:
            Image(systemName: "doc.text").foregroundStyle(ReadBoardDesign.C.text3)
        }
    }
}

public struct ReadBoardArticleSummaryCard: View {
    public let text: String
    public let font: Font
    public let textColor: Color
    public let backgroundColor: Color

    public init(
        text: String,
        font: Font = .system(size: 14),
        textColor: Color = ReadBoardDesign.C.text2,
        backgroundColor: Color = ReadBoardDesign.C.surface
    ) {
        self.text = text
        self.font = font
        self.textColor = textColor
        self.backgroundColor = backgroundColor
    }

    public var body: some View {
        Text(text)
            .font(font).foregroundStyle(textColor).lineSpacing(3)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor)
            .overlay(alignment: .leading) {
                Rectangle().fill(ReadBoardDesign.C.summary.opacity(0.85)).frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
            .textSelection(.enabled)
    }
}

public struct ReadBoardArticleEmptyState: View {
    public let title: String
    public let message: String
    public let icon: String
    public let retry: (() -> Void)?

    public init(
        title: String, message: String, icon: String,
        retry: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.icon = icon
        self.retry = retry
    }

    public var body: some View {
        VStack(spacing: ReadBoardDesign.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(ReadBoardDesign.C.text3)
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(ReadBoardDesign.C.text2)
            Text(message)
                .font(.system(size: 11)).foregroundStyle(ReadBoardDesign.C.text3)
                .multilineTextAlignment(.center)
            if let retry {
                Button("重试", action: retry).buttonStyle(ReadBoardSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
