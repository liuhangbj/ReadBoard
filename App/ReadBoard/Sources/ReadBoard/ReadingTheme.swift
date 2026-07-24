import SwiftUI

// MARK: - 阅读器主题（颜色规范抄自 Obsidian 主题）
// 每套主题是一个完整的颜色系统，渲染器的每个元素（标题层级/正文/引用/
// 加粗/斜体/行内代码/代码块/列表标记/分割线/链接）都从主题取色，不是只配背景文字。
//
// Things 主题颜色规范（colineckert/obsidian-things）：
//   named palette: blue #2e80f2 / pink #ff82b2 / green #3eb4bf / yellow #e5b567
//                  orange #e87d3e / red #e83e3e / purple #9e86c8
//   dark bg: 深蓝灰，文字 #D3CECA 系；粗体/斜体 pink，引用 green，行内代码灰
// Claude 风格：暖白纸感底，深棕灰字，衬线标题，赭橙 accent

struct ThemePalette {
    // 底色
    let background: Color
    let backgroundAlt: Color        // 引用块/摘要块底
    let codeBackground: Color
    let inlineCodeBackground: Color
    // 文字
    let text: Color
    let textSecondary: Color        // 元信息/摘要
    let textFaint: Color            // 更弱（分割线/caption）
    // 标题层级（h1-h4 可不同色）
    let h1: Color
    let h2: Color
    let h3: Color
    let h4: Color
    // 行内语义
    let bold: Color
    let italic: Color
    let inlineCode: Color
    let link: Color
    // 块级
    let quoteBorder: Color
    let quoteText: Color
    let listMarker: Color
    let divider: Color
    // 代码块内（语法色简化：注释/字符串/关键字/数字/普通）
    let codeText: Color
    let codeKeyword: Color
    let codeString: Color
    let codeComment: Color
    let codeNumber: Color

    let headingSerif: Bool
}

