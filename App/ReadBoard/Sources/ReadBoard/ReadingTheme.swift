import SwiftUI

// MARK: - 阅读器主题
// 内置几套主题：Claude 风格（暖白底+深灰字+衬线标题）、
// Obsidian Things 主题风格（深蓝灰底+亮 accent）。持久化选择。

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

    // MARK: 颜色
    var background: Color {
        switch self {
        case .claude: return Color(red: 0.98, green: 0.97, blue: 0.95)      // 暖白 #F9F7F2
        case .things: return Color(red: 0.13, green: 0.16, blue: 0.22)      // 深蓝灰 #212937
        case .systemDefault: return Color(nsColor: .textBackgroundColor)
        }
    }
    var text: Color {
        switch self {
        case .claude: return Color(red: 0.20, green: 0.18, blue: 0.16)      // 深灰 #332E29
        case .things: return Color(red: 0.85, green: 0.88, blue: 0.92)      // 亮灰 #D9E0EA
        case .systemDefault: return Color(nsColor: .textColor)
        }
    }
    var secondaryText: Color {
        switch self {
        case .claude: return Color(red: 0.45, green: 0.42, blue: 0.38)
        case .things: return Color(red: 0.55, green: 0.60, blue: 0.68)
        case .systemDefault: return .secondary
        }
    }
    var accent: Color {
        switch self {
        case .claude: return Color(red: 0.75, green: 0.35, blue: 0.20)      // 赭橙 #C05933
        case .things: return Color(red: 0.35, green: 0.65, blue: 0.95)      // 亮蓝 #59A6F2
        case .systemDefault: return .accentColor
        }
    }
    var quoteBackground: Color {
        switch self {
        case .claude: return Color(red: 0.94, green: 0.92, blue: 0.88)
        case .things: return Color(red: 0.18, green: 0.22, blue: 0.30)
        case .systemDefault: return Color.gray.opacity(0.12)
        }
    }
    var codeBackground: Color {
        switch self {
        case .claude: return Color(red: 0.93, green: 0.91, blue: 0.87)
        case .things: return Color(red: 0.10, green: 0.12, blue: 0.18)
        case .systemDefault: return Color.gray.opacity(0.15)
        }
    }

    /// 标题是否用衬线（Claude 风格衬线标题）
    var headingSerif: Bool { self == .claude }

    // MARK: 持久化
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
    case system
    case serif
    case sansSerif
    case mono

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

// MARK: - Markdown 正文视图（主题化渲染）

struct MarkdownBodyView: View {
    let markdown: String
    let theme: ReadingTheme
    let fontChoice: ReadingFont
    let fontSize: Double
    let lineSpacing: Double

    @State private var blocks: [MdBlock] = []

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
            Text(MarkdownRenderer.inline(text))
                .font(headingFont(level))
                .foregroundStyle(theme.text)
                .padding(.top, level <= 2 ? 8 : 4)

        case .paragraph(let text):
            Text(MarkdownRenderer.inline(text))
                .font(fontChoice.font(size: fontSize))
                .lineSpacing(lineSpacing)
                .foregroundStyle(theme.text)

        case .listItem(let ordered, let index, let text):
            HStack(alignment: .top, spacing: 8) {
                Text(ordered ? "\(index)." : "•")
                    .font(fontChoice.font(size: fontSize))
                    .foregroundStyle(theme.accent)
                    .frame(minWidth: 20, alignment: .trailing)
                Text(MarkdownRenderer.inline(text))
                    .font(fontChoice.font(size: fontSize))
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(theme.text)
            }
            .padding(.leading, 8)

        case .quote(let text):
            HStack(spacing: 0) {
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: 3)
                Text(MarkdownRenderer.inline(text))
                    .font(fontChoice.font(size: fontSize))
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .background(theme.quoteBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))

        case .codeBlock(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .padding(12)
            }
            .background(theme.codeBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .divider:
            Divider().background(theme.secondaryText.opacity(0.4))

        case .image(let alt, let url):
            VStack(alignment: .leading, spacing: 4) {
                AsyncImage(url: URL(string: url)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fit)
                    case .failure:
                        Label("图片加载失败", systemImage: "photo")
                            .foregroundStyle(theme.secondaryText)
                    case .empty:
                        ProgressView()
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                if !alt.isEmpty {
                    Text(alt).font(.caption).foregroundStyle(theme.secondaryText)
                }
            }
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
        return theme.headingSerif
            ? .system(size: base, design: .serif).bold()
            : .system(size: base).bold()
    }
}
