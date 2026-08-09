import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum ReadBoardReadingTheme: String, CaseIterable, Identifiable, Sendable {
    case claude
    case things
    case systemDefault

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Primary"
        case .things: "Things"
        case .systemDefault: "系统默认"
        }
    }
}

public enum ReadBoardReadingColorMode: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case system

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .light: "亮色"
        case .dark: "暗色"
        case .system: "跟随系统"
        }
    }
}

public struct ReadBoardReadingPalette: @unchecked Sendable {
    public let background: Color
    public let text: Color
    public let textSecondary: Color
    public let textFaint: Color
    public let markdown: ReadBoardMarkdownPalette

    public static func resolve(
        theme: ReadBoardReadingTheme,
        mode: ReadBoardReadingColorMode,
        systemColorScheme: ColorScheme
    ) -> ReadBoardReadingPalette {
        let isDark = mode == .dark || (mode == .system && systemColorScheme == .dark)
        return switch (theme, isDark) {
        case (.claude, false): primaryLight
        case (.claude, true): primaryDark
        case (.things, false): thingsLight
        case (.things, true): thingsDark
        case (.systemDefault, _): system
        }
    }

    private static let primaryLight = make(
        background: rgb(0.965, 0.945, 0.894),
        backgroundAlt: rgb(0.937, 0.910, 0.847),
        codeBackground: rgb(0.929, 0.898, 0.831),
        inlineCodeBackground: rgb(0.910, 0.878, 0.812),
        text: rgb(0.286, 0.247, 0.208),
        secondary: rgb(0.482, 0.435, 0.376),
        faint: rgb(0.639, 0.596, 0.533),
        headings: [rgb(0.220, 0.184, 0.149), rgb(0.769, 0.263, 0.220),
                   rgb(0.227, 0.471, 0.678), rgb(0.788, 0.596, 0.180)],
        bold: rgb(0.769, 0.263, 0.220), italic: rgb(0.227, 0.471, 0.678),
        inlineCode: rgb(0.769, 0.263, 0.220), link: rgb(0.788, 0.596, 0.180),
        quoteBorder: rgb(0.227, 0.471, 0.678), quoteText: rgb(0.435, 0.384, 0.322),
        listMarker: rgb(0.769, 0.263, 0.220), divider: rgb(0.839, 0.800, 0.729))

    private static let primaryDark = make(
        background: rgb(0.145, 0.125, 0.098),
        backgroundAlt: rgb(0.110, 0.094, 0.074),
        codeBackground: rgb(0.090, 0.078, 0.063),
        inlineCodeBackground: rgb(0.22, 0.19, 0.15),
        text: rgb(0.878, 0.847, 0.796),
        secondary: rgb(0.62, 0.58, 0.52), faint: rgb(0.47, 0.44, 0.39),
        headings: [rgb(0.945, 0.925, 0.890), rgb(0.898, 0.478, 0.435),
                   rgb(0.549, 0.720, 0.878), rgb(0.898, 0.761, 0.478)],
        bold: rgb(0.898, 0.478, 0.435), italic: rgb(0.549, 0.720, 0.878),
        inlineCode: rgb(0.898, 0.620, 0.478), link: rgb(0.898, 0.761, 0.478),
        quoteBorder: rgb(0.549, 0.720, 0.878), quoteText: rgb(0.70, 0.66, 0.60),
        listMarker: rgb(0.898, 0.478, 0.435), divider: rgb(0.32, 0.28, 0.23))

    private static let thingsLight = make(
        background: rgb(0.996, 0.996, 0.992),
        backgroundAlt: rgb(0.949, 0.953, 0.961),
        codeBackground: rgb(0.937, 0.941, 0.949),
        inlineCodeBackground: rgb(0.898, 0.906, 0.918),
        text: rgb(0.220, 0.243, 0.278),
        secondary: rgb(0.45, 0.48, 0.53), faint: rgb(0.62, 0.65, 0.69),
        headings: [rgb(0.13, 0.15, 0.18), rgb(0.16, 0.45, 0.85),
                   rgb(0.16, 0.45, 0.85), rgb(0.78, 0.58, 0.20)],
        bold: rgb(0.88, 0.30, 0.52), italic: rgb(0.88, 0.30, 0.52),
        inlineCode: rgb(0.33, 0.36, 0.42), link: rgb(0.16, 0.45, 0.85),
        quoteBorder: rgb(0.20, 0.60, 0.65), quoteText: rgb(0.20, 0.55, 0.60),
        listMarker: rgb(0.20, 0.60, 0.65), divider: rgb(0.86, 0.87, 0.89))