enum ReadingTheme: String, CaseIterable, Identifiable {
    case claude
    case things
    case systemDefault

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .things: return "Things"
        case .systemDefault: return "系统默认"
        }
    }

    var palette: ThemePalette {
        switch self {
        case .claude:
            // Claude 风格：暖白纸感 + 深棕灰 + 赭橙 accent + 衬线标题
            return ThemePalette(
                background: Color(red: 0.976, green: 0.965, blue: 0.949),   // #F9F6F2
                backgroundAlt: Color(red: 0.945, green: 0.929, blue: 0.902), // #F1EDE6
                codeBackground: Color(red: 0.937, green: 0.922, blue: 0.894),
                inlineCodeBackground: Color(red: 0.92, green: 0.90, blue: 0.87),
                text: Color(red: 0.208, green: 0.184, blue: 0.161),          // #352F29
                textSecondary: Color(red: 0.42, green: 0.39, blue: 0.35),
                textFaint: Color(red: 0.58, green: 0.55, blue: 0.51),
                h1: Color(red: 0.15, green: 0.13, blue: 0.11),
                h2: Color(red: 0.22, green: 0.19, blue: 0.16),
                h3: Color(red: 0.30, green: 0.26, blue: 0.22),
                h4: Color(red: 0.38, green: 0.34, blue: 0.29),
                bold: Color(red: 0.62, green: 0.28, blue: 0.14),             // 赭棕
                italic: Color(red: 0.50, green: 0.32, blue: 0.22),
                inlineCode: Color(red: 0.65, green: 0.30, blue: 0.16),
                link: Color(red: 0.72, green: 0.33, blue: 0.18),             // 赭橙
                quoteBorder: Color(red: 0.72, green: 0.35, blue: 0.20),
                quoteText: Color(red: 0.40, green: 0.36, blue: 0.31),
                listMarker: Color(red: 0.72, green: 0.35, blue: 0.20),
                divider: Color(red: 0.80, green: 0.77, blue: 0.73),
                codeText: Color(red: 0.25, green: 0.22, blue: 0.19),
                codeKeyword: Color(red: 0.62, green: 0.25, blue: 0.30),
                codeString: Color(red: 0.35, green: 0.50, blue: 0.25),
                codeComment: Color(red: 0.55, green: 0.52, blue: 0.48),
                codeNumber: Color(red: 0.65, green: 0.45, blue: 0.15),
                headingSerif: true
            )
        case .things:
            // Things 主题（obsidian-things 深色）：named palette 直接抄
            return ThemePalette(
                background: Color(red: 0.141, green: 0.157, blue: 0.196),    // #242832 深蓝灰
                backgroundAlt: Color(red: 0.113, green: 0.125, blue: 0.161), // 更深 #1D2029
                codeBackground: Color(red: 0.098, green: 0.110, blue: 0.145),
                inlineCodeBackground: Color(red: 0.20, green: 0.22, blue: 0.27),
                text: Color(red: 0.827, green: 0.808, blue: 0.792),          // #D3CECA
                textSecondary: Color(red: 0.55, green: 0.57, blue: 0.62),
                textFaint: Color(red: 0.42, green: 0.45, blue: 0.51),
                h1: Color(red: 0.937, green: 0.925, blue: 0.910),            // 近白
                h2: Color(red: 0.18, green: 0.50, blue: 0.95),               // blue #2e80f2
                h3: Color(red: 0.18, green: 0.50, blue: 0.95),               // H3 blue
                h4: Color(red: 0.898, green: 0.710, blue: 0.404),            // yellow #e5b567
                bold: Color(red: 1.0, green: 0.510, blue: 0.698),            // pink #ff82b2
                italic: Color(red: 1.0, green: 0.510, blue: 0.698),          // pink
                inlineCode: Color(red: 0.745, green: 0.78, blue: 0.81),      // 浅灰 #BEC6CF
                link: Color(red: 0.18, green: 0.50, blue: 0.95),             // blue
                quoteBorder: Color(red: 0.243, green: 0.706, blue: 0.749),   // green #3eb4bf
                quoteText: Color(red: 0.243, green: 0.706, blue: 0.749),     // 引用 green
                listMarker: Color(red: 0.243, green: 0.706, blue: 0.749),    // green
                divider: Color(red: 0.30, green: 0.32, blue: 0.38),
                codeText: Color(red: 0.827, green: 0.808, blue: 0.792),
                codeKeyword: Color(red: 0.78, green: 0.47, blue: 0.87),      // purple-ish
                codeString: Color(red: 0.60, green: 0.76, blue: 0.47),       // atom green
                codeComment: Color(red: 0.42, green: 0.45, blue: 0.51),      // atom gray
                codeNumber: Color(red: 0.82, green: 0.60, blue: 0.40),       // atom orange
                headingSerif: false
            )
        case .systemDefault:
            return ThemePalette(
                background: Color(nsColor: .textBackgroundColor),
                backgroundAlt: Color.gray.opacity(0.10),
                codeBackground: Color.gray.opacity(0.14),
                inlineCodeBackground: Color.gray.opacity(0.16),
                text: Color(nsColor: .textColor),
                textSecondary: .secondary,
                textFaint: Color(nsColor: .tertiaryLabelColor),
                h1: Color(nsColor: .textColor),
                h2: Color(nsColor: .textColor),
                h3: Color(nsColor: .textColor),
                h4: Color(nsColor: .textColor),
                bold: Color(nsColor: .textColor),
                italic: Color(nsColor: .textColor),
                inlineCode: Color(nsColor: .textColor),
                link: .accentColor,
                quoteBorder: .accentColor,
                quoteText: .secondary,
                listMarker: .accentColor,
                divider: Color.gray.opacity(0.4),
                codeText: Color(nsColor: .textColor),
                codeKeyword: .accentColor,
                codeString: .green,
                codeComment: .secondary,
                codeNumber: .orange,
                headingSerif: false
            )
        }
    }

    static var current: ReadingTheme {
        get {
            let raw = UserDefaults.standard.string(forKey: "reading.theme") ?? "claude"
            return ReadingTheme(rawValue: raw) ?? .claude
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "reading.theme") }
    }
}

