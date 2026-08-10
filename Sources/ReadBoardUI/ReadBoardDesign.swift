import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Core 与 Go 共用的纸墨设计系统。产品差异只能通过能力和内容体现，不能再复制一套视觉常量。
public enum ReadBoardDesign {
    public static func dynamic(_ light: String, _ dark: String) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(readBoardHex: isDark ? dark : light)
        })
        #else
        return Color(uiColor: UIColor { traits in
            UIColor(readBoardHex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }

    public enum C {
        public static let bg = ReadBoardDesign.dynamic("#FFFFFF", "#1D1C1A")
        public static let bgSidebar = ReadBoardDesign.dynamic("#F7F6F2", "#161514")
        public static let surface = ReadBoardDesign.dynamic("#F5F4F0", "#282622")
        public static let text = ReadBoardDesign.dynamic("#282622", "#E5E2DA")
        public static let text2 = ReadBoardDesign.dynamic("#6F6A5E", "#A19C90")
        public static let text3 = ReadBoardDesign.dynamic("#AAA498", "#65615A")
        public static let accent = ReadBoardDesign.dynamic("#2F5B8F", "#7AA4D9")
        public static let onAccent = ReadBoardDesign.dynamic("#FFFFFF", "#1D1C1A")
        public static let hairline = ReadBoardDesign.dynamic("#EBE9E3", "#35322C")
        public static let separator = ReadBoardDesign.dynamic("#DDDAD1", "#45413A")
        public static let scoreHigh = ReadBoardDesign.dynamic("#4C8A5A", "#7BAF86")
        public static let scoreGood = accent
        public static let scoreMid = ReadBoardDesign.dynamic("#B07A3A", "#CE9E5F")
        public static let scoreLow = ReadBoardDesign.dynamic("#B0524A", "#CE7B74")
        public static let scoreNone = ReadBoardDesign.dynamic("#9BA1AB", "#5C6270")
        public static let star = ReadBoardDesign.dynamic("#C9A24B", "#D9BC6E")
        public static let summary = ReadBoardDesign.dynamic("#7A6AA0", "#9E8FC0")
        public static let translate = ReadBoardDesign.dynamic("#4A7A8C", "#6FA3B3")
        public static let rss = ReadBoardDesign.dynamic("#E66A22", "#F08A4B")
        public static let podcast = ReadBoardDesign.dynamic("#8B4CB8", "#B07AD3")
        public static let video = ReadBoardDesign.dynamic("#D95A56", "#E98480")
        public static let youtube = video
        public static let bilibili = ReadBoardDesign.dynamic("#4FA9C4", "#79C5D8")
        public static let wechat = ReadBoardDesign.dynamic("#5FA66A", "#82BF8A")
    }

    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public enum Radius {
        public static let sm: CGFloat = 4
        public static let md: CGFloat = 6
        public static let lg: CGFloat = 8
        public static let xl: CGFloat = 10
    }

    public enum Line { public static let hair: CGFloat = 0.5 }
    /// 迁移期兼容名；新代码使用 `Line.hair`。
    public static let hairline = Line.hair
    public enum Track { public static let section: CGFloat = 0.8 }

    public enum F {
        public static let rowTitle: CGFloat = 14
        public static let rowExcerpt: CGFloat = 12
        public static let rowMeta: CGFloat = 11
        public static let badge: CGFloat = 9
        public static let sidebar: CGFloat = 13
        public static let count: CGFloat = 11
        public static let section: CGFloat = 11
        public static let pageTitle: CGFloat = 17
    }
    /// 迁移期兼容名；Core 现有代码使用 `F`，Go 旧调用使用 `FontSize`。
    public typealias FontSize = F

    public enum Shadow {
        public static let floatingColor = ReadBoardDesign.dynamic("#282622", "#000000")
        public static let floatingOpacity = 0.10
        public static let floatingRadius: CGFloat = 14
        public static let floatingY: CGFloat = 5
    }
}

public struct ReadBoardHairline: View {
    public var vertical: Bool
    public init(vertical: Bool = false) { self.vertical = vertical }
    public var body: some View {
        Rectangle()
            .fill(ReadBoardDesign.C.hairline)
            .frame(
                width: vertical ? ReadBoardDesign.Line.hair : nil,
                height: vertical ? nil : ReadBoardDesign.Line.hair)
    }
}

public struct ReadBoardSectionLabel: View {
    public let text: String
    public init(text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(.system(size: ReadBoardDesign.F.section, weight: .medium))
            .foregroundStyle(ReadBoardDesign.C.text3)
            .tracking(ReadBoardDesign.Track.section)
    }
}

public struct ReadBoardBadge: View {
    public let text: String
    public let color: Color
    public let scale: Double
    public init(text: String, color: Color, scale: Double = 1) {
        self.text = text
        self.color = color
        self.scale = scale
    }
    public var body: some View {
        Text(text)
            .font(.system(size: ReadBoardDesign.F.badge * scale, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.sm))
            .overlay {
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.sm)
                    .strokeBorder(color.opacity(0.22), lineWidth: ReadBoardDesign.Line.hair)
            }
    }
}

