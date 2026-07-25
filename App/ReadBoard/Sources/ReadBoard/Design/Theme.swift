import SwiftUI

// MARK: - 颜色/视图便捷扩展（极简留白系）
//
// 把 RB.C.* 暴露成 Color 静态属性，调用点写 .rbAccent / .rbText2 即可。
// 选中态扩展 .rbSelection 是全 App 统一的核心视觉：
//   accentColor 实心填充+白字 → 浅墨蓝底 + 左缘 2.5pt 竖条 + 文字保持主色。

extension Color {
    // 背景三级
    static let rbBg        = RB.C.bg
    static let rbBgSidebar = RB.C.bgSidebar
    static let rbSurface   = RB.C.surface
    // 文字三级
    static let rbText      = RB.C.text
    static let rbText2     = RB.C.text2
    static let rbText3     = RB.C.text3
    // 点缀 + 分割线
    static let rbAccent    = RB.C.accent
    static let rbHairline  = RB.C.hairline
    static let rbSeparator = RB.C.separator
    // 语义色
    static let rbScoreHigh = RB.C.scoreHigh
    static let rbScoreGood = RB.C.scoreGood
    static let rbScoreMid  = RB.C.scoreMid
    static let rbScoreLow  = RB.C.scoreLow
    static let rbScoreNone = RB.C.scoreNone
    static let rbStar      = RB.C.star
    static let rbSummary   = RB.C.summary
    static let rbTranslate = RB.C.translate
}

extension View {
    /// 极简选中态：浅墨蓝底 + 左缘 2.5pt 竖条，文字保持主色（Things 3 标志性处理）。
    /// 用 overlay 不用 ZStack——不额外布局，300 行列表下 diff 更轻。
    /// 亮 0.10 / 暗自动由动态色适配（accent 本身已是动态色，opacity 底在暗色下自然更深）。
    func rbSelection(_ selected: Bool, radius: CGFloat = RB.Radius.md) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(selected ? Color.rbAccent.opacity(0.10) : Color.clear)
            )
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.rbAccent)
                        .frame(width: 2.5)
                        .padding(.vertical, 3)
                }
            }
    }

    /// 行选中态文字色：选中/未选中都用主文字体系（不再选中反白）
    func rbRowTitleColor(isRead: Bool) -> some View {
        self.foregroundStyle(isRead ? Color.rbText2 : Color.rbText)
    }
}
