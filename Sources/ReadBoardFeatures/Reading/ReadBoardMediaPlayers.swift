import AVKit
import Foundation
import ReadBoardContract
import ReadBoardUI
import SwiftUI
import WebKit

public enum ReadBoardVideoPlayerPlatform: Equatable, Sendable {
    case youtube
    case bilibili

    public static func resolve(source: String, pageURL: URL? = nil) -> Self {
        let source = source.lowercased()
        if source.contains("bilibili")
            || pageURL?.host?.lowercased().contains("bilibili.com") == true {
            return .bilibili
        }
        return .youtube
    }
}

public enum ReadBoardAudioPlayback {
    public static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 2]

    public static func clampedTime(_ value: Double, duration: Double) -> Double {
        guard value.isFinite else { return 0 }
        let upper = duration.isFinite && duration > 0 ? duration : max(value, 0)
        return min(max(value, 0), upper)
    }

    public static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    public static func formatRate(_ rate: Double) -> String {
        if rate == floor(rate) { return "\(Int(rate))×" }
        let decimals = rate * 10 == floor(rate * 10) ? 1 : 2
        return String(format: "%.*f×", decimals, rate)
    }
}

@MainActor
private final class ReadBoardAudioController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var isLoadingMetadata = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?

    private let url: URL
    private var asset: AVURLAsset?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var metadataTask: Task<Void, Never>?
    private var preferredRate: Float = 1
    private var generation = 0

    init(url: URL) { self.url = url }

    func setPreferredRate(_ value: Double) {
        let safe = ReadBoardAudioPlayback.speeds.contains(value) ? value : 1
        preferredRate = Float(safe)
        player?.defaultRate = preferredRate
        if isPlaying { player?.rate = preferredRate }
    }

    func toggle() {
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

    func preloadMetadata() {
        guard duration <= 0, metadataTask == nil else { return }
        let asset = resolveAsset()
        let currentGeneration = generation
        isLoadingMetadata = true
        metadataTask = Task { [weak self] in
            do {
                let loadedDuration = try await asset.load(.duration)
                guard !Task.isCancelled, let self,
                      self.generation == currentGeneration,
                      self.asset === asset else { return }
                let seconds = loadedDuration.seconds
                if seconds.isFinite && seconds > 0 { self.duration = seconds }
            } catch is CancellationError {
                return
            } catch {
                // Metadata failure does not prove that streaming playback will fail.
            }
            guard let self, self.generation == currentGeneration else { return }
            self.metadataTask = nil
            self.isLoadingMetadata = false
        }
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    func seek(to seconds: Double) {
        prepareIfNeeded()
        guard let player else { return }
        let target = ReadBoardAudioPlayback.clampedTime(seconds, duration: duration)
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600))
    }

    func cleanup() {
        generation += 1
        metadataTask?.cancel()
        metadataTask = nil
        player?.currentItem?.cancelPendingSeeks()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        asset = nil
        isPlaying = false
        isBuffering = false
        isLoadingMetadata = false
        currentTime = 0
        duration = 0
    }

    private func resolveAsset() -> AVURLAsset {
        if let asset { return asset }
        let value = AVURLAsset(url: url)
        asset = value
        return value
    }

    private func prepareIfNeeded() {
        guard player == nil else { return }
        let item = AVPlayerItem(asset: resolveAsset())
        item.preferredForwardBufferDuration = 5
        let value = AVPlayer(playerItem: item)
        value.automaticallyWaitsToMinimizeStalling = true
        value.defaultRate = preferredRate
        player = value
        preloadMetadata()
        timeObserver = value.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak value] time in
            MainActor.assumeIsolated {
                guard let self, let value else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = max(0, seconds) }
                if let item = value.currentItem {
                    let loadedDuration = item.duration.seconds
                    if loadedDuration.isFinite && loadedDuration > 0 {
                        self.duration = loadedDuration
                    }
                    if item.status == .failed {
                        self.errorMessage = item.error?.localizedDescription
                            ?? value.error?.localizedDescription ?? "媒体加载失败"
                    }
                }
                self.isPlaying = value.timeControlStatus == .playing
                self.isBuffering = value.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
    }
}

