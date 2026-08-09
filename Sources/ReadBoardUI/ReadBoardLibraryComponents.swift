import ReadBoardContract
import SwiftUI

public enum ReadBoardLibraryCollection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case unread
    case starred
    case pending
    case exported
    case articles
    case podcasts
    case videos

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "全部文章"
        case .unread: "未读"
        case .starred: "收藏"
        case .pending: "待处理"
        case .exported: "已导出"
        case .articles: "文章"
        case .podcasts: "播客"
        case .videos: "视频"
        }
    }
    public var compactTitle: String {
        switch self {
        case .starred: "星标"
        default: title
        }
    }

    public var icon: String {
        switch self {
        case .all: "tray.full"
        case .unread: "circlebadge.fill"
        case .starred: "star.fill"
        case .pending: "clock.badge.exclamationmark"
        case .exported: "square.and.arrow.up"
        case .articles: "doc.text.fill"
        case .podcasts: "mic.fill"
        case .videos: "play.rectangle.fill"
        }
    }

    public var initialReadFilter: ReadBoardLibraryReadFilter {
        switch self {
        case .unread: .unread
        case .starred: .starred
        default: .all
        }
    }

    public var initialCategoryFilter: ReadBoardLibraryCategoryFilter {
        switch self {
        case .articles: .article
        case .podcasts: .podcast
        case .videos: .video
        default: .all
        }
    }

    public func count(in counts: LibraryCountsSnapshot) -> Int? {
        switch self {
        case .all: counts.total
        case .unread: counts.unread
        case .starred: nil
        case .pending: counts.pending
        case .exported: counts.exported
        case .articles: counts.articles
        case .podcasts: counts.podcasts
        case .videos: counts.videos
        }
    }

    public func countPair(in counts: LibraryCountsSnapshot) -> (unread: Int, total: Int)? {
        switch self {
        case .all, .unread:
            (counts.unread, counts.total)
        case .starred:
            nil
        case .pending:
            (counts.pendingUnread, counts.pending)
        case .exported:
            (counts.exportedUnread, counts.exported)
        case .articles:
            (counts.articleUnread, counts.articles)
        case .podcasts:
            (counts.podcastUnread, counts.podcasts)
        case .videos:
            (counts.videoUnread, counts.videos)
        }
    }
}

public enum ReadBoardLibraryReadFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case unread
    case starred

    public var id: String { rawValue }
    public var readState: ContentReadState {
        switch self {
        case .all: .all
        case .unread: .unread
        case .starred: .starred
        }
    }
    public var title: String {
        switch self {
        case .all: "全部"
        case .unread: "未读"
        case .starred: "收藏"
        }
    }
    public var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .unread: "circlebadge.fill"
        case .starred: "star"
        }
    }
    public var compactTitle: String {
        switch self {
        case .starred: "星标"
        default: title
        }
    }
}

public enum ReadBoardLibraryCategoryFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case article
    case podcast
    case video

    public var id: String { rawValue }
    public var category: ContentCategory? {
        switch self {
        case .all: nil
        case .article: .article
        case .podcast: .podcast
        case .video: .video
        }
    }
    public var title: String {
        switch self {
        case .all: "全部类型"
        case .article: "文章"
        case .podcast: "播客"
        case .video: "视频"
        }
    }
    public var systemImage: String {
        switch self {
        case .all: "square.stack"
        case .article: "doc.text"
        case .podcast: "mic"
        case .video: "play.rectangle"
        }
    }
}

public enum ReadBoardLibrarySortOption: String, CaseIterable, Identifiable, Hashable, Sendable {
    case newest
    case oldest
    case score

    public var id: String { rawValue }
    public var sort: ContentSort {
        switch self {
        case .newest: .newest
        case .oldest: .oldest
        case .score: .score
        }
    }
    public var title: String {
        switch self {
        case .newest: "最新优先"
        case .oldest: "最早优先"
        case .score: "评分优先"
        }
    }
    public var compactTitle: String {
        switch self {
        case .newest: "最新"
        case .oldest: "最早"
        case .score: "评分"
        }
    }
}

