import SwiftUI
import AVFoundation
import AVKit
import WebKit

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
                // ⚠️ hover 状态链收敛（17:35 B3 对照实验实锤为 AG cycle 触发器）：
                // 原实现 onHover 无去重 + 每个变化都开 .animation 事务——ReadingView 每篇
                // 销毁重建时，指针下追踪区反复 enter/exit，拆解窗口内连写 @State → cycle → 闪退。
                // 改为只在值真变时才写 + 不开动画事务（视觉瞬切，交互一致）。
                .onHover { h in
                    if h != hovering { hovering = h }
                }
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
                .onHover { h in
                    if h != hovering { hovering = h }
                }
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
                .onHover { h in
                    if h != hovering { hovering = h }
                }
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
        // hover 状态链收敛（同 QuietButtonStyle，17:35 实锤为 AG cycle 触发器）
        .onHover { h in
            if h != hovering { hovering = h }
        }
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

/// 安静按钮样式的**无状态机版**（17:48 定案）：
/// 仅 ReadingView 使用——阅读区每篇文章销毁重建时，hover 追踪区 enter/exit 会
/// 在拆解窗口写 @State → AG cycle → 闪退（B3 静态按钮对照实验实锤稳定）。
/// 外观一致（无 hover 变色反馈，换来零状态机）。左栏/设置页保留带 hover 的 .quiet。
struct StaticQuietButtonStyle: ButtonStyle {
    var radius: CGFloat = RB.Radius.md

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.rbText2)
            .padding(RB.Space.xs)
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(configuration.isPressed ? Color.rbSurface : Color.clear)
            )
    }
}

extension ButtonStyle where Self == StaticQuietButtonStyle {
    static var staticQuiet: StaticQuietButtonStyle { StaticQuietButtonStyle() }
}

/// 胶囊操作按钮的**无状态机版**（ReadingView 专用，理由同上——B3 对照实验实锤稳定）。
struct StaticCapsuleButton: View {
    let title: String
    let icon: String
    var disabled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(disabled ? Color.rbText3 : Color.rbText2)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(disabled ? Color.rbSurface.opacity(0.5) : Color.rbSurface)
                )
                .overlay(
                    Capsule().strokeBorder(Color.rbHairline, lineWidth: RB.Line.hair)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// 纸墨分段选择器（替代原生 segmented control）：
/// surface 胶囊容器 + hairline 描边；选中段墨蓝浅底 + 墨蓝字 medium。
/// 原生 segmented 带系统蓝、视觉重，与纸墨系不搭——中栏筛选/阅读区视图切换统一用这个。
struct RBSegmented<Item: Hashable>: View {
    let items: [(Item, String)]
    @Binding var selection: Item
    var fontSize: CGFloat = 11
    /// 阅读器文稿标签使用：让每个标签等分占满可用宽度；其他筛选器继续保持紧凑宽度。
    var fillsAvailableWidth = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { idx in
                let (item, label) = items[idx]
                let active = selection == item
                // ⚠️ 10:04 最终根因：onTapGesture 改状态但不触发 AppKit「渲染提交」——
                // 日志实证 body 点击后 0.008s 立即重算、viewMode 也变，但屏幕不上屏，
                // 要等用户在任意位置（含程序外）点鼠标产生新事件循环，才把积压的渲染事务冲出来。
                // Button 的 action 有完整「点击→状态变更→立即渲染提交」链路，改回 Button 即根治。
                Button {
                    selection = item
                } label: {
                    Text(label)
                        .font(.system(size: fontSize, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? Color.rbAccent : Color.rbText2)
                        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, alignment: .center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(active ? Color.rbAccent.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
            }
        }
        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
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

enum AudioPlaybackSettings {
    static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    nonisolated static func clampedTime(_ value: Double, duration: Double) -> Double {
        guard value.isFinite else { return 0 }
        let upper = duration.isFinite && duration > 0 ? duration : max(value, 0)
        return min(max(value, 0), upper)
    }
}

/// AVPlayer 生命周期与观察器集中管理。播放器仍然惰性创建：不点播放不会请求远程媒体。
@MainActor
final class AudioPlayerController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?

    private let audioURL: String
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var preferredRate: Float = 1.0

    init(audioURL: String) {
        self.audioURL = audioURL
    }

    func setPreferredRate(_ rate: Double) {
        let safeRate = AudioPlaybackSettings.speeds.contains(rate) ? rate : 1.0
        preferredRate = Float(safeRate)
        player?.defaultRate = preferredRate
        if isPlaying { player?.rate = preferredRate }
    }

    func togglePlay() {
        prepareIfNeeded()
        guard let player else { return }
        if player.timeControlStatus == .playing || player.rate > 0 {
            player.pause()
            isPlaying = false
        } else {
            errorMessage = nil
            isBuffering = true
            player.defaultRate = preferredRate
            player.play()
        }
    }

    func skip(by seconds: Double) {
        prepareIfNeeded()
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        prepareIfNeeded()
        guard let player else { return }
        let target = AudioPlaybackSettings.clampedTime(seconds, duration: duration)
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600))
    }

    func cleanup() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        isBuffering = false
    }

    private func prepareIfNeeded() {
        guard player == nil else { return }
        guard let url = URL(string: audioURL), let scheme = url.scheme,
              scheme == "http" || scheme == "https" else {
            errorMessage = "媒体地址无效"
            return
        }
        let player = AVPlayer(url: url)
        player.defaultRate = preferredRate
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                guard let self, let player else { return }
                self.updateState(player: player, time: time)
            }
        }
    }

    private func updateState(player: AVPlayer, time: CMTime) {
        let seconds = time.seconds
        if seconds.isFinite { currentTime = max(0, seconds) }
        if let item = player.currentItem {
            let itemDuration = item.duration.seconds
            if itemDuration.isFinite && itemDuration > 0 { duration = itemDuration }
            if item.status == .failed {
                errorMessage = item.error?.localizedDescription ?? player.error?.localizedDescription ?? "媒体加载失败"
            }
        }
        isPlaying = player.timeControlStatus == .playing
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }
}

