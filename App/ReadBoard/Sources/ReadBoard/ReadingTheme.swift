import SwiftUI
import AppKit

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
        case .claude: return "Primary"
        case .things: return "Things"
        case .systemDefault: return "系统默认"
        }
    }

    /// 亮/暗模式（持久化）：亮色 / 暗色 / 跟随系统
    enum Mode: String, CaseIterable, Identifiable {
        case light, dark, system
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .light: return "亮色"
            case .dark: return "暗色"
            case .system: return "跟随系统"
            }
        }
        static var current: Mode {
            get {
                let raw = UserDefaults.standard.string(forKey: "reading.themeMode") ?? "system"
                return Mode(rawValue: raw) ?? .system
            }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: "reading.themeMode") }
        }
    }

    /// 当前主题的 palette（按亮暗模式取对应变体；system 模式读系统外观）
    var palette: ThemePalette {
        palette(for: Mode.current)
    }

    func palette(for mode: Mode) -> ThemePalette {
        // system 模式读系统外观（亮色/暗色）
        let effectiveMode: Mode = mode == .system ? Self.systemAppearance() : mode
        switch (self, effectiveMode) {
        case (.claude, .light), (.claude, .system): return Self.primaryLight
        case (.claude, .dark): return Self.primaryDark
        case (.things, .light), (.things, .system): return Self.thingsLight
        case (.things, .dark): return Self.thingsDark
        case (.systemDefault, _): return Self.systemPalette
        }
    }

    /// 读系统外观（亮色/暗色）
    private static func systemAppearance() -> Mode {
        let appearance = NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    // MARK: Primary（ceciliamay/obsidian-primary）——Bauhaus 红黄蓝 + 泛黄杂志

    /// Primary 浅色：泛黄杂志底 + 暖深棕字 + 红黄蓝语义
    static let primaryLight = ThemePalette(
        background: Color(red: 0.965, green: 0.945, blue: 0.894),    // #F6F1E4
        backgroundAlt: Color(red: 0.937, green: 0.910, blue: 0.847),
        codeBackground: Color(red: 0.929, green: 0.898, blue: 0.831),
        inlineCodeBackground: Color(red: 0.910, green: 0.878, blue: 0.812),
        text: Color(red: 0.286, green: 0.247, blue: 0.208),          // #493F35
        textSecondary: Color(red: 0.482, green: 0.435, blue: 0.376),
        textFaint: Color(red: 0.639, green: 0.596, blue: 0.533),
        h1: Color(red: 0.220, green: 0.184, blue: 0.149),
        h2: Color(red: 0.769, green: 0.263, blue: 0.220),            // 红
        h3: Color(red: 0.227, green: 0.471, blue: 0.678),            // 蓝
        h4: Color(red: 0.788, green: 0.596, blue: 0.180),            // 黄
        bold: Color(red: 0.769, green: 0.263, blue: 0.220),
        italic: Color(red: 0.227, green: 0.471, blue: 0.678),
        inlineCode: Color(red: 0.769, green: 0.263, blue: 0.220),
        link: Color(red: 0.788, green: 0.596, blue: 0.180),
        quoteBorder: Color(red: 0.227, green: 0.471, blue: 0.678),
        quoteText: Color(red: 0.435, green: 0.384, blue: 0.322),
        listMarker: Color(red: 0.769, green: 0.263, blue: 0.220),
        divider: Color(red: 0.839, green: 0.800, blue: 0.729),
        codeText: Color(red: 0.286, green: 0.247, blue: 0.208),
        codeKeyword: Color(red: 0.769, green: 0.263, blue: 0.220),
        codeString: Color(red: 0.345, green: 0.553, blue: 0.310),
        codeComment: Color(red: 0.639, green: 0.596, blue: 0.533),
        codeNumber: Color(red: 0.788, green: 0.596, blue: 0.180),
        headingSerif: true
    )

    /// Primary 深色：暖棕暗底 + 米黄字 + 柔化红黄蓝（降低饱和度护眼）
    static let primaryDark = ThemePalette(
        background: Color(red: 0.145, green: 0.125, blue: 0.098),    // #251F19 暖棕暗底
        backgroundAlt: Color(red: 0.110, green: 0.094, blue: 0.074),
        codeBackground: Color(red: 0.090, green: 0.078, blue: 0.063),
        inlineCodeBackground: Color(red: 0.22, green: 0.19, blue: 0.15),
        text: Color(red: 0.878, green: 0.847, blue: 0.796),          // #E0D8CB 米黄
        textSecondary: Color(red: 0.62, green: 0.58, blue: 0.52),
        textFaint: Color(red: 0.47, green: 0.44, blue: 0.39),
        h1: Color(red: 0.945, green: 0.925, blue: 0.890),            // 近白米
        h2: Color(red: 0.898, green: 0.478, blue: 0.435),            // 柔红 #E57A70
        h3: Color(red: 0.549, green: 0.720, blue: 0.878),            // 柔蓝 #8CB8E0
        h4: Color(red: 0.898, green: 0.761, blue: 0.478),            // 柔黄 #E5C27A
        bold: Color(red: 0.898, green: 0.478, blue: 0.435),
        italic: Color(red: 0.549, green: 0.720, blue: 0.878),
        inlineCode: Color(red: 0.898, green: 0.620, blue: 0.478),    // 柔橙红
        link: Color(red: 0.898, green: 0.761, blue: 0.478),
        quoteBorder: Color(red: 0.549, green: 0.720, blue: 0.878),
        quoteText: Color(red: 0.70, green: 0.66, blue: 0.60),
        listMarker: Color(red: 0.898, green: 0.478, blue: 0.435),
        divider: Color(red: 0.32, green: 0.28, blue: 0.23),
        codeText: Color(red: 0.878, green: 0.847, blue: 0.796),
        codeKeyword: Color(red: 0.898, green: 0.478, blue: 0.435),
        codeString: Color(red: 0.643, green: 0.796, blue: 0.549),    // 柔绿
        codeComment: Color(red: 0.47, green: 0.44, blue: 0.39),
        codeNumber: Color(red: 0.898, green: 0.761, blue: 0.478),
        headingSerif: true
    )

    // MARK: Things（colineckert/obsidian-things）——named palette

    /// Things 深色：深蓝灰底 + named palette（blue/pink/green/yellow）
    static let thingsDark = ThemePalette(
        background: Color(red: 0.141, green: 0.157, blue: 0.196),    // #242832
        backgroundAlt: Color(red: 0.113, green: 0.125, blue: 0.161),
        codeBackground: Color(red: 0.098, green: 0.110, blue: 0.145),
        inlineCodeBackground: Color(red: 0.20, green: 0.22, blue: 0.27),
        text: Color(red: 0.827, green: 0.808, blue: 0.792),          // #D3CECA
        textSecondary: Color(red: 0.55, green: 0.57, blue: 0.62),
        textFaint: Color(red: 0.42, green: 0.45, blue: 0.51),
        h1: Color(red: 0.937, green: 0.925, blue: 0.910),
        h2: Color(red: 0.18, green: 0.50, blue: 0.95),               // blue #2e80f2
        h3: Color(red: 0.18, green: 0.50, blue: 0.95),
        h4: Color(red: 0.898, green: 0.710, blue: 0.404),            // yellow #e5b567
        bold: Color(red: 1.0, green: 0.510, blue: 0.698),            // pink #ff82b2
        italic: Color(red: 1.0, green: 0.510, blue: 0.698),
        inlineCode: Color(red: 0.745, green: 0.78, blue: 0.81),
        link: Color(red: 0.18, green: 0.50, blue: 0.95),
        quoteBorder: Color(red: 0.243, green: 0.706, blue: 0.749),   // green #3eb4bf
        quoteText: Color(red: 0.243, green: 0.706, blue: 0.749),
        listMarker: Color(red: 0.243, green: 0.706, blue: 0.749),
        divider: Color(red: 0.30, green: 0.32, blue: 0.38),
        codeText: Color(red: 0.827, green: 0.808, blue: 0.792),
        codeKeyword: Color(red: 0.78, green: 0.47, blue: 0.87),
        codeString: Color(red: 0.60, green: 0.76, blue: 0.47),
        codeComment: Color(red: 0.42, green: 0.45, blue: 0.51),
        codeNumber: Color(red: 0.82, green: 0.60, blue: 0.40),
        headingSerif: false
    )

    /// Things 浅色：白底 + named palette 同色（浅色下加深保证对比度）
    static let thingsLight = ThemePalette(
        background: Color(red: 0.996, green: 0.996, blue: 0.992),    // #FEFEFD 近白
        backgroundAlt: Color(red: 0.949, green: 0.953, blue: 0.961),
        codeBackground: Color(red: 0.937, green: 0.941, blue: 0.949),
        inlineCodeBackground: Color(red: 0.898, green: 0.906, blue: 0.918),
        text: Color(red: 0.220, green: 0.243, blue: 0.278),          // #383E47
        textSecondary: Color(red: 0.45, green: 0.48, blue: 0.53),
        textFaint: Color(red: 0.62, green: 0.65, blue: 0.69),
        h1: Color(red: 0.13, green: 0.15, blue: 0.18),
        h2: Color(red: 0.16, green: 0.45, blue: 0.85),               // blue 深一点
        h3: Color(red: 0.16, green: 0.45, blue: 0.85),
        h4: Color(red: 0.78, green: 0.58, blue: 0.20),               // yellow 深
        bold: Color(red: 0.88, green: 0.30, blue: 0.52),             // pink 深
        italic: Color(red: 0.88, green: 0.30, blue: 0.52),
        inlineCode: Color(red: 0.33, green: 0.36, blue: 0.42),
        link: Color(red: 0.16, green: 0.45, blue: 0.85),
        quoteBorder: Color(red: 0.20, green: 0.60, blue: 0.65),      // green 深
        quoteText: Color(red: 0.20, green: 0.55, blue: 0.60),
        listMarker: Color(red: 0.20, green: 0.60, blue: 0.65),
        divider: Color(red: 0.86, green: 0.87, blue: 0.89),
        codeText: Color(red: 0.220, green: 0.243, blue: 0.278),
        codeKeyword: Color(red: 0.65, green: 0.28, blue: 0.70),
        codeString: Color(red: 0.30, green: 0.60, blue: 0.30),
        codeComment: Color(red: 0.55, green: 0.58, blue: 0.62),
        codeNumber: Color(red: 0.78, green: 0.48, blue: 0.20),
        headingSerif: false
    )

    /// 系统默认
    static let systemPalette = ThemePalette(
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

    static var current: ReadingTheme {
        get {
            let raw = UserDefaults.standard.string(forKey: "reading.theme") ?? "claude"
            return ReadingTheme(rawValue: raw) ?? .claude
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "reading.theme") }
    }
}