public enum ReadBoardLibraryDensity: String, Sendable {
    case compact
    case comfortable
}

public enum ReadBoardLibraryDateStyle: String, Sendable {
    case absolute
    case relative
}

public struct ReadBoardLibraryRowStyle: Sendable {
    public var scale: Double
    public var density: ReadBoardLibraryDensity
    public var showSource: Bool
    public var showDate: Bool
    public var unreadBold: Bool
    public var dateStyle: ReadBoardLibraryDateStyle
    public var excerptLines: Int
    public var usesSystemSelection: Bool

    public init(
        scale: Double = 1,
        density: ReadBoardLibraryDensity = .comfortable,
        showSource: Bool = true,
        showDate: Bool = true,
        unreadBold: Bool = true,
        dateStyle: ReadBoardLibraryDateStyle = .absolute,
        excerptLines: Int = 0,
        usesSystemSelection: Bool = false
    ) {
        self.scale = scale
        self.density = density
        self.showSource = showSource
        self.showDate = showDate
        self.unreadBold = unreadBold
        self.dateStyle = dateStyle
        self.excerptLines = max(0, excerptLines)
        self.usesSystemSelection = usesSystemSelection
    }
}

public struct ReadBoardLibraryItemPresentation: Sendable {
    public let item: ContentSummary
    public let isRead: Bool

    public init(item: ContentSummary, isReadOverride: Bool? = nil) {
        self.item = item
        self.isRead = isReadOverride ?? item.isRead
    }

    public var displayTitle: String {
        if let title = item.translatedTitle, !title.isEmpty { return title }
        if let head = item.translatedHead, !head.isEmpty {
            let first = head.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            let cleaned = first.replacingOccurrences(
                of: "^#+\\s*", with: "", options: .regularExpression)
            if !cleaned.isEmpty { return cleaned }
        }
        return item.title
    }

    public var platform: String {
        (item.sourceType ?? item.source).lowercased()
    }

    public var platformIcon: String? {
        if platform.contains("podcast") || item.contentType == "podcast" { return "mic.fill" }
        if platform.contains("youtube") { return "play.rectangle.fill" }
        if platform.contains("bilibili") { return "tv.fill" }
        if platform.contains("wechat") { return "message.badge.filled.fill" }
        if ["video", "youtube"].contains(item.contentType) { return "play.rectangle.fill" }
        return nil
    }

    public var platformColor: Color {
        if platform.contains("podcast") || item.contentType == "podcast" {
            return ReadBoardDesign.C.podcast
        }
        if platform.contains("youtube") { return ReadBoardDesign.C.youtube }
        if platform.contains("bilibili") { return ReadBoardDesign.C.bilibili }
        if platform.contains("wechat") { return ReadBoardDesign.C.wechat }
        if ["video", "youtube"].contains(item.contentType) { return ReadBoardDesign.C.video }
        return ReadBoardDesign.C.rss
    }

    public var isRSS: Bool {
        platform == "rss" || platform == "article" || platformIcon == nil
    }

