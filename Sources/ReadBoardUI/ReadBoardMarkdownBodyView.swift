import Foundation
import ImageIO
import SwiftUI

public struct ReadBoardMarkdownPalette: @unchecked Sendable {
    public let backgroundAlt: Color
    public let codeBackground: Color
    public let inlineCodeBackground: Color
    public let text: Color
    public let textSecondary: Color
    public let textFaint: Color
    public let headings: [Color]
    public let bold: Color
    public let italic: Color
    public let inlineCode: Color
    public let link: Color
    public let quoteBorder: Color
    public let quoteText: Color
    public let listMarker: Color
    public let divider: Color
    public let codeText: Color

    public init(
        backgroundAlt: Color, codeBackground: Color, inlineCodeBackground: Color,
        text: Color, textSecondary: Color, textFaint: Color, headings: [Color],
        bold: Color, italic: Color, inlineCode: Color, link: Color,
        quoteBorder: Color, quoteText: Color, listMarker: Color, divider: Color,
        codeText: Color
    ) {
        self.backgroundAlt = backgroundAlt
        self.codeBackground = codeBackground
        self.inlineCodeBackground = inlineCodeBackground
        self.text = text
        self.textSecondary = textSecondary
        self.textFaint = textFaint
        self.headings = headings
        self.bold = bold
        self.italic = italic
        self.inlineCode = inlineCode
        self.link = link
        self.quoteBorder = quoteBorder
        self.quoteText = quoteText
        self.listMarker = listMarker
        self.divider = divider
        self.codeText = codeText
    }

    public static let paper = ReadBoardMarkdownPalette(
        backgroundAlt: ReadBoardDesign.C.surface,
        codeBackground: ReadBoardDesign.C.surface,
        inlineCodeBackground: ReadBoardDesign.C.separator.opacity(0.35),
        text: ReadBoardDesign.C.text,
        textSecondary: ReadBoardDesign.C.text2,
        textFaint: ReadBoardDesign.C.text3,
        headings: [ReadBoardDesign.C.text, ReadBoardDesign.C.accent,
                   ReadBoardDesign.C.translate, ReadBoardDesign.C.scoreMid],
        bold: ReadBoardDesign.C.text,
        italic: ReadBoardDesign.C.text2,
        inlineCode: ReadBoardDesign.C.scoreLow,
        link: ReadBoardDesign.C.accent,
        quoteBorder: ReadBoardDesign.C.accent,
        quoteText: ReadBoardDesign.C.text2,
        listMarker: ReadBoardDesign.C.accent,
        divider: ReadBoardDesign.C.hairline,
        codeText: ReadBoardDesign.C.text)
}

public struct ReadBoardMarkdownStyle {
    public let fontSize: CGFloat
    public let lineSpacing: CGFloat
    public let palette: ReadBoardMarkdownPalette
    public let layoutRevision: String
    private let fontProvider: (CGFloat, Font.Weight, Font.Design) -> Font

    public init(
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        palette: ReadBoardMarkdownPalette = .paper,
        layoutRevision: String = "default",
        fontProvider: @escaping (CGFloat, Font.Weight, Font.Design) -> Font = {
            size, weight, design in .system(size: size, weight: weight, design: design)
        }
    ) {
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.palette = palette
        self.layoutRevision = layoutRevision
        self.fontProvider = fontProvider
    }

    fileprivate func font(
        size: CGFloat? = nil,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        fontProvider(size ?? fontSize, weight, design)
    }
}

/// Core 与 Go 共用的正文渲染器。两端只提供外观参数，不再各自维护块布局和图片加载。
public struct ReadBoardMarkdownBodyView: View {
    public let markdown: String
    public let baseURL: URL?
    public let style: ReadBoardMarkdownStyle
    @State private var units: [RenderUnit] = []

    public init(
        markdown: String,
        baseURL: URL? = nil,
        style: ReadBoardMarkdownStyle
    ) {
        self.markdown = markdown
        self.baseURL = baseURL
        self.style = style
    }

