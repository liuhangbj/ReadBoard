import SwiftUI
import AVFoundation

// MARK: - 复用样式组件（纸墨系）
//
// Hairline / VHairline（替换全部 Divider）、SectionLabel（眉题小标题）、
// RBadge（去 bold、底 10% + 同色 hairline 描边）、QuietButtonStyle（hover 浮现）、
// RowHoverButtonStyle（列表/左栏行 hover）、PrimaryCapsuleButtonStyle（关键动作）、
// CapsuleButton（次级动作）、StatusBanner（状态横幅）、rbFieldBackground（输入框）。

/// 极细分割线（0.5pt 物理 1px）——替换全部 Divider()，呼吸感来源
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.rbHairline)
            .frame(height: RB.Line.hair)
    }
}

/// 垂直 hairline——工具条按钮簇之间的克制分隔（替代 Spacer 堆间距）
struct VHairline: View {
    var height: CGFloat = 14
    var body: some View {
        Rectangle()
            .fill(Color.rbHairline)
            .frame(width: RB.Line.hair, height: height)
    }
}

/// 眉题小标题（左栏「订阅源」、设置分组、统计分区）：
/// 11pt medium + 加宽字距 + text3——编辑部 eyebrow 风格，克制不抢眼
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: RB.F.section, weight: .medium))
            .foregroundStyle(Color.rbText3)
            .tracking(RB.Track.section)
    }
}

/// 统一 badge（评分/管线状态）：去 bold、底 10% 透明 + 同色 20% hairline 描边、radius sm。
/// 描边让浅底 badge 在白底上边缘更挺——纸墨细节。
struct RBadge: View {
    let text: String
    let color: Color
    var scale: Double = 1.0

    var body: some View {
        Text(text)
            .font(.system(size: RB.F.badge * scale, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: RB.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: RB.Radius.sm)
                    .strokeBorder(color.opacity(0.22), lineWidth: RB.Line.hair)
            )
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

/// 行 hover 按钮样式（左栏源行 / 设置行 / 列表行）：
/// hover 浮现 surface 圆角底；选中态交给 rbSelection 叠加，二者正交。
struct RowHoverButtonStyle: ButtonStyle {
    var radius: CGFloat = RB.Radius.md

    func makeBody(configuration: Configuration) -> some View {
        RowHoverBody(configuration: configuration, radius: radius)
    }

    private struct RowHoverBody: View {
        let configuration: Configuration
        let radius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .rbRowHover(hovering || configuration.isPressed, radius: radius)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.10), value: hovering)
        }
    }
}

extension ButtonStyle where Self == RowHoverButtonStyle {
    static var rowHover: RowHoverButtonStyle { RowHoverButtonStyle() }
}

/// 主行动胶囊按钮（「添加」「保存」等关键动作）：
/// 墨蓝实心 + onAccent 字，hover 微降明度，禁用 45% 透明。
/// 全 App 每屏至多一个主行动——视觉焦点纪律。
struct PrimaryCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryCapsuleBody(configuration: configuration)
    }

    private struct PrimaryCapsuleBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.rbOnAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.rbAccent
                            .opacity(isEnabled ? (hovering ? 0.85 : 1.0) : 0.45))
                )
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.10), value: hovering)
        }
    }
}

extension ButtonStyle where Self == PrimaryCapsuleButtonStyle {
    static var primaryCapsule: PrimaryCapsuleButtonStyle { PrimaryCapsuleButtonStyle() }
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
                    Capsule().strokeBorder(
                        hovering && !disabled ? Color.rbAccent.opacity(0.30) : Color.rbHairline,
                        lineWidth: RB.Line.hair)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// 状态横幅（同步中/管线状态/导入导出结果）：
/// surface 70% 底 + hairline 描边的通栏胶囊行——比裸文本行更像"系统状态"，
/// 又不打断页面流。
struct StatusBanner<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: RB.Space.sm) { content }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: RB.Radius.lg)
                    .fill(Color.rbSurface.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: RB.Radius.lg)
                    .strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
            )
    }
}