// MARK: - 正文字体选择（预置中文字体 + 系统字体列表任选）

enum ReadingFont: Hashable {
    case system
    case heiti       // 黑体
    case kaiti       // 楷体
    case fangsong    // 仿宋
    case custom(String)   // 系统已装字体族名（从列表选）

    var displayName: String {
        switch self {
        case .system: return "系统默认"
        case .heiti: return "黑体"
        case .kaiti: return "楷体"
        case .fangsong: return "仿宋"
        case .custom(let name): return name
        }
    }

    /// 预置项（自定义走系统字体列表）
    static let presets: [ReadingFont] = [.system, .heiti, .kaiti, .fangsong]

    /// 预置对应的系统字体族候选名（取系统里实际存在的）
    private var presetFamilyCandidates: [String] {
        switch self {
        case .heiti: return ["Heiti SC", "STHeiti", "PingFang SC"]
        case .kaiti: return ["Kaiti SC", "STKaiti", "Kai"]
        case .fangsong: return ["STFangsong", "FangSong", "FangSong_GB2312"]
        default: return []
        }
    }

    func font(size: CGFloat) -> Font {
        switch self {
        case .system:
            return .system(size: size)
        case .heiti, .kaiti, .fangsong:
            // 预置中文字体：按候选名找系统里实际装的，找不到回退系统默认
            let available = Set(NSFontManager.shared.availableFontFamilies)
            for candidate in presetFamilyCandidates where available.contains(candidate) {
                return .custom(candidate, size: size)
            }
            return .system(size: size)
        case .custom(let name):
            return .custom(name, size: size)
        }
    }