    private struct RenderUnit {
        let blocks: [ReadBoardMarkdownBlock]
        var isMergedTextFlow: Bool { blocks.count > 1 }
    }

    // 单个 SwiftUI Text 承载数万字时，macOS 可能只布局前半段。连续正文仍按组支持
    // 跨段选择，但每组保持在一个保守上限内，确保长文全部进入布局树。
    nonisolated private static let maximumTextFlowCharacters = 12_000
    nonisolated private static let maximumTextFlowBlocks = 24

    public var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(units.indices, id: \.self) { index in
                let unit = units[index]
                if unit.isMergedTextFlow {
                    Text(attributedTextFlow(unit.blocks))
                        .font(style.font())
                        .lineSpacing(style.lineSpacing)
                        .foregroundStyle(style.palette.text)
                } else if let block = unit.blocks.first {
                    blockView(block)
                }
            }
        }
        // macOS 有时会让包含 AttributedString 的 LazyVStack 沿用字体变化前的
        // 文本布局缓存，结果是当前文章正文高度变成 0。只重建渲染子树，保留
        // 已解析的 units；切换字体、字号或主题时无需重新加载文章。
        .id(style.layoutRevision)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: markdown) {
            let parsed = await Task.detached(priority: .userInitiated) {
                ReadBoardMarkdownParser.parse(markdown)
            }.value
            units = Self.buildUnits(parsed)
        }
    }

    nonisolated public static func selectionUnitBlockCounts(markdown: String) -> [Int] {
        buildUnits(ReadBoardMarkdownParser.parse(markdown)).map(\.blocks.count)
    }

    nonisolated public static func selectionUnitCharacterCounts(markdown: String) -> [Int] {
        buildUnits(ReadBoardMarkdownParser.parse(markdown)).map { unit in
            unit.blocks.reduce(0) { $0 + textLength($1) }
        }
    }

    nonisolated private static func buildUnits(
        _ blocks: [ReadBoardMarkdownBlock]
    ) -> [RenderUnit] {
        var output: [RenderUnit] = []
        var textFlow: [ReadBoardMarkdownBlock] = []

        func flushTextFlow() {
            guard !textFlow.isEmpty else { return }
            output.append(RenderUnit(blocks: textFlow))
            textFlow = []
        }

        for sourceBlock in blocks {
            for block in splitOversizedTextFlowBlock(sourceBlock) {
                if isTextFlow(block) {
                    let currentCharacters = textFlow.reduce(0) { $0 + textLength($1) }
                    let nextCharacters = textLength(block)
                    if !textFlow.isEmpty,
                       textFlow.count >= maximumTextFlowBlocks
                        || currentCharacters + nextCharacters > maximumTextFlowCharacters {
                        flushTextFlow()
                    }
                    textFlow.append(block)
                } else {
                    flushTextFlow()
                    output.append(RenderUnit(blocks: [block]))
                }
            }
        }
        flushTextFlow()
        return output
    }

    nonisolated private static func splitOversizedTextFlowBlock(
        _ block: ReadBoardMarkdownBlock
    ) -> [ReadBoardMarkdownBlock] {
        guard case .paragraph(let text) = block,
              text.count > maximumTextFlowCharacters else { return [block] }
        return splitText(text, limit: maximumTextFlowCharacters).map {
            .paragraph(text: $0)
        }
    }

    /// Unicode 安全且不丢字符地拆分超长段落；优先在接近上限的空白或中文句末断开。
    nonisolated private static func splitText(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var result: [String] = []
        var start = text.startIndex
        while text.distance(from: start, to: text.endIndex) > limit {
            let hardEnd = text.index(start, offsetBy: limit)
            let searchStart = text.index(hardEnd, offsetBy: -(limit / 5))
            let preferredBreak = text[searchStart..<hardEnd].lastIndex {
                $0.isWhitespace || "。！？.!?；;".contains($0)
            }
            let end = preferredBreak.map { text.index(after: $0) } ?? hardEnd
            result.append(String(text[start..<end]))
            start = end
        }
        if start < text.endIndex { result.append(String(text[start...])) }
        return result
    }

    nonisolated private static func textLength(_ block: ReadBoardMarkdownBlock) -> Int {
        switch block {
        case .heading(_, let text), .paragraph(let text), .quote(let text),
             .frontmatter(let text):
            text.count
        case .listItem(_, _, let text):
            text.count
        case .codeBlock(_, let code):
            code.count
        case .image(let alt, let url):
            alt.count + url.count
        case .divider:
            0
        }
    }

    nonisolated private static func isTextFlow(_ block: ReadBoardMarkdownBlock) -> Bool {
        switch block {
        case .heading, .paragraph, .listItem: true
        case .quote, .codeBlock, .divider, .image, .frontmatter: false
        }
    }

    private func attributedTextFlow(_ blocks: [ReadBoardMarkdownBlock]) -> AttributedString {
        var result = AttributedString()
        var previousWasList = false
        for (index, block) in blocks.enumerated() {
            let isList: Bool
            if case .listItem = block { isList = true } else { isList = false }
            if index > 0 {
                result.append(AttributedString(previousWasList && isList ? "\n" : "\n\n"))
            }
            switch block {
            case .heading(let level, let text):
                var heading = inline(text, fontSize: headingSize(level))
                heading.font = style.font(size: headingSize(level), weight: .bold)
                heading.foregroundColor = headingColor(level)
                result.append(heading)
            case .paragraph(let text):
                result.append(inline(text, fontSize: style.fontSize))
            case .listItem(let ordered, let itemIndex, let text):
                var marker = AttributedString(ordered ? "\(itemIndex).  " : "•  ")
                marker.font = style.font()
                marker.foregroundColor = style.palette.listMarker
                result.append(marker)
                result.append(inline(text, fontSize: style.fontSize))
            case .quote, .codeBlock, .divider, .image, .frontmatter:
                break
            }
            previousWasList = isList
        }
        return result
    }

    @ViewBuilder
    private func blockView(_ block: ReadBoardMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text, fontSize: headingSize(level)))
                .font(style.font(size: headingSize(level), weight: .bold))
                .foregroundStyle(headingColor(level))
                .padding(.top, level <= 2 ? 10 : 5)
        case .paragraph(let text):
            Text(inline(text, fontSize: style.fontSize))
                .font(style.font()).lineSpacing(style.lineSpacing)
        case .listItem(let ordered, let index, let text):
            HStack(alignment: .top, spacing: 8) {
                Text(ordered ? "\(index)." : "•")
                    .font(style.font()).foregroundStyle(style.palette.listMarker)
                    .frame(minWidth: 20, alignment: .trailing)
                Text(inline(text, fontSize: style.fontSize))
                    .font(style.font()).lineSpacing(style.lineSpacing)
            }
            .padding(.leading, 8)
        case .quote(let text):
            HStack(spacing: 0) {
                Rectangle().fill(style.palette.quoteBorder).frame(width: 3)
                Text(inline(text, fontSize: style.fontSize))
                    .font(style.font()).lineSpacing(style.lineSpacing)
                    .foregroundStyle(style.palette.quoteText)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(style.palette.backgroundAlt)
            .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md))
        case .codeBlock(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(style.font(design: .monospaced))
                    .foregroundStyle(style.palette.codeText).padding(12)
            }
            .background(style.palette.codeBackground)
            .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg)
                    .strokeBorder(style.palette.divider.opacity(0.6),
                                  lineWidth: ReadBoardDesign.Line.hair)
            }
        case .divider:
            Rectangle().fill(style.palette.divider).frame(height: ReadBoardDesign.Line.hair)
        case .image(let alt, let rawURL):
            if let url = resolvedURL(rawURL) {
                ReadBoardRemoteImage(url: url, alt: alt, palette: style.palette)
            } else {
                Label(alt.isEmpty ? "图片地址无效" : alt,
                      systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundStyle(style.palette.textFaint)
            }
        case .frontmatter(let text):
            ReadBoardFrontmatterBlock(text: text, palette: style.palette)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: style.fontSize + 10
        case 2: style.fontSize + 6
        case 3: style.fontSize + 3
        default: style.fontSize + 1
        }
    }

    private func headingColor(_ level: Int) -> Color {
        guard !style.palette.headings.isEmpty else { return style.palette.text }
        let index = min(max(level - 1, 0), style.palette.headings.count - 1)
        return style.palette.headings[index]
    }

    private func resolvedURL(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let absolute = URL(string: value), absolute.scheme != nil { return absolute }
        return baseURL.flatMap { URL(string: value, relativeTo: $0)?.absoluteURL }
    }

    private func inline(_ text: String, fontSize: CGFloat) -> AttributedString {
        var result = AttributedString()
        var buffer = ""
        var index = text.startIndex
        func flush() {
            guard !buffer.isEmpty else { return }
            var value = AttributedString(buffer)
            value.foregroundColor = style.palette.text
            result.append(value); buffer = ""
        }
        while index < text.endIndex {
            if text[index] == "[", let link = parseLink(text, from: index) {
                flush()
                var value = AttributedString(link.label)
                value.link = URL(string: link.url)
                value.foregroundColor = style.palette.link
                value.underlineStyle = .single
                result.append(value); index = link.end; continue
            }
            if text[index] == "`", let end = text[text.index(after: index)...].firstIndex(of: "`") {
                flush()
                var value = AttributedString(String(text[text.index(after: index)..<end]))
                value.font = style.font(size: fontSize, design: .monospaced)
                value.foregroundColor = style.palette.inlineCode
                value.backgroundColor = style.palette.inlineCodeBackground
                result.append(value); index = text.index(after: end); continue
            }
            if text[index] == "*", text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == "*",
               let end = findBoldClosing(text, from: text.index(index, offsetBy: 2)) {
                flush()
                var value = AttributedString(String(text[text.index(index, offsetBy: 2)..<end]))
                value.font = style.font(size: fontSize, weight: .bold)
                value.foregroundColor = style.palette.bold
                result.append(value); index = text.index(end, offsetBy: 2); continue
            }
            if text[index] == "*", text.index(after: index) < text.endIndex,
               text[text.index(after: index)] != "*",
               let end = text[text.index(after: index)...].firstIndex(of: "*") {
                let content = String(text[text.index(after: index)..<end])
                if !content.isEmpty {
                    flush()
                    var value = AttributedString(content)
                    value.font = style.font(size: fontSize).italic()
                    value.foregroundColor = style.palette.italic
                    result.append(value); index = text.index(after: end); continue
                }
            }
            buffer.append(text[index]); index = text.index(after: index)
        }
        flush()
        return result
    }

    private func parseLink(
        _ text: String, from: String.Index
    ) -> (label: String, url: String, end: String.Index)? {
        guard let closeBracket = text[from...].firstIndex(of: "]"),
              text.index(after: closeBracket) < text.endIndex,
              text[text.index(after: closeBracket)] == "(",
              let closeParenthesis = text[closeBracket...].firstIndex(of: ")") else { return nil }
        return (
            String(text[text.index(after: from)..<closeBracket]),
            String(text[text.index(closeBracket, offsetBy: 2)..<closeParenthesis]),
            text.index(after: closeParenthesis))
    }

    private func findBoldClosing(_ text: String, from: String.Index) -> String.Index? {
        var index = from
        while index < text.endIndex {
            if text[index] == "*", text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == "*" { return index }
            index = text.index(after: index)
        }
        return nil
    }
}