// MARK: - 正文字体选择

enum ReadingFont: String, CaseIterable, Identifiable {
    case system, serif, sansSerif, mono

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "系统默认"
        case .serif: return "衬线（宋）"
        case .sansSerif: return "无衬线（黑）"
        case .mono: return "等宽"
        }
    }

    func font(size: CGFloat) -> Font {
        switch self {
        case .system: return .system(size: size)
        case .serif: return .system(size: size, design: .serif)
        case .sansSerif: return .system(size: size, design: .default)
        case .mono: return .system(size: size, design: .monospaced)
        }
    }

    static var current: ReadingFont {
        get {
            let raw = UserDefaults.standard.string(forKey: "reading.font") ?? "system"
            return ReadingFont(rawValue: raw) ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "reading.font") }
    }
}

// MARK: - Markdown 正文视图（按主题 palette 全元素着色）

struct MarkdownBodyView: View {
    let markdown: String
    let theme: ReadingTheme
    let fontChoice: ReadingFont
    let fontSize: Double
    let lineSpacing: Double

    @State private var blocks: [MdBlock] = []

    private var p: ThemePalette { theme.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .onAppear { blocks = MarkdownRenderer.parse(markdown) }
        .onChange(of: markdown) { _, v in blocks = MarkdownRenderer.parse(v) }
    }

    @ViewBuilder
    private func blockView(_ block: MdBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownRenderer.inline(text, palette: p))
                .font(headingFont(level))
                .foregroundStyle(headingColor(level))
                .padding(.top, level <= 2 ? 10 : 5)

        case .paragraph(let text):
            Text(MarkdownRenderer.inline(text, palette: p))
                .font(fontChoice.font(size: fontSize))
                .lineSpacing(lineSpacing)

        case .listItem(let ordered, let index, let text):
            HStack(alignment: .top, spacing: 8) {
                Text(ordered ? "\(index)." : "•")
                    .font(fontChoice.font(size: fontSize))
                    .foregroundStyle(p.listMarker)
                    .frame(minWidth: 20, alignment: .trailing)
                Text(MarkdownRenderer.inline(text, palette: p))
                    .font(fontChoice.font(size: fontSize))
                    .lineSpacing(lineSpacing)
            }
            .padding(.leading, 8)

        case .quote(let text):
            HStack(spacing: 0) {
                Rectangle().fill(p.quoteBorder).frame(width: 3)
                Text(MarkdownRenderer.inline(text, palette: p))
                    .font(fontChoice.font(size: fontSize))
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(p.quoteText)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(p.backgroundAlt)
            .clipShape(RoundedRectangle(cornerRadius: 4))

        case .codeBlock(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundStyle(p.codeText)
                    .padding(12)
            }
            .background(p.codeBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .divider:
            Rectangle().fill(p.divider).frame(height: 1)

        case .image(let alt, let url):
            VStack(alignment: .leading, spacing: 4) {
                AsyncImage(url: URL(string: url)) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fit)
                    case .failure: Label("图片加载失败", systemImage: "photo").foregroundStyle(p.textFaint)
                    case .empty: ProgressView()
                    @unknown default: EmptyView()
                    }
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                if !alt.isEmpty {
                    Text(alt).font(.caption).foregroundStyle(p.textFaint)
                }
            }
        }
    }

    private func headingColor(_ level: Int) -> Color {
        switch level {
        case 1: return p.h1
        case 2: return p.h2
        case 3: return p.h3
        default: return p.h4
        }
    }

    private func headingFont(_ level: Int) -> Font {
        let base: CGFloat
        switch level {
        case 1: base = fontSize + 10
        case 2: base = fontSize + 6
        case 3: base = fontSize + 3
        default: base = fontSize + 1
        }
        return p.headingSerif ? .system(size: base, design: .serif).bold() : .system(size: base).bold()
    }
}
