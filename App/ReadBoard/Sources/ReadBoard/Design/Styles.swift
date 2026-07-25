import SwiftUI

// MARK: - 复用样式组件（极简留白系）
//
// Hairline（替换全部 Divider）、Badge（去 bold、底 12%）、
// QuietButtonStyle（hover 浮现 surface 底）、SectionLabel（小标题）。

/// 极细分割线（0.5pt 物理 1px）——替换全部 Divider()，呼吸感来源
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.rbHairline)
            .frame(height: RB.Line.hair)
    }
}

/// 统一 badge（评分/管线状态）：去 bold、底 12% 透明、radius sm。
/// 选中态不再反白——浅色底下保持各自颜色更清晰。
struct RBadge: View {
    let text: String
    let color: Color
    var scale: Double = 1.0

    var body: some View {
        Text(text)
            .font(.system(size: RB.F.badge * scale, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: RB.Radius.sm))
    }
}

/// 安静按钮样式：默认 text2 无底色，hover 浮现 surface 圆角底，无按压变蓝。
/// 用于操作条图标按钮——极简界面里按钮不该抢视觉。
struct QuietButtonStyle: ButtonStyle {
    var radius: CGFloat = RB.Radius.md

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, radius: radius)
    }

    private struct QuietButtonBody: View {
        let configuration: Configuration
        let radius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Color.rbText2)
                .padding(RB.Space.xs)
                .background(
                    RoundedRectangle(cornerRadius: radius)
                        .fill(hovering || configuration.isPressed
                              ? Color.rbSurface : Color.clear)
                )
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

/// 小标题（左栏"订阅源"、列表"N 条"）：caption + text3 + 字距，克制不抢眼
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.rbText3)
            .tracking(0.5)
    }
}

/// 胶囊操作按钮（LLM 操作条等"可点动作"）：surface 底 + 圆角胶囊，
/// hover 时 accent 浅底浮现 + 文字 accent，图标+文字一组。比默认 bordered 按钮克制，
/// 比纯文字按钮有可点感。
struct CapsuleButton: View {
    let title: String
    let icon: String
    var disabled: Bool = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(disabled ? Color.rbText3 : (hovering ? Color.rbAccent : Color.rbText2))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(disabled ? Color.rbSurface.opacity(0.5)
                              : (hovering ? Color.rbAccent.opacity(0.10) : Color.rbSurface))
                )
                .overlay(
                    Capsule().strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