    // MARK: 持久化（预置存 key，自定义存 "custom:<name>"；兼容旧值迁移）
    static var current: ReadingFont {
        get {
            let raw = UserDefaults.standard.string(forKey: "reading.font") ?? "system"
            if raw.hasPrefix("custom:") { return .custom(String(raw.dropFirst(7))) }
            switch raw {
            case "heiti", "sansSerif": return .heiti
            case "kaiti": return .kaiti
            case "fangsong", "serif": return .fangsong
            case "mono": return .custom("Menlo")
            default: return .system
            }
        }
        set {
            let raw: String
            switch newValue {
            case .system: raw = "system"
            case .heiti: raw = "heiti"
            case .kaiti: raw = "kaiti"
            case .fangsong: raw = "fangsong"
            case .custom(let name): raw = "custom:\(name)"
            }
            UserDefaults.standard.set(raw, forKey: "reading.font")
        }
    }

    // MARK: 系统字体枚举

    /// 系统已安装字体族名（去重排序），供选择列表
    static var availableFontFamilies: [String] {
        let names = NSFontManager.shared.availableFontFamilies
        return Array(Set(names)).sorted()
    }
}

// MARK: - Markdown 正文视图（按主题 palette 全元素着色）

struct MarkdownBodyView: View {
    let markdown: String
    let theme: ReadingTheme
    let mode: ReadingTheme.Mode
    let fontChoice: ReadingFont
    let fontSize: Double
    let lineSpacing: Double