    private static let thingsDark = make(
        background: rgb(0.141, 0.157, 0.196),
        backgroundAlt: rgb(0.113, 0.125, 0.161),
        codeBackground: rgb(0.098, 0.110, 0.145),
        inlineCodeBackground: rgb(0.20, 0.22, 0.27),
        text: rgb(0.827, 0.808, 0.792),
        secondary: rgb(0.55, 0.57, 0.62), faint: rgb(0.42, 0.45, 0.51),
        headings: [rgb(0.937, 0.925, 0.910), rgb(0.18, 0.50, 0.95),
                   rgb(0.18, 0.50, 0.95), rgb(0.898, 0.710, 0.404)],
        bold: rgb(1.0, 0.510, 0.698), italic: rgb(1.0, 0.510, 0.698),
        inlineCode: rgb(0.745, 0.78, 0.81), link: rgb(0.18, 0.50, 0.95),
        quoteBorder: rgb(0.243, 0.706, 0.749), quoteText: rgb(0.243, 0.706, 0.749),
        listMarker: rgb(0.243, 0.706, 0.749), divider: rgb(0.30, 0.32, 0.38))

    private static let system = make(
        background: ReadBoardDesign.C.bg,
        backgroundAlt: ReadBoardDesign.C.surface,
        codeBackground: ReadBoardDesign.C.surface,
        inlineCodeBackground: ReadBoardDesign.C.separator.opacity(0.35),
        text: ReadBoardDesign.C.text,
        secondary: ReadBoardDesign.C.text2,
        faint: ReadBoardDesign.C.text3,
        headings: [ReadBoardDesign.C.text, ReadBoardDesign.C.text,
                   ReadBoardDesign.C.text, ReadBoardDesign.C.text],
        bold: ReadBoardDesign.C.text, italic: ReadBoardDesign.C.text,
        inlineCode: ReadBoardDesign.C.text, link: ReadBoardDesign.C.accent,
        quoteBorder: ReadBoardDesign.C.accent, quoteText: ReadBoardDesign.C.text2,
        listMarker: ReadBoardDesign.C.accent, divider: ReadBoardDesign.C.hairline)

    private static func make(
        background: Color, backgroundAlt: Color, codeBackground: Color,
        inlineCodeBackground: Color, text: Color, secondary: Color, faint: Color,
        headings: [Color], bold: Color, italic: Color, inlineCode: Color, link: Color,
        quoteBorder: Color, quoteText: Color, listMarker: Color, divider: Color
    ) -> ReadBoardReadingPalette {
        ReadBoardReadingPalette(
            background: background,
            text: text,
            textSecondary: secondary,
            textFaint: faint,
            markdown: ReadBoardMarkdownPalette(
                backgroundAlt: backgroundAlt,
                codeBackground: codeBackground,
                inlineCodeBackground: inlineCodeBackground,
                text: text,
                textSecondary: secondary,
                textFaint: faint,
                headings: headings,
                bold: bold,
                italic: italic,
                inlineCode: inlineCode,
                link: link,
                quoteBorder: quoteBorder,
                quoteText: quoteText,
                listMarker: listMarker,
                divider: divider,
                codeText: text))
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red, green: green, blue: blue)
    }
}

public enum ReadBoardReadingFont {
    public static let presets: [(key: String, title: String)] = [
        ("system", "系统默认"),
        ("heiti", "黑体"),
        ("kaiti", "楷体"),
        ("fangsong", "仿宋"),
    ]

    public static var availableFontFamilies: [String] {
        #if os(macOS)
        Array(Set(NSFontManager.shared.availableFontFamilies)).sorted()
        #else
        UIFont.familyNames.sorted()
        #endif
    }

    public static func font(
        rawValue: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        guard let family = resolvedFamily(rawValue: rawValue) else {
            return .system(size: size, weight: weight, design: design)
        }
        return .custom(family, size: size).weight(weight)
    }

    private static func resolvedFamily(rawValue: String) -> String? {
        if rawValue.hasPrefix("custom:") { return String(rawValue.dropFirst(7)) }
        let candidates: [String]
        switch rawValue {
        case "heiti", "sansSerif": candidates = ["Heiti SC", "STHeiti", "PingFang SC"]
        case "kaiti": candidates = ["Kaiti SC", "STKaiti", "Kai"]
        case "fangsong", "serif": candidates = ["STFangsong", "FangSong", "FangSong_GB2312"]
        case "mono": candidates = ["Menlo"]
        default: return nil
        }
        let available = Set(availableFontFamilies)
        return candidates.first(where: available.contains)
    }
}
