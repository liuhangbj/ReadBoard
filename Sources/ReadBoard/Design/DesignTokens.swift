import SwiftUI
import AppKit

// MARK: - 设计 Token（纸墨系 · 编辑部极简）
//
// 全 App 唯一的视觉常量层。暖纸白中性灰 + 墨水蓝单点缀，亮暗两套色系。
// 功能逻辑零改——这里只定义"颜色/间距/圆角/分割线/阴影/字级"，不碰任何行为。
//
// 设计纪律（全 App 一致）：
//   · 中性色一律暖调（纸感），唯一冷色是墨蓝 accent——暖底冷墨形成张力
//   · 文字三级用"墨色浓淡"而非多种灰——同一墨色的不同稀释度
//   · 分割线全部是 0.5pt hairline；阴影只给浮层（popover/toast/sheet）
//   · 色彩克制：大面积无彩色，让文章配图/内容本身提供颜色
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
        // —— 背景三级（暖纸基底，大面积留白）——
        static let bg        = RB.dynamic("#FFFFFF", "#1D1C1A")  // 窗体主底（暗色为暖炭黑）
        static let bgSidebar = RB.dynamic("#F7F6F2", "#161514")  // 左栏略灰偏暖，分出层次
        static let surface   = RB.dynamic("#F5F4F0", "#282622")  // 卡片/行 hover/搜索框

        // —— 文字三级（墨色浓淡：同一墨的不同稀释）——
        static let text      = RB.dynamic("#282622", "#E5E2DA")  // 主文字 暖墨近黑
        static let text2     = RB.dynamic("#6F6A5E", "#A19C90")  // 次要（来源/摘要）
        static let text3     = RB.dynamic("#AAA498", "#65615A")  // 弱化（日期/计数）

        // —— 点缀色（选中/未读点/强调，全 App 唯一强调色）——
        static let accent    = RB.dynamic("#2F5B8F", "#7AA4D9")  // 墨水蓝
        static let onAccent  = RB.dynamic("#FFFFFF", "#1D1C1A")  // accent 底上的文字色

        // —— 分割线（极细极淡，呼吸感来源）——
        static let hairline  = RB.dynamic("#EBE9E3", "#35322C")  // 0.5pt 分割
        static let separator = RB.dynamic("#DDDAD1", "#45413A")  // 稍强分隔

        // —— 语义色（降饱和版，评分/badge 用）——
        static let scoreHigh = RB.dynamic("#4C8A5A", "#7BAF86")  // 90+ 灰绿
        static let scoreGood = RB.dynamic("#2F5B8F", "#7AA4D9")  // 75-84 直接用 accent
        static let scoreMid  = RB.dynamic("#B07A3A", "#CE9E5F")  // 60-74 赭
        static let scoreLow  = RB.dynamic("#B0524A", "#CE7B74")  // 1-59 砖红
        static let scoreNone = RB.dynamic("#9BA1AB", "#5C6270")  // 0 灰
        static let star      = RB.dynamic("#C9A24B", "#D9BC6E")  // 星标 柔金
        static let summary   = RB.dynamic("#7A6AA0", "#9E8FC0")  // 摘 灰紫
        static let translate = RB.dynamic("#4A7A8C", "#6FA3B3")  // 译/录 灰青

        // —— 内容类型图标（仅用于小面积识别，不参与全局强调层级）——
        static let rss       = RB.dynamic("#E66A22", "#F08A4B")  // RSS 橙
        static let podcast   = RB.dynamic("#8B4CB8", "#B07AD3")  // Podcast 紫
        static let video     = RB.dynamic("#E53935", "#FF6B66")  // 视频红
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
        static let xl: CGFloat = 10
    }

    // MARK: 分割线（物理 1px）

    enum Line {
        static let hair: CGFloat = 0.5
    }

    // MARK: 阴影（只给浮层：popover / toast / 浮起卡片）

    enum Shadow {
        /// 浮层软阴影：短距离、低透明，纸上浮起一张纸的克制度
        static let floatingColor = RB.dynamic("#282622", "#000000")
        static let floatingOpacity: Double = 0.10
        static let floatingRadius: CGFloat = 14
        static let floatingY: CGFloat = 5
    }

    // MARK: 字距（编辑部眉题风格）

    enum Track {
        static let section: CGFloat = 0.8   // 小标题/眉题加宽字距
    }

    // MARK: 字级（乘在 uiFontScale 上的相对磅数——保留现有 scale 机制）

    enum F {
        static let rowTitle:   CGFloat = 14  // 列表标题
        static let rowExcerpt: CGFloat = 12  // 摘要
        static let rowMeta:    CGFloat = 11  // 来源/日期
        static let badge:      CGFloat = 9   // badge 单字
        static let sidebar:    CGFloat = 13  // 左栏源名
        static let count:      CGFloat = 11  // 未读计数
        static let section:    CGFloat = 11  // 区块小标题（眉题）
        static let pageTitle:  CGFloat = 17  // 页面大标题（订阅源/管理页头）
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