    @State private var blocks: [MdBlock] = []

    private var p: ThemePalette { theme.palette(for: mode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        // 后台解析——长文（>50KB）主线程同步 parse 掉帧（修 P1-6）。
        // Task.detached 解析后 MainActor.run 写回，不阻塞首帧。
        .task(id: markdown) {
            let parsed = await Task.detached(priority: .userInitiated) {
                MarkdownRenderer.parse(markdown)
            }.value
            blocks = parsed
        }
    }

    @ViewBuilder
    private func blockView(_ block: MdBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownRenderer.inline(text, palette: p, fontSize: headingSize(level)))
                .font(headingFont(level))
                .foregroundStyle(headingColor(level))
                .padding(.top, level <= 2 ? 10 : 5)

        case .paragraph(let text):
            Text(MarkdownRenderer.inline(text, palette: p, fontSize: fontSize))
                .font(fontChoice.font(size: fontSize))
                .lineSpacing(lineSpacing)

        case .listItem(let ordered, let index, let text):
            HStack(alignment: .top, spacing: 8) {
                Text(ordered ? "\(index)." : "•")
                    .font(fontChoice.font(size: fontSize))
                    .foregroundStyle(p.listMarker)
                    .frame(minWidth: 20, alignment: .trailing)
                Text(MarkdownRenderer.inline(text, palette: p, fontSize: fontSize))
                    .font(fontChoice.font(size: fontSize))
                    .lineSpacing(lineSpacing)
            }
            .padding(.leading, 8)

        case .quote(let text):
            HStack(spacing: 0) {
                Rectangle().fill(p.quoteBorder).frame(width: 3)
                Text(MarkdownRenderer.inline(text, palette: p, fontSize: fontSize))
                    .font(fontChoice.font(size: fontSize))
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(p.quoteText)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(p.backgroundAlt)
            .clipShape(RoundedRectangle(cornerRadius: RB.Radius.md))

        case .codeBlock(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(p.codeText)
                    .padding(12)
            }
            .background(p.codeBackground)
            .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: RB.Radius.lg)
                    .strokeBorder(p.divider.opacity(0.6), lineWidth: RB.Line.hair)
            )

        case .divider:
            Rectangle().fill(p.divider).frame(height: RB.Line.hair)

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

