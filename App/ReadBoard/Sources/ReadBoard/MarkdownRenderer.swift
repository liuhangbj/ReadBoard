import SwiftUI

// MARK: - Markdown 渲染器（阅读器正文）
// 按块解析 markdown 为结构化元素，主题化渲染。
// 覆盖阅读器常见元素：标题 1-4 / 段落（含行内加粗斜体链接）/ 无序有序列表 /
// 引用块 / 代码块 / 行内代码 / 分割线 / 图片（占位）。

/// 一个 markdown 块
enum MdBlock: Identifiable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case listItem(ordered: Bool, index: Int, text: String)
    case quote(text: String)
    case codeBlock(lang: String?, code: String)
    case divider
    case image(alt: String, url: String)

    var id: UUID { UUID() }
}

struct MarkdownRenderer {

    /// 把 markdown 文本解析成块序列
    static func parse(_ md: String) -> [MdBlock] {
        var blocks: [MdBlock] = []
        let lines = md.components(separatedBy: "\n")
        var i = 0
        var paraBuf: [String] = []        // 段落累积（连续非空行）
        var inCode = false
        var codeLang: String? = nil
        var codeBuf: [String] = []

        func flushPara() {
            let text = paraBuf.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(text: text)) }
            paraBuf = []
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            i += 1