public struct ReadBoardAudioPlayerView: View {
    public let title: String
    @StateObject private var controller: ReadBoardAudioController
    @AppStorage("player.playbackRate") private var playbackRate: Double = 1
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    public init(url: URL, title: String) {
        self.title = title
        _controller = StateObject(wrappedValue: ReadBoardAudioController(url: url))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ReadBoardDesign.Space.md) {
            HStack(spacing: ReadBoardDesign.Space.sm) {
                Button { controller.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15").frame(width: 24, height: 24)
                }
                .buttonStyle(ReadBoardQuietButtonStyle())
                .help("后退 15 秒")

                Button { controller.toggle() } label: {
                    Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(ReadBoardDesign.C.accent)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)

                Button { controller.skip(by: 30) } label: {
                    Image(systemName: "goforward.30").frame(width: 24, height: 24)
                }
                .buttonStyle(ReadBoardQuietButtonStyle())
                .help("前进 30 秒")

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ReadBoardDesign.C.text)
                        .lineLimit(1)
                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubTime : controller.currentTime },
                            set: { scrubTime = $0 }),
                        in: 0...max(controller.duration, 1),
                        onEditingChanged: { editing in
                            if editing {
                                scrubTime = controller.currentTime
                                isScrubbing = true
                            } else {
                                isScrubbing = false
                                controller.seek(to: scrubTime)
                            }
                        })
                        .tint(ReadBoardDesign.C.accent)
                        .disabled(controller.duration <= 0)
                    HStack {
                        Text(ReadBoardAudioPlayback.formatTime(
                            isScrubbing ? scrubTime : controller.currentTime))
                        Spacer()
                        Text("−" + ReadBoardAudioPlayback.formatTime(max(
                            0, controller.duration - (isScrubbing ? scrubTime : controller.currentTime))))
                    }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ReadBoardDesign.C.text3)
                }
                Spacer(minLength: 0)

                if controller.isBuffering || controller.isLoadingMetadata {
                    ProgressView().controlSize(.small).frame(width: 16)
                }

                Menu {
                    ForEach(ReadBoardAudioPlayback.speeds, id: \.self) { value in
                        Button {
                            playbackRate = value
                            controller.setPreferredRate(value)
                        } label: {
                            if playbackRate == value {
                                Label(ReadBoardAudioPlayback.formatRate(value), systemImage: "checkmark")
                            } else {
                                Text(ReadBoardAudioPlayback.formatRate(value))
                            }
                        }
                    }
                } label: {
                    Text(ReadBoardAudioPlayback.formatRate(playbackRate))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(ReadBoardDesign.C.scoreLow)
                    .lineLimit(2)
            }
        }
        .padding(ReadBoardDesign.Space.md)
        .background(ReadBoardDesign.C.surface.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg)
                .strokeBorder(ReadBoardDesign.C.hairline, lineWidth: ReadBoardDesign.Line.hair)
        }
        .onAppear {
            controller.setPreferredRate(playbackRate)
            controller.preloadMetadata()
        }
        .onChange(of: playbackRate) { _, value in controller.setPreferredRate(value) }
        .onDisappear { controller.cleanup() }
    }
}

public struct ReadBoardYouTubePlayerView: View {
    public let videoID: String
    public let title: String
    private let gateway: any MediaPlaybackGateway
    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var isLoading = false

    public init(videoID: String, title: String, gateway: any MediaPlaybackGateway) {
        self.videoID = videoID
        self.title = title
        self.gateway = gateway
    }

    public var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
            } else if let errorMessage {
                ReadBoardArticleEmptyState(
                    title: "视频加载失败",
                    message: errorMessage,
                    icon: "play.slash",
                    retry: { Task { await load() } })
            } else {
                ZStack {
                    ReadBoardDesign.C.surface
                    VStack(spacing: ReadBoardDesign.Space.sm) {
                        if isLoading { ProgressView() }
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 28, weight: .light))
                        Text(isLoading ? "正在解析播放地址…" : title)
                            .font(.system(size: 11)).lineLimit(1)
                    }
                    .foregroundStyle(ReadBoardDesign.C.text3)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg)
                .strokeBorder(ReadBoardDesign.C.hairline, lineWidth: ReadBoardDesign.Line.hair)
        }
        .task(id: videoID) { await load() }
        .onDisappear { player?.pause() }
    }

    @MainActor
    private func load() async {
        guard player == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let source = try await gateway.youtubeStream(videoID: videoID)
            guard !Task.isCancelled, let url = URL(string: source.url) else { return }
            player = AVPlayer(url: url)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

public struct ReadBoardBilibiliPlayerView: View {
    public let bvid: String
    public let pageURL: URL?

    public init(bvid: String, pageURL: URL? = nil) {
        self.bvid = bvid
        self.pageURL = pageURL
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ReadBoardDesign.Space.sm) {
            ReadBoardBilibiliWebPlayer(bvid: bvid)
                .aspectRatio(16 / 9, contentMode: .fit)
            if let pageURL {
                Link("浏览器打开 B站视频", destination: pageURL)
                    .font(.system(size: 10))
            }
        }
        .padding(ReadBoardDesign.Space.md)
        .background(ReadBoardDesign.C.surface.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg)
                .strokeBorder(ReadBoardDesign.C.hairline, lineWidth: ReadBoardDesign.Line.hair)
        }
    }
}

#if os(macOS)
private struct ReadBoardBilibiliWebPlayer: NSViewRepresentable {
    let bvid: String
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString(html, baseURL: URL(string: "https://www.bilibili.com"))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    private var html: String { embedHTML(bvid: bvid) }
}
#else
private struct ReadBoardBilibiliWebPlayer: UIViewRepresentable {
    let bvid: String
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString(html, baseURL: URL(string: "https://www.bilibili.com"))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    private var html: String { embedHTML(bvid: bvid) }
}
#endif

private func embedHTML(bvid: String) -> String {
    """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>html,body,iframe{margin:0;width:100%;height:100%;background:#000;border:0;overflow:hidden}</style>
    </head><body><iframe src="https://player.bilibili.com/player.html?bvid=\(bvid)&autoplay=0&high_quality=1"
    allow="autoplay; fullscreen; picture-in-picture" allowfullscreen></iframe></body></html>
    """
}