        case .frontmatter(let text):
            FrontmatterBlock(text: text, palette: p)
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

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return fontSize + 10
        case 2: return fontSize + 6
        case 3: return fontSize + 3
        default: return fontSize + 1
        }
    }

    private func headingFont(_ level: Int) -> Font {
        let base = headingSize(level)
        // 标题字体跟用户的字体选择走，不被主题强制（主题 headingSerif 只作默认提示，
        // 用户选了字体就尊重用户——此前 Primary 的 headingSerif=true 把标题强制衬线，
        // 覆盖了用户选的黑体/楷体）
        return fontChoice.font(size: base).bold()
    }
}

// MARK: - 双语逐段对照视图（Follo 核心交互）
// 原文/译文按段落对齐交替：原文普通字、译文色块背景突出。
// 段落按双换行切分，一一对应（LLM 翻译保持段数一致时对齐最好）。

struct BilingualBodyView: View {
    let original: String
    let translated: String
    let theme: ReadingTheme
    let mode: ReadingTheme.Mode
    let fontChoice: ReadingFont
    let fontSize: Double
    let lineSpacing: Double

    private var p: ThemePalette { theme.palette(for: mode) }

    /// 段落对（原文段 + 对应译文段）——@State 缓存，不再每次 body 重建重算 splitParagraphs（修 P1-6）
    @State private var pairs: [(original: String, translated: String)] = []

    private func computePairs() -> [(original: String, translated: String)] {
        // 先剥掉原文开头的 frontmatter（Cleaned URL/YAML/时间戳），不进段落对——
        // 否则双语模式下 frontmatter 混进第一段露出来（和单语模式一致的剥离逻辑）。
        let cleanedOriginal = Self.stripFrontmatterText(original)
        let origParas = splitParagraphs(cleanedOriginal)
        // 译文按 [P1][P2]…编号对齐——LLM 翻译输出带编号，精确匹配（解决段落数不一致错位）
        let transMap = Self.parseTranslatedParagraphs(translated)
        // 兼容旧格式（无编号）：按顺序填充
        if transMap.isEmpty {
            let transParas = splitParagraphs(translated)
            var result: [(String, String)] = []
            for (i, origPara) in origParas.enumerated() {
                let transPara = i < transParas.count ? transParas[i] : ""
                result.append((origPara, transPara))
            }
            return result
        }
        // 新格式（带编号）：按编号精确对齐
        var result: [(String, String)] = []
        for (i, origPara) in origParas.enumerated() {
            let key = "P\(i + 1)"
            let transPara = transMap[key] ?? ""
            result.append((origPara, transPara))
        }
        return result
    }

