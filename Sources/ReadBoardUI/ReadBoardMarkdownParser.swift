import Foundation

public enum ReadBoardMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case listItem(ordered: Bool, index: Int, text: String)
    case quote(text: String)
    case codeBlock(lang: String?, code: String)
    case divider
    case image(alt: String, url: String)
    case frontmatter(text: String)
}

/// Core 与 Go 共用的 Markdown 分块器。任何兼容性修复只能进入这里，不能在客户端再分叉。
public enum ReadBoardMarkdownParser {
    public static func parse(_ markdown: String) -> [ReadBoardMarkdownBlock] {
        var blocks: [ReadBoardMarkdownBlock] = []
        let lines = stripLeadingFrontmatter(
            lines: markdown.components(separatedBy: "\n"), into: &blocks)
        var paragraph: [(text: String, hardBreakAfter: Bool)] = []
        var code: [String] = []
        var codeLanguage: String?
        var isInCodeBlock = false

        func flushParagraph() {
            var text = ""
            for index in paragraph.indices {
                if index > paragraph.startIndex {
                    let previous = paragraph[paragraph.index(before: index)]
                    text += previous.hardBreakAfter ? "\n" : " "
                }
                text += paragraph[index].text
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text: text)) }
            paragraph = []
        }

        for raw in lines {
            let hasMarkdownHardBreak = raw.hasSuffix("  ")
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if isInCodeBlock {
                    blocks.append(.codeBlock(lang: codeLanguage, code: code.joined(separator: "\n")))
                    code = []; codeLanguage = nil; isInCodeBlock = false
                } else {
                    flushParagraph()
                    isInCodeBlock = true
                    let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                }
                continue
            }
            if isInCodeBlock { code.append(raw); continue }
            if line.isEmpty { flushParagraph(); continue }
            if ["---", "***", "___"].contains(line) {
                flushParagraph(); blocks.append(.divider); continue
            }
            if let heading = parseHeading(line) {
                flushParagraph(); blocks.append(heading); continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(text: String(line.dropFirst())
                    .trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let images = parseStandaloneImages(line) {
                flushParagraph(); blocks.append(contentsOf: images); continue
            }
            if let listItem = parseListItem(line) {
                flushParagraph(); blocks.append(listItem); continue
            }
            paragraph.append((text: line, hardBreakAfter: hasMarkdownHardBreak))
        }
        flushParagraph()
        if isInCodeBlock, !code.isEmpty {
            blocks.append(.codeBlock(lang: codeLanguage, code: code.joined(separator: "\n")))
        }
        return blocks
    }

    private static func parseHeading(_ line: String) -> ReadBoardMarkdownBlock? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level), line.count > level else { return nil }
        let separator = line.index(line.startIndex, offsetBy: level)
        guard line[separator] == " " else { return nil }
        return .heading(
            level: min(level, 4),
            text: String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces))
    }

    private static func parseListItem(_ line: String) -> ReadBoardMarkdownBlock? {
        if line.count > 2, ["- ", "* ", "+ "].contains(String(line.prefix(2))) {
            return .listItem(ordered: false, index: 0, text: String(line.dropFirst(2)))
        }
        guard let dot = line.firstIndex(of: "."), let index = Int(line[..<dot]) else { return nil }
        let text = String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .listItem(ordered: true, index: index, text: text)
    }

    private static func parseStandaloneImages(_ line: String) -> [ReadBoardMarkdownBlock]? {
        let markdownPattern = #"!\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^\s\)]+))(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^\)]*\)))?\s*\)"#
        if let regex = try? NSRegularExpression(pattern: markdownPattern),
           let images = markdownImageBlocks(
               matches: regex.matches(in: line, range: NSRange(line.startIndex..., in: line)),
               source: line), !images.isEmpty {
            return images
        }

        guard let htmlRegex = try? NSRegularExpression(
            pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive]) else { return nil }
        let matches = htmlRegex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        guard onlyWhitespaceOutside(matches: matches, in: line), !matches.isEmpty else { return nil }
        let source = line as NSString
        let images = matches.compactMap { match -> ReadBoardMarkdownBlock? in
            let tag = source.substring(with: match.range)
            guard let url = htmlAttribute("src", in: tag), !url.isEmpty else { return nil }
            return .image(
                alt: decodeHTMLEntities(htmlAttribute("alt", in: tag) ?? ""),
                url: decodeHTMLEntities(url))
        }
        return images.isEmpty ? nil : images
    }

    private static func markdownImageBlocks(
        matches: [NSTextCheckingResult], source: String
    ) -> [ReadBoardMarkdownBlock]? {
        guard onlyWhitespaceOutside(matches: matches, in: source), !matches.isEmpty else { return nil }
        let text = source as NSString
        return matches.compactMap { match in
            let alt = text.substring(with: match.range(at: 1))
            let url = [2, 3].compactMap { group -> String? in
                let range = match.range(at: group)
                return range.location == NSNotFound ? nil : text.substring(with: range)
            }.first
            guard let url, !url.isEmpty else { return nil }
            return .image(alt: decodeHTMLEntities(alt), url: decodeHTMLEntities(url))
        }
    }

    private static func onlyWhitespaceOutside(
        matches: [NSTextCheckingResult], in line: String
    ) -> Bool {
        guard !matches.isEmpty else { return false }
        let source = line as NSString
        var cursor = 0
        for match in matches {
            guard match.range.location >= cursor else { return false }
            let gap = NSRange(location: cursor, length: match.range.location - cursor)
            if !source.substring(with: gap).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            cursor = NSMaxRange(match.range)
        }
        let tail = NSRange(location: cursor, length: source.length - cursor)
        return source.substring(with: tail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func htmlAttribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) +
            #"\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else {
            return nil
        }
        let source = tag as NSString
        for group in 1...3 {
            let range = match.range(at: group)
            if range.location != NSNotFound { return source.substring(with: range) }
        }
        return nil
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func stripLeadingFrontmatter(
        lines: [String], into blocks: inout [ReadBoardMarkdownBlock]
    ) -> [String] {
        guard !lines.isEmpty else { return lines }
        var yamlStart: Int?
        for index in 0..<min(lines.count, 6)
        where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
            yamlStart = index; break
        }
        guard let yamlStart else { return lines }
        var yamlEnd: Int?
        if yamlStart + 1 < min(lines.count, 46) {
            for index in (yamlStart + 1)..<min(lines.count, 46)
            where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                yamlEnd = index; break
            }
        }
        guard let yamlEnd, yamlEnd > yamlStart else { return lines }
        let yamlLines = Array(lines[(yamlStart + 1)..<yamlEnd])
        guard yamlLines.filter({ $0.contains(":") }).count >= 2 else { return lines }

        var metadata = lines[..<yamlStart]
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        metadata.append(contentsOf: yamlLines.map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty })
        var consumedEnd = yamlEnd
        var next = yamlEnd + 1
        while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
            next += 1
        }
        if next < lines.count, isTimestamp(lines[next].trimmingCharacters(in: .whitespaces)) {
            metadata.append(lines[next].trimmingCharacters(in: .whitespaces))
            consumedEnd = next
        }
        if !metadata.isEmpty { blocks.append(.frontmatter(text: metadata.joined(separator: "\n"))) }
        guard consumedEnd + 1 < lines.count else { return [] }
        return Array(lines[(consumedEnd + 1)...])
    }

    private static func isTimestamp(_ value: String) -> Bool {
        value.range(
            of: #"^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$"#,
            options: .regularExpression) != nil
    }
}