public struct ReadBoardPanel<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .padding(ReadBoardDesign.Space.lg)
            .background(ReadBoardDesign.C.surface.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg)
                    .strokeBorder(ReadBoardDesign.C.hairline, lineWidth: ReadBoardDesign.Line.hair)
            }
    }
}

public struct ReadBoardMetricTile: View {
    public let title: String
    public let value: String
    public let icon: String
    public let color: Color
    public init(title: String, value: String, icon: String, color: Color) {
        self.title = title; self.value = value; self.icon = icon; self.color = color
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
            Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(ReadBoardDesign.C.text)
            Text(title).font(.system(size: 11)).foregroundStyle(ReadBoardDesign.C.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ReadBoardDesign.Space.md)
        .background(ReadBoardDesign.C.surface.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg)
                .strokeBorder(ReadBoardDesign.C.hairline, lineWidth: ReadBoardDesign.Line.hair)
        }
    }
}

public struct ReadBoardPageHeader<Trailing: View>: View {
    public let eyebrow: String
    public let title: String
    public let subtitle: String?
    private let trailing: Trailing
    public init(
        eyebrow: String, title: String, subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.eyebrow = eyebrow; self.title = title; self.subtitle = subtitle
        self.trailing = trailing()
    }
    public var body: some View {
        HStack(alignment: .center, spacing: ReadBoardDesign.Space.lg) {
            VStack(alignment: .leading, spacing: ReadBoardDesign.Space.xs) {
                ReadBoardSectionLabel(text: eyebrow)
                Text(title).font(.system(size: ReadBoardDesign.F.pageTitle, weight: .semibold))
                    .foregroundStyle(ReadBoardDesign.C.text)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(ReadBoardDesign.C.text3)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: ReadBoardDesign.Space.md)
            trailing
        }
    }
}

public extension ReadBoardPageHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

public struct ReadBoardQuietButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ReadBoardDesign.C.text2)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(configuration.isPressed ? ReadBoardDesign.C.surface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md))
    }
}

public struct ReadBoardSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ReadBoardDesign.C.text2)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(ReadBoardDesign.C.surface.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md)
                    .strokeBorder(ReadBoardDesign.C.hairline, lineWidth: ReadBoardDesign.Line.hair)
            }
    }
}

public struct ReadBoardPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ReadBoardDesign.C.onAccent)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(ReadBoardDesign.C.accent.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
    }
}

public extension View {
    func readBoardField(focused: Bool = false) -> some View {
        padding(.horizontal, 11).padding(.vertical, 9)
            .background(ReadBoardDesign.C.surface)
            .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg)
                    .strokeBorder(
                        focused ? ReadBoardDesign.C.accent.opacity(0.45) : ReadBoardDesign.C.hairline,
                        lineWidth: ReadBoardDesign.Line.hair)
            }
    }

    func readBoardSelected(_ selected: Bool) -> some View {
        background {
            RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md)
                .fill(selected ? ReadBoardDesign.C.accent.opacity(0.10) : Color.clear)
        }
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2).fill(ReadBoardDesign.C.accent)
                    .frame(width: 2.5).padding(.vertical, 3)
            }
        }
    }
}

#if os(macOS)
private extension NSColor {
    convenience init(readBoardHex: String) {
        let rgb = readBoardRGB(readBoardHex)
        self.init(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
}
#else
private extension UIColor {
    convenience init(readBoardHex: String) {
        let rgb = readBoardRGB(readBoardHex)
        self.init(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
}
#endif

private func readBoardRGB(_ value: String) -> (CGFloat, CGFloat, CGFloat) {
    let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    let number = UInt64(hex, radix: 16) ?? 0
    return (
        CGFloat((number >> 16) & 255) / 255,
        CGFloat((number >> 8) & 255) / 255,
        CGFloat(number & 255) / 255)
}