/// 播客播放器：自定义纸墨控制条 + AVPlayer 播放引擎。
/// 支持拖动进度、15 秒回退、30 秒前进、倍速、缓冲及失败提示；MP3/MP4 共用。
struct AudioPlayerView: View {
    let audioUrl: String
    let title: String
    @StateObject private var controller: AudioPlayerController
    @AppStorage("player.playbackRate") private var playbackRate: Double = 1.0
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    init(audioUrl: String, title: String) {
        self.audioUrl = audioUrl
        self.title = title
        _controller = StateObject(wrappedValue: AudioPlayerController(audioURL: audioUrl))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Button { controller.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 15))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.staticQuiet)
                .help("后退 15 秒")

                Button { controller.togglePlay() } label: {
                    Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.rbAccent)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .help(controller.isPlaying ? "暂停" : "播放")

                Button { controller.skip(by: 30) } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 15))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.staticQuiet)
                .help("前进 30 秒")

                VStack(spacing: 1) {
                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubTime : controller.currentTime },
                            set: { scrubTime = $0 }
                        ),
                        in: 0...max(controller.duration, 1),
                        onEditingChanged: { editing in
                            if editing {
                                scrubTime = controller.currentTime
                                isScrubbing = true
                            } else {
                                isScrubbing = false
                                controller.seek(to: scrubTime)
                            }
                        }
                    )
                    .tint(Color.rbAccent)
                    .disabled(controller.duration <= 0)
                    .frame(height: 24)

                    HStack {
                        Text(Self.formatTime(isScrubbing ? scrubTime : controller.currentTime))
                        Spacer()
                        Text("−" + Self.formatTime(max(0, controller.duration - (isScrubbing ? scrubTime : controller.currentTime))))
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.rbText3)
                }
                // 以 Slider 轨道而不是“轨道 + 时间”的整体中心与播放按钮对齐。
                .alignmentGuide(VerticalAlignment.center) { _ in 12 }

                if controller.isBuffering {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16)
                        .help("正在缓冲")
                }

                Menu {
                    ForEach(AudioPlaybackSettings.speeds, id: \.self) { rate in
                        Button {
                            playbackRate = rate
                            controller.setPreferredRate(rate)
                        } label: {
                            if playbackRate == rate {
                                Label(Self.formatRate(rate), systemImage: "checkmark")
                            } else {
                                Text(Self.formatRate(rate))
                            }
                        }
                    }
                } label: {
                    Text(Self.formatRate(playbackRate))
                        .font(.system(size: 11, weight: .medium))
                        .frame(minWidth: 36)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("播放速度")
            }

            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.rbScoreLow)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.rbSurface)
        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
        .accessibilityLabel("\(title) 播放器")
        .onAppear { controller.setPreferredRate(playbackRate) }
        .onChange(of: playbackRate) { _, rate in controller.setPreferredRate(rate) }
        .onDisappear { controller.cleanup() }
    }

    nonisolated static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    nonisolated static func formatRate(_ rate: Double) -> String {
        if rate == floor(rate) { return "\(Int(rate))×" }
        let decimals = rate * 10 == floor(rate * 10) ? 1 : 2
        return String(format: "%.*f×", decimals, rate)
    }
}