    /// 解析译文段落——[P1] 段落1 [P2] 段落2 → ["P1": "段落1", "P2": "段落2"]
    /// LLM 翻译输出带编号标记，按编号精确对齐原文段落。
    static func parseTranslatedParagraphs(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        let paras = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for para in paras {
            // 匹配 [P1] 开头
            if let range = para.range(of: #"^\[P(\d+)\]"#, options: .regularExpression) {
                let tag = String(para[range]).replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                let content = String(para[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                map[tag] = content
            }
        }
        return map
    }

    /// 去掉文本开头的 frontmatter 区（调试日志 + --- 包裹的 YAML + 残留时间戳），
    /// 供双语模式拆段前清理原文。逻辑与 MarkdownRenderer.stripLeadingFrontmatter 对齐。
    static func stripFrontmatterText(_ md: String) -> String {
        var lines = md.components(separatedBy: "\n")
        var yamlStart = -1
        for j in 0..<min(lines.count, 6) where lines[j].trimmingCharacters(in: .whitespaces) == "---" {
            yamlStart = j; break
        }
        guard yamlStart >= 0 else { return md }
        var yamlEnd = -1
        for j in (yamlStart + 1)..<min(lines.count, 46) where lines[j].trimmingCharacters(in: .whitespaces) == "---" {
            yamlEnd = j; break
        }
        guard yamlEnd > yamlStart else { return md }
        let yamlLines = Array(lines[(yamlStart + 1)..<yamlEnd])
        guard yamlLines.filter({ $0.contains(":") }).count >= 2 else { return md }
        var consumedEnd = yamlEnd
        var k = yamlEnd + 1
        while k < lines.count, lines[k].trimmingCharacters(in: .whitespaces).isEmpty { k += 1 }
        if k < lines.count {
            let t = lines[k].trimmingCharacters(in: .whitespaces)
            let ts = #"^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$"#
            if t.range(of: ts, options: .regularExpression) != nil { consumedEnd = k }
        }
        lines = Array(lines[(consumedEnd + 1)...])
        return lines.joined(separator: "\n")
    }

    private func splitParagraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 6) {
                    // 原文
                    if !pair.original.isEmpty {
                        MarkdownBodyView(markdown: pair.original, theme: theme, mode: mode,
                                         fontChoice: fontChoice, fontSize: fontSize, lineSpacing: lineSpacing)
                    }
                    // 译文（色块背景突出，Follo 风格）
                    if !pair.translated.isEmpty {
                        MarkdownBodyView(markdown: pair.translated, theme: theme, mode: mode,
                                         fontChoice: fontChoice, fontSize: fontSize, lineSpacing: lineSpacing)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(p.backgroundAlt)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(p.link).frame(width: 3)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
                    }
                }
            }
        }
        // pairs 在原文/译文变化时重算（onChange 比 .task(id:) 更可靠——hashValue 可能冲突）
        .onAppear { pairs = computePairs() }
        .onChange(of: original) { _, _ in pairs = computePairs() }
        .onChange(of: translated) { _, _ in pairs = computePairs() }
    }
}

// MARK: - Frontmatter 折叠块（正文开头的 YAML 元数据，Obsidian 式）

/// 渲染正文开头的 frontmatter 块（title/url/published/domain 等抓取元数据）。
/// 默认收起显示「文档信息 · N 项」，点开展开看全部键值对（长值自动换行）。
/// 折叠状态记 reading.metaExpanded（重启保持）。
struct FrontmatterBlock: View {
    let text: String
    let palette: ThemePalette
    @AppStorage("reading.metaExpanded") private var expanded: Bool = false

    /// 解析 YAML 行成 (key, value) 对（title: xxx → (title, xxx)）。
    /// 过滤 defuddle 调试噪音行（Cleaned URL/Xxx detected/pre-processing/Fetched/
    /// 时间戳残留）——这些是抓取过程日志不是元数据，不显示给用户。
    private var fields: [(key: String, value: String)] {
        text.components(separatedBy: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            // 跳过调试噪音行和时间戳残留行
            if isDebugNoise(t) { return nil }
            guard !t.isEmpty, let colon = t.firstIndex(of: ":") else { return nil }
            let key = String(t[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // 去 YAML 引号（'xxx' / "xxx"）
            if (value.hasPrefix("'") && value.hasSuffix("'")) ||
               (value.hasPrefix("\"") && value.hasSuffix("\"")), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return (key, value)
        }
    }

    /// 是否 defuddle 调试噪音/残留行（不该显示给用户的抓取过程日志）
    private func isDebugNoise(_ s: String) -> Bool {
        if s.isEmpty { return true }
        // 调试日志前缀
        let noisePrefixes = ["Cleaned URL:", "Fetching", "Fetched", "Pre-processing", "pre-processing"]
        for p in noisePrefixes where s.hasPrefix(p) { return true }
        // 「Xxx detected, ...」检测日志
        if s.contains("detected,") { return true }
        // 残留时间戳行（yyyy-MM-dd 或带时间）
        let ts = #"^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$"#
        if s.range(of: ts, options: .regularExpression) != nil { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
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
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { _, f in
                        HStack(alignment: .top, spacing: 8) {
                            Text(f.key)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(palette.textFaint)
                                .frame(width: 90, alignment: .trailing)
                            // 长值（url）自动换行；description 超长截断 3 行（防撑爆）
                            Text(f.value)
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textSecondary)
                                .lineLimit(f.key == "description" ? 3 : nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(palette.backgroundAlt.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(palette.divider, lineWidth: 0.5)
        )
    }
}