    public var excerpt: String? {
        let value = item.summary ?? item.excerpt
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    public func formattedDate(style: ReadBoardLibraryDateStyle, now: Date = Date()) -> String? {
        guard let publishedAt = item.publishedAt else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(publishedAt))
        if style == .absolute {
            return Self.isoDay(date)
        }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3_600) 小时前" }
        if seconds < 86_400 * 7 { return "\(seconds / 86_400) 天前" }
        return Self.isoDay(date)
    }

    public var badges: [ReadBoardArticleBadgeValue] {
        var result: [ReadBoardArticleBadgeValue] = []
        if let access = accessBadge { result.append(access) }
        if item.contentType != "podcast", item.hasFulltext {
            result.append(.init(id: "fulltext", text: "全文", color: ReadBoardDesign.C.scoreHigh))
        }
        if let score = item.score {
            result.append(.init(id: "score", text: "评分 \(score)", color: scoreColor(score)))
        }
        if item.summary?.isEmpty == false {
            result.append(.init(id: "summary", text: "摘要", color: ReadBoardDesign.C.summary))
        }
        if item.hasTranslation {
            result.append(.init(id: "translation", text: "翻译", color: ReadBoardDesign.C.translate))
        }
        if item.isMedia, item.hasTranscript {
            result.append(.init(id: "transcript", text: "转录", color: ReadBoardDesign.C.summary))
        }
        return result
    }

    private var accessBadge: ReadBoardArticleBadgeValue? {
        switch item.accessState {
        case "paidPreview":
            .init(id: "access", text: "单片付费", color: ReadBoardDesign.C.scoreLow)
        case "paidSeason":
            .init(id: "access", text: "付费合集", color: ReadBoardDesign.C.scoreLow)
        case "upowerExclusive":
            .init(id: "access", text: "充电专属", color: ReadBoardDesign.C.scoreMid)
        case "upowerEarlyAccess":
            .init(id: "access", text: "充电抢先看", color: ReadBoardDesign.C.scoreMid)
        case "loginRequired":
            .init(id: "access", text: "需登录", color: ReadBoardDesign.C.text2)
        default: nil
        }
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

    private static func isoDay(_ date: Date) -> String {
        let value = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let year = value.year, let month = value.month, let day = value.day else {
            return ""
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

public struct ReadBoardLibraryRow: View {
    public let item: ContentSummary
    public let isSelected: Bool
    public let isReadOverride: Bool?
    public let style: ReadBoardLibraryRowStyle

    public init(
        item: ContentSummary,
        isSelected: Bool = false,
        isReadOverride: Bool? = nil,
        style: ReadBoardLibraryRowStyle = .init()
    ) {
        self.item = item
        self.isSelected = isSelected
        self.isReadOverride = isReadOverride
        self.style = style
    }

    private var presentation: ReadBoardLibraryItemPresentation {
        ReadBoardLibraryItemPresentation(item: item, isReadOverride: isReadOverride)
    }

    private var isCompact: Bool { style.density == .compact }

    public var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Circle()
                .fill(presentation.isRead ? Color.clear : ReadBoardDesign.C.accent)
                .frame(width: 6, height: 6).frame(width: 8)

            VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
                HStack(alignment: .top, spacing: 6) {
                    Text(presentation.displayTitle)
                        .font(.system(
                            size: ReadBoardDesign.F.rowTitle * style.scale,
                            weight: style.unreadBold && !presentation.isRead ? .semibold : .regular))
                        .foregroundStyle(titleColor)
                        .lineLimit(isCompact ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.isStarred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(ReadBoardDesign.C.star)
                            .font(.system(size: 11 * style.scale))
                    }
                    Spacer(minLength: 0)
                }

                if style.showSource || style.showDate {
                    HStack(spacing: 6) {
                        if presentation.isRSS {
                            ReadBoardRSSIcon(size: 11, color: ReadBoardDesign.C.rss)
                        } else if let icon = presentation.platformIcon {
                            Image(systemName: icon)
                                .font(.system(size: 11))
                                .foregroundStyle(presentation.platformColor)
                        }
                        if style.showSource {
                            Text(item.sourceName ?? item.source).lineLimit(1)
                        }
                        if style.showSource, style.showDate, item.publishedAt != nil { Text("·") }
                        if style.showDate, let date = presentation.formattedDate(style: style.dateStyle) {
                            Text(date)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: ReadBoardDesign.F.rowMeta * style.scale))
                    .foregroundStyle(ReadBoardDesign.C.text3)
                }

                if style.excerptLines > 0, let excerpt = presentation.excerpt {
                    Text(excerpt)
                        .font(.system(size: ReadBoardDesign.F.rowExcerpt * style.scale))
                        .foregroundStyle(ReadBoardDesign.C.text2)
                        .lineLimit(style.excerptLines)
                }

                HStack(spacing: 6) {
                    ForEach(presentation.badges) { badge in
                        ReadBoardBadge(text: badge.text, color: badge.color, scale: style.scale)
                    }
                    Spacer(minLength: 8)
                    if item.hasExport {
                        ReadBoardBadge(
                            text: "已导出", color: ReadBoardDesign.C.accent, scale: style.scale)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isCompact ? 4 : 8)
        .contentShape(Rectangle())
        .readBoardSelected(isSelected && !style.usesSystemSelection)
    }

    private var titleColor: Color {
        if isSelected, style.usesSystemSelection { return Color.white.opacity(0.82) }
        return presentation.isRead ? ReadBoardDesign.C.text2 : ReadBoardDesign.C.text
    }
}

public struct ReadBoardRSSIcon: View {
    public let size: CGFloat
    public let color: Color

    public init(size: CGFloat = 11, color: Color = ReadBoardDesign.C.rss) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 16
            let shading = GraphicsContext.Shading.color(color)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: 2 * scale, y: 12 * scale,
                    width: 2.5 * scale, height: 2.5 * scale)),
                with: shading)
            var innerArc = Path()
            innerArc.addArc(
                center: CGPoint(x: 2 * scale, y: 14 * scale), radius: 6 * scale,
                startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            context.stroke(innerArc, with: shading, lineWidth: 1.8 * scale)
            var outerArc = Path()
            outerArc.addArc(
                center: CGPoint(x: 2 * scale, y: 14 * scale), radius: 11 * scale,
                startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            context.stroke(outerArc, with: shading, lineWidth: 1.8 * scale)
        }
        .frame(width: size, height: size)
    }
}