private struct ReadBoardFrontmatterBlock: View {
    let text: String
    let palette: ReadBoardMarkdownPalette
    @AppStorage("reading.metaExpanded") private var expanded = false

    private var fields: [(key: String, value: String)] {
        text.components(separatedBy: "\n").compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !isDebugNoise(value), let colon = value.firstIndex(of: ":") else { return nil }
            let key = String(value[..<colon]).trimmingCharacters(in: .whitespaces)
            var fieldValue = String(value[value.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if ((fieldValue.hasPrefix("'") && fieldValue.hasSuffix("'")) ||
                (fieldValue.hasPrefix("\"") && fieldValue.hasSuffix("\""))), fieldValue.count >= 2 {
                fieldValue = String(fieldValue.dropFirst().dropLast())
            }
            return (key, fieldValue)
        }
    }

    private func isDebugNoise(_ value: String) -> Bool {
        guard !value.isEmpty else { return true }
        if ["Cleaned URL:", "Fetching", "Fetched", "Pre-processing", "pre-processing"]
            .contains(where: value.hasPrefix) { return true }
        if value.contains("detected,") { return true }
        let timestamp = #"^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$"#
        return value.range(of: timestamp, options: .regularExpression) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.textFaint)
                        .frame(width: 12)
                    Text("文档信息")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.textFaint)
                    Text("· \(fields.count) 项")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textFaint.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(fields.indices, id: \.self) { index in
                        let field = fields[index]
                        HStack(alignment: .top, spacing: 8) {
                            Text(field.key)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(palette.textFaint)
                                .frame(width: 90, alignment: .trailing)
                            Text(field.value)
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textSecondary)
                                .lineLimit(field.key == "description" ? 3 : nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(palette.backgroundAlt.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md)
                .strokeBorder(palette.divider, lineWidth: ReadBoardDesign.Line.hair)
        }
    }
}