extension View {
    /// 输入框底（搜索框/行内输入）：surface 圆角底 + hairline 描边；
    /// focused 时描边转墨蓝 40%——克制的焦点反馈，不用系统蓝环。
    func rbFieldBackground(focused: Bool = false) -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: RB.Radius.lg)
                    .fill(Color.rbSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RB.Radius.lg)
                    .strokeBorder(focused ? Color.rbAccent.opacity(0.4) : Color.rbHairline,
                                  lineWidth: RB.Line.hair)
            )
    }
}

/// 纸墨分段选择器（替代原生 segmented control）：
/// surface 胶囊容器 + hairline 描边；选中段墨蓝浅底 + 墨蓝字 medium。
/// 原生 segmented 带系统蓝、视觉重，与纸墨系不搭——中栏筛选/阅读区视图切换统一用这个。
struct RBSegmented<Item: Hashable>: View {
    let items: [(Item, String)]
    @Binding var selection: Item
    var fontSize: CGFloat = 11

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, entry in
                let (item, label) = entry
                let active = selection == item
                Button {
                    selection = item
                } label: {
                    Text(label)
                        .font(.system(size: fontSize, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? Color.rbAccent : Color.rbText2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(active ? Color.rbAccent.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.rbSurface))
        .overlay(
            Capsule().strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
        )
    }
}

/// RSS 经典三半圆图标（标准 RSS feed 标识）
/// 左下原点 + 两道弧线， universally recognized 的 RSS 符号
struct RSSIcon: View {
    var size: CGFloat = 11
    var color: Color = .primary

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 16  // 以 16×16 viewBox 为基准缩放
            let shading = GraphicsContext.Shading.color(color)
            // 左下原点
            let dotRect = CGRect(x: 2 * scale, y: 12 * scale, width: 2.5 * scale, height: 2.5 * scale)
            context.fill(Path(ellipseIn: dotRect), with: shading)
            // 内弧（第一道半圆）
            var innerArc = Path()
            innerArc.addArc(center: CGPoint(x: 2 * scale, y: 14 * scale),
                            radius: 6 * scale,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(0),
                            clockwise: false)
            context.stroke(innerArc, with: shading, lineWidth: 1.8 * scale)
            // 外弧（第二道半圆）
            var outerArc = Path()
            outerArc.addArc(center: CGPoint(x: 2 * scale, y: 14 * scale),
                            radius: 11 * scale,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(0),
                            clockwise: false)
            context.stroke(outerArc, with: shading, lineWidth: 1.8 * scale)
        }
        .frame(width: size, height: size)
    }
}

/// 播客音频播放器（AVPlayer 播放远程音频流）
/// 播放/暂停 + 进度条 + 时间显示，纸墨系配色
struct AudioPlayerView: View {
    let audioUrl: String
    let title: String
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 8) {
            // 播放控制行
            HStack(spacing: 12) {
                // 播放/暂停按钮
                Button {
                    togglePlay()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.rbAccent)
                }
                .buttonStyle(.plain)

                // 进度条 + 时间
                VStack(spacing: 4) {
                    // 进度条
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.rbSurface)
                                .frame(height: 4)
                            Capsule()
                                .fill(Color.rbAccent)
                                .frame(width: duration > 0 ? geo.size.width * CGFloat(currentTime / duration) : 0, height: 4)
                        }
                    }
                    .frame(height: 4)

                    // 时间显示
                    HStack {
                        Text(formatTime(currentTime))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.rbText3)
                        Spacer()
                        Text(formatTime(duration))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.rbText3)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.rbSurface)
        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
        .onAppear { setupPlayer() }
        .onDisappear { cleanup() }
    }

    private func setupPlayer() {
        guard let url = URL(string: audioUrl) else { return }
        player = AVPlayer(url: url)
        // 监听播放进度
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            guard let player = player else { return }
            currentTime = player.currentTime().seconds
            if let item = player.currentItem {
                duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
            }
            isPlaying = player.rate > 0
        }
    }

    private func togglePlay() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        player?.pause()
        player = nil
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