/// YouTube video player using yt-dlp -g (URL extraction only, no download) + AVPlayer.
/// yt-dlp -g returns direct stream URL in ~0.5s; AVPlayer streams directly from YouTube CDN.
/// WKWebView iframe embed is blocked by YouTube on macOS (Error 152/153 regardless of UA/Origin).
struct YouTubePlayerView: View {
    let videoId: String
    let title: String

    @State private var player: AVPlayer?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var timer: Timer?

    private var ytdlpBin: String { DependencyPaths.resolve(.ytdlp) ?? "yt-dlp" }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: RB.Radius.lg)
                    .fill(Color.black)
                if let player = player {
                    AVPlayerViewRepresentable(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
                } else if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Resolving URL...")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                } else if let err = loadError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.yellow.opacity(0.7))
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                        Button("Retry") { resolveAndPlay() }
                            .font(.system(size: 12))
                            .foregroundStyle(Color.rbAccent)
                    }
                } else {
                    Button {
                        resolveAndPlay()
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(Color.white.opacity(0.92))
                            Text("Click to load video")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.white.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                if player != nil {
                    Button {
                        togglePlay()
                    } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.rbAccent)
                    }
                    .buttonStyle(.plain)
                }

                if player != nil {
                    VStack(spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.rbBg)
                                    .frame(height: 4)
                                Capsule()
                                    .fill(Color.rbAccent)
                                    .frame(width: duration > 0 ? geo.size.width * CGFloat(currentTime / duration) : 0, height: 4)
                            }
                        }
                        .frame(height: 4)
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

                Button {
                    if let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.rbText3)
                }
                .buttonStyle(.plain)
                .help("Open in browser")

                Spacer()
            }
        }
        .padding(12)
        .background(Color.rbSurface)
        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
        .onDisappear { cleanup() }
    }

    private func resolveAndPlay() {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        Task {
            if let url = await resolveVideoURL() {
                await MainActor.run {
                    isLoading = false
                    startPlayback(url: url)
                }
            } else {
                await MainActor.run {
                    isLoading = false
                    loadError = "Could not resolve video URL.\nTry opening in browser."
                }
            }
        }
    }

    private func resolveVideoURL() async -> URL? {
        let watchUrl = "https://www.youtube.com/watch?v=\(videoId)"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ytdlpBin)
        proc.arguments = ["-g", "-f", "best[height<=720]/best", "--no-playlist", watchUrl]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let urls = output.components(separatedBy: "\n").filter { !$0.isEmpty }
            return urls.first.flatMap { URL(string: $0) }
        } catch {
            return nil
        }
    }

    private func startPlayback(url: URL) {
        let p = AVPlayer(url: url)
        player = p
        p.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in
            guard let p = player else { return }
            currentTime = p.currentTime().seconds
            if let item = p.currentItem {
                duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
            }
            isPlaying = p.rate > 0
        }
    }

    private func togglePlay() {
        guard let p = player else { return }
        if isPlaying { p.pause() } else { p.play() }
        isPlaying = p.rate > 0
    }

    private func formatTime(_ sec: Double) -> String {
        guard sec.isFinite, sec >= 0 else { return "--:--" }
        let m = Int(sec) / 60, s = Int(sec) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        player?.pause()
        player = nil
    }
}

/// AVPlayerView wrapper for SwiftUI on macOS
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