public struct ReadBoardLibraryRowPlaceholder: View {
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("正在加载文章标题").font(.system(size: 14, weight: .semibold))
            Text("内容来源 · 2026-08-09").font(.system(size: 11))
            Text("这里会显示文章摘要，帮助快速判断是否值得打开阅读。")
                .font(.system(size: 12))
        }
        .foregroundStyle(ReadBoardDesign.C.text2)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .redacted(reason: .placeholder)
    }
}

public struct ReadBoardLibraryPaginationFooter: View {
    public let isLoading: Bool

    public init(isLoading: Bool) {
        self.isLoading = isLoading
    }

    public var body: some View {
        HStack {
            Spacer()
            ProgressView(isLoading ? "正在加载更多…" : "继续加载")
                .controlSize(.small)
                .tint(ReadBoardDesign.C.accent)
                .font(.system(size: 10))
                .foregroundStyle(ReadBoardDesign.C.text3)
            Spacer()
        }
        .padding(ReadBoardDesign.Space.md)
    }
}

public enum ReadBoardLibraryColumnMetrics {
    public static let sidebarMinimum: CGFloat = 180
    public static let sidebarIdeal: CGFloat = 230
    public static let sidebarMaximum: CGFloat = 360
    public static let listMinimum: CGFloat = 280
    public static let listIdeal: CGFloat = 380
    public static let listMaximum: CGFloat = 640
}

/// Go 的桌面双栏与 Core 三栏中的中、右两栏共用同一组尺寸和分隔规则。
public struct ReadBoardLibraryDesktopColumns<ListPane: View, DetailPane: View>: View {
    private let listPane: ListPane
    private let detailPane: DetailPane

    public init(
        @ViewBuilder list: () -> ListPane,
        @ViewBuilder detail: () -> DetailPane
    ) {
        self.listPane = list()
        self.detailPane = detail()
    }