            // 代码块围栏
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.codeBlock(lang: codeLang, code: codeBuf.joined(separator: "\n")))
                    codeBuf = []; codeLang = nil; inCode = false
                } else {
                    flushPara()
                    inCode = true
                    codeLang = line.count > 3 ? String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) : nil
                }
                continue
            }
            if inCode { codeBuf.append(raw); continue }

            // 空行：段落分隔
            if line.isEmpty { flushPara(); continue }

            // 分割线
            if line == "---" || line == "***" || line == "___" {
                flushPara(); blocks.append(.divider); continue
            }

            // 标题 #..######
            if let h = parseHeading(line) {
                flushPara(); blocks.append(h); continue
            }

            // 引用 >
            if line.hasPrefix(">") {
                flushPara()
                let q = line.dropFirst().trimmingCharacters(in: .whitespaces)
                blocks.append(.quote(text: String(q))); continue
            }

            // 图片 ![alt](url)
            if let img = parseImage(line) {
                flushPara(); blocks.append(img); continue
            }

            // 无序列表 -/*/+ 或有序 1.
            if let li = parseListItem(line) {
                flushPara(); blocks.append(li); continue
            }

            // 普通行：累积进段落
            paraBuf.append(line)
        }
        flushPara()
        if inCode, !codeBuf.isEmpty {
            blocks.append(.codeBlock(lang: codeLang, code: codeBuf.joined(separator: "\n")))
        }
        return blocks
    }

    private static func parseHeading(_ line: String) -> MdBlock? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6, line.count > level, line[line.index(line.startIndex, offsetBy: level)] == " " else { return nil }
        let text = String(line.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
        return .heading(level: min(level, 4), text: text)
    }

    private static func parseListItem(_ line: String) -> MdBlock? {
        // 无序：- / * / +
        if line.count > 2, ["- ", "* ", "+ "].contains(String(line.prefix(2))) {
            return .listItem(ordered: false, index: 0, text: String(line.dropFirst(2)))
        }
        // 有序：数字 + .
        if let dot = line.firstIndex(of: ".") {
            let numStr = String(line[line.startIndex..<dot])
            if let num = Int(numStr), line.count > dot.utf16Offset(in: line) + 1 {
                let rest = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return .listItem(ordered: true, index: num, text: rest) }
            }
        }
        return nil
    }

    private static func parseImage(_ line: String) -> MdBlock? {
        // ![alt](url) 独占一行才算图片块
        guard line.hasPrefix("!["), let closeAlt = line.firstIndex(of: "]"),
              line.count > closeAlt.utf16Offset(in: line) + 1,
              line[line.index(after: closeAlt)] == "(",
              line.hasSuffix(")") else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<closeAlt])
        let url = String(line[line.index(closeAlt, offsetBy: 2)..<line.index(before: line.endIndex)])
        return .image(alt: alt, url: url)
    }

    /// 行内样式：加粗 **x** / 斜体 *x* / 行内代码 `x` / 链接 [t](u)
    /// 返回 AttributedString（行内级渲染，供段落/列表项/标题用）。
    /// palette 提供各语义元素的着色；fontSize 让行内元素跟正文字号走
    /// （此前写死 .body/.body.bold() 系统语义字号 ~13pt，比用户设的正文字号小，
    ///  导致加粗/斜体/行内代码渲染出来字号明显变小）。
    static func inline(_ text: String, palette: ThemePalette? = nil, fontSize: CGFloat = 0) -> AttributedString {
        // fontSize=0 表示不指定（用系统默认，向后兼容旧调用）
        let boldFont: Font = fontSize > 0 ? .system(size: fontSize).bold() : .body.bold()
        let italicFont: Font = fontSize > 0 ? .system(size: fontSize).italic() : .body.italic()
        let codeFont: Font = fontSize > 0 ? .system(size: fontSize, design: .monospaced) : .system(.body, design: .monospaced)
        var result = AttributedString()
        var buf = ""
        var i = text.startIndex

        func flushBuf() {
            if !buf.isEmpty {
                var plain = AttributedString(buf)
                plain.foregroundColor = palette?.text
                result.append(plain); buf = ""
            }
        }

        while i < text.endIndex {
            // 链接 [text](url)
            if text[i] == "[", let (t, u, end) = parseLink(text, from: i) {
                flushBuf()
                var linkAttr = AttributedString(t)
                linkAttr.link = URL(string: u)
                linkAttr.foregroundColor = palette?.link ?? .accentColor
                linkAttr.underlineStyle = .single
                result.append(linkAttr)
                i = end
                continue
            }
            // 行内代码 `x`
            if text[i] == "`", let end = text[text.index(after: i)...].firstIndex(of: "`") {
                flushBuf()
                let code = String(text[text.index(after: i)..<end])
                var codeAttr = AttributedString(code)
                codeAttr.font = codeFont
                codeAttr.foregroundColor = palette?.inlineCode
                codeAttr.backgroundColor = palette?.inlineCodeBackground ?? Color.gray.opacity(0.18)
                result.append(codeAttr)
                i = text.index(after: end)
                continue
            }
            // 加粗 **x**
            if text[i] == "*", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "*",
               let close = findClosing(text, from: text.index(i, offsetBy: 2), marker: "**") {
                flushBuf()
                let bold = String(text[text.index(i, offsetBy: 2)..<close])
                var boldAttr = AttributedString(bold)
                boldAttr.font = boldFont
                boldAttr.foregroundColor = palette?.bold
                result.append(boldAttr)
                i = text.index(close, offsetBy: 2)
                continue
            }
            // 斜体 *x*（单星号，非双）
            if text[i] == "*", text.index(after: i) < text.endIndex, text[text.index(after: i)] != "*",
               let close = text[text.index(after: i)...].firstIndex(of: "*") {
                flushBuf()
                let em = String(text[text.index(after: i)..<close])
                if !em.isEmpty {
                    var emAttr = AttributedString(em)
                    emAttr.font = italicFont
                    emAttr.foregroundColor = palette?.italic
                    result.append(emAttr)
                    i = text.index(after: close)
                    continue
                }
            }
            buf.append(text[i])
            i = text.index(after: i)
        }
        flushBuf()
        return result
    }

    private static func parseLink(_ text: String, from: String.Index) -> (String, String, String.Index)? {
        guard let closeB = text[from...].firstIndex(of: "]"),
              text.index(after: closeB) < text.endIndex, text[text.index(after: closeB)] == "(",
              let closeP = text[closeB...].firstIndex(of: ")") else { return nil }
        let t = String(text[text.index(after: from)..<closeB])
        let u = String(text[text.index(closeB, offsetBy: 2)..<closeP])
        return (t, u, text.index(after: closeP))
    }

    private static func findClosing(_ text: String, from: String.Index, marker: String) -> String.Index? {
        var i = from
        while i < text.endIndex {
            if text[i] == "*", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "*" {
                return i
            }
            i = text.index(after: i)
        }
        return nil
    }
}