private struct ReadBoardRemoteImage: View {
    let url: URL
    let alt: String
    let palette: ReadBoardMarkdownPalette
    @State private var cgImage: CGImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cgImage {
                Image(decorative: cgImage, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md))
            } else if failed {
                Link(destination: url) {
                    Label(alt.isEmpty ? "查看图片" : alt, systemImage: "photo")
                        .font(.caption).foregroundStyle(palette.link)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("图片加载中…").font(.caption).foregroundStyle(palette.textFaint)
                }
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            }
            if cgImage != nil, !alt.isEmpty {
                Text(alt).font(.caption).foregroundStyle(palette.textFaint)
            }
        }
        .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        guard let box = await ReadBoardImagePipeline.shared.image(url: url, maxPixelSize: 2048) else {
            failed = true
            return
        }
        cgImage = box.image
    }
}

private final class ReadBoardImageBox: @unchecked Sendable {
    let image: CGImage
    let cost: Int

    init(image: CGImage) {
        self.image = image
        self.cost = image.bytesPerRow * image.height
    }
}

/// Core 与 Go 共用缓存和请求合并，避免多图文章重复下载或解码原始大图。
private actor ReadBoardImagePipeline {
    static let shared = ReadBoardImagePipeline()

    private let cache: NSCache<NSString, ReadBoardImageBox> = {
        let cache = NSCache<NSString, ReadBoardImageBox>()
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()
    private var inFlight: [String: Task<ReadBoardImageBox?, Never>] = [:]

    func image(url: URL, maxPixelSize: Int) async -> ReadBoardImageBox? {
        let key = "\(maxPixelSize)|\(url.absoluteString)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let running = inFlight[key] { return await running.value }

        let task: Task<ReadBoardImageBox?, Never> = Task.detached(priority: .utility) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Mozilla/5.0 (Macintosh) ReadBoard", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let response = response as? HTTPURLResponse,
                   !(200..<300).contains(response.statusCode) { return nil }
                return Self.downsample(data: data, maxPixelSize: maxPixelSize)
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { cache.setObject(result, forKey: key as NSString, cost: result.cost) }
        return result
    }

    nonisolated private static func downsample(
        data: Data, maxPixelSize: Int
    ) -> ReadBoardImageBox? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return ReadBoardImageBox(image: image)
    }
}
