import SwiftUI
import AppKit

// MARK: - 设计 Token（极简留白系 · Things 3 / Bear）
//
// 全 App 唯一的视觉常量层。黑白灰为主 + 墨水蓝点缀，亮暗两套色系。
// 功能逻辑零改——这里只定义"颜色/间距/圆角/分割线"，不碰任何行为。
//
// 颜色用 NSColor 动态色（RB.dynamic）：跟随系统外观自动切换，由系统层缓存，
// 视图重建零开销（比 @Environment(\.colorScheme) 判断高效——后者切换外观时整个子树全量重建）。

enum RB {

    /// 亮暗动态色：传两套 hex，系统外观切换自动取对应值
    static func dynamic(_ light: String, _ dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    // MARK: 色彩（亮 / 暗 两套 hex）

    enum C {
        // —— 背景三级（大面积留白基底）——
        static let bg        = RB.dynamic("#FFFFFF", "#1B1D21")  // 窗体主底
        static let bgSidebar = RB.dynamic("#F5F5F4", "#17181B")  // 左栏略灰，分出层次
        static let surface   = RB.dynamic("#FAFAF9", "#22242A")  // 卡片/行选中底/搜索框

        // —— 文字三级 ——
        static let text      = RB.dynamic("#1D2129", "#E3E5E8")  // 主文字 近黑非纯黑
        static let text2     = RB.dynamic("#6B7280", "#9BA1AB")  // 次要（来源/摘要）
        static let text3     = RB.dynamic("#A8AEB8", "#5C6270")  // 弱化（日期/计数）

        // —— 点缀色（选中/未读点/强调，全 App 唯一强调色）——
        static let accent    = RB.dynamic("#2F5B8F", "#6E9BD8")  // 墨水蓝

        // —— 分割线（极细极淡，呼吸感来源）——
        static let hairline  = RB.dynamic("#ECECEA", "#2E3138")  // 0.5pt 分割
        static let separator = RB.dynamic("#E2E2DF", "#35383F")  // 稍强分隔

        // —— 语义色（降饱和版，评分/badge 用）——
        static let scoreHigh = RB.dynamic("#4C8A5A", "#7BAF86")  // 90+ 灰绿
        static let scoreGood = RB.dynamic("#2F5B8F", "#6E9BD8")  // 75-84 直接用 accent
        static let scoreMid  = RB.dynamic("#B07A3A", "#CE9E5F")  // 60-74 赭
        static let scoreLow  = RB.dynamic("#B0524A", "#CE7B74")  // 1-59 砖红
        static let scoreNone = RB.dynamic("#9BA1AB", "#5C6270")  // 0 灰
        static let star      = RB.dynamic("#C9A24B", "#D9BC6E")  // 星标 柔金
        static let summary   = RB.dynamic("#7A6AA0", "#9E8FC0")  // 摘 灰紫
        static let translate = RB.dynamic("#4A7A8C", "#6FA3B3")  // 译/录 灰青
    }

    // MARK: 间距（4 基数梯度）

    enum Space {
        static let xxs: CGFloat = 2
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 12
        static let lg:  CGFloat = 16
        static let xl:  CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: 圆角

    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 6
        static let lg: CGFloat = 8
    }

    // MARK: 分割线（物理 1px）

    enum Line {
        static let hair: CGFloat = 0.5
    }

    // MARK: 字级（乘在 uiFontScale 上的相对磅数——保留现有 scale 机制）

    enum F {
        static let rowTitle:   CGFloat = 14  // 列表标题（原 15→14 更克制）
        static let rowExcerpt: CGFloat = 12  // 摘要
        static let rowMeta:    CGFloat = 11  // 来源/日期
        static let badge:      CGFloat = 9   // badge 单字
        static let sidebar:    CGFloat = 13  // 左栏源名
        static let count:      CGFloat = 11  // 未读计数
    }
}

// MARK: - NSColor hex 初始化

extension NSColor {
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