    public var body: some View {
        #if os(macOS)
        HSplitView {
            listPane
                .frame(
                    minWidth: ReadBoardLibraryColumnMetrics.listMinimum,
                    idealWidth: ReadBoardLibraryColumnMetrics.listIdeal,
                    maxWidth: ReadBoardLibraryColumnMetrics.listMaximum)
                .background(ReadBoardDesign.C.bg)

            detailPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                .background(ReadBoardDesign.C.bg)
        }
        .background(ReadBoardDesign.C.bg)
        #else
        detailPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ReadBoardDesign.C.bg)
        #endif
    }
}

public struct ReadBoardLibraryEmptyState: View {
    public let title: String
    public let message: String
    public let icon: String
    public let actionTitle: String?
    public let action: (() -> Void)?

    public init(
        title: String, message: String, icon: String,
        actionTitle: String? = nil, action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.icon = icon
        self.actionTitle = actionTitle
        self.action = action
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
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(ReadBoardSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ReadBoardDesign.Space.xxl)
    }
}

public struct ReadBoardReaderPlaceholder: View {
    public let count: Int?

    public init(count: Int? = nil) { self.count = count }

    public var body: some View {
        VStack(spacing: ReadBoardDesign.Space.md) {
            ZStack {
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.xl)
                    .fill(ReadBoardDesign.C.surface.opacity(0.7))
                Image(systemName: "doc.text")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(ReadBoardDesign.C.text3)
            }
            .frame(width: 54, height: 54)
            Text("选择一篇文章")
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(ReadBoardDesign.C.text2)
            Text(count.map { "共 \($0) 条内容" } ?? "内容会在这里打开，不离开当前列表。")
                .font(.system(size: 11)).foregroundStyle(ReadBoardDesign.C.text3)
        }
    }
}

public struct ReadBoardLibrarySidebarRow<CountContent: View>: View {
    public let title: String
    public let icon: String
    public let iconColor: Color
    public let isSelected: Bool
    public let scale: Double
    public let action: () -> Void
    private let countContent: CountContent

    public init(
        title: String,
        icon: String,
        iconColor: Color = ReadBoardDesign.C.accent,
        isSelected: Bool,
        scale: Double = 1,
        action: @escaping () -> Void,
        @ViewBuilder count: () -> CountContent
    ) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
        self.isSelected = isSelected
        self.scale = scale
        self.action = action
        self.countContent = count()
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: ReadBoardDesign.F.sidebar * scale))
                    .foregroundStyle(ReadBoardDesign.C.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                countContent
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6 * scale)
            .contentShape(Rectangle())
            .readBoardSelected(isSelected)
        }
        .buttonStyle(.plain)
    }
}

public struct ReadBoardLibrarySearchField: View {
    @Binding public var text: String
    @FocusState.Binding private var isFocused: Bool
    public let placeholder: String
    public let onTextChange: (String) -> Void
    public let onFocusChange: (Bool) -> Void
    public let onSubmit: () -> Void

    public init(
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding,
        placeholder: String = "搜索标题 / 正文",
        onTextChange: @escaping (String) -> Void = { _ in },
        onFocusChange: @escaping (Bool) -> Void = { _ in },
        onSubmit: @escaping () -> Void = {}
    ) {
        _text = text
        _isFocused = isFocused
        self.placeholder = placeholder
        self.onTextChange = onTextChange
        self.onFocusChange = onFocusChange
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ReadBoardDesign.C.text3)
                .font(.system(size: 12))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isFocused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ReadBoardDesign.C.text3)
                }
                .buttonStyle(.plain)
            }
        }
        .readBoardField(focused: isFocused)
        .onChange(of: text) { _, value in onTextChange(value) }
        .onChange(of: isFocused) { _, value in onFocusChange(value) }
    }
}

public extension ReadBoardLibrarySidebarRow where CountContent == EmptyView {
    init(
        title: String,
        icon: String,
        iconColor: Color = ReadBoardDesign.C.accent,
        isSelected: Bool,
        scale: Double = 1,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title, icon: icon, iconColor: iconColor,
            isSelected: isSelected, scale: scale, action: action
        ) { EmptyView() }
    }
}
