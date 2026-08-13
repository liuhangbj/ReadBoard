import AVKit
import Foundation
import Observation
import ReadBoardContract
import ReadBoardUI
import SwiftUI
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum ReadBoardMediaPlayerLayout {
    public static let videoAspectRatio: CGFloat = 16.0 / 9.0
}

public struct ReadBoardPlaybackItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case audio
        case youtube
        case bilibili
    }

    public let summary: ContentSummary
    public let kind: Kind
    public let mediaURL: URL?
    public let videoID: String?
    public let pageURL: URL?

    public var id: Int64 { summary.id }
    public var title: String { summary.title }
    public var sourceName: String { summary.sourceName ?? summary.source }

    public var artworkURL: URL? {
        if let value = summary.imageURL,
           let url = URL(string: value),
           ["http", "https"].contains(url.scheme?.lowercased()) {
            return url
        }
        if kind == .youtube, let videoID {
            return URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
        }
        return nil
    }

    public init(
        summary: ContentSummary,
        kind: Kind,
        mediaURL: URL? = nil,
        videoID: String? = nil,
        pageURL: URL? = nil
    ) {
        self.summary = summary
        self.kind = kind
        self.mediaURL = mediaURL
        self.videoID = videoID
        self.pageURL = pageURL
    }

    public static func make(
        summary: ContentSummary,
        detail: ContentDetail
    ) -> ReadBoardPlaybackItem? {
        if summary.contentType.lowercased() == "podcast",
           let value = detail.audioURL,
           let url = playableURL(value) {
            return ReadBoardPlaybackItem(
                summary: summary,
                kind: .audio,
                mediaURL: url,
                pageURL: playableURL(summary.url))
        }

        let source = (summary.sourceType ?? summary.source).lowercased()
        let isVideo = ["video", "youtube"].contains(summary.contentType.lowercased())
            || source.contains("youtube")
            || source.contains("bilibili")
        guard isVideo,
              let videoID = detail.videoID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !videoID.isEmpty else { return nil }
        let platform = ReadBoardVideoPlayerPlatform.resolve(
            source: source,
            pageURL: playableURL(summary.url))
        return ReadBoardPlaybackItem(
            summary: summary,
            kind: platform == .bilibili ? .bilibili : .youtube,
            videoID: videoID,
            pageURL: playableURL(summary.url))
    }

    private static func playableURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }
}

public struct ReadBoardPlaybackNavigationRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let summary: ContentSummary

    public init(summary: ContentSummary, id: UUID = UUID()) {
        self.id = id
        self.summary = summary
    }
}

@MainActor
@Observable
public final class ReadBoardGlobalMediaPlayer {
    public private(set) var item: ReadBoardPlaybackItem?
    /// 只有用户真正启动过播放后，当前项目才属于应用级后台播放任务。
    /// 单纯预加载只服务于当前阅读详情，不应让左栏出现迷你播放器。
    public private(set) var hasUserStartedPlayback = false
    public private(set) var isPlaying = false
    public private(set) var isLoading = false
    public private(set) var isBuffering = false
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var errorMessage: String?
    public private(set) var playbackRate: Double
    public private(set) var avPlayer: AVPlayer?

    let webPlayerView: WKWebView
    #if os(macOS)
    let webPlayerParkingView = NSView()
    #else
    let webPlayerParkingView = UIView()
    #endif

    private let webPlayerNavigationDelegate = ReadBoardWebPlayerNavigationDelegate()
    private var loadTask: Task<Void, Never>?
    private var avTimeObserver: Any?
    private var webPlayerPollTimer: Timer?
    private var generation = 0
    private var shouldAutoplayWeb = false

    public init(mediaPlayback _: any MediaPlaybackGateway) {
        let savedRate = UserDefaults.standard.double(forKey: "player.playbackRate")
        playbackRate = ReadBoardAudioPlayback.speeds.contains(savedRate) ? savedRate : 1

        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webPlayerView = WKWebView(frame: .zero, configuration: configuration)
        webPlayerView.setValue(false, forKey: "drawsBackground")
        webPlayerNavigationDelegate.player = self
        webPlayerView.navigationDelegate = webPlayerNavigationDelegate
        parkWebPlayerView()
    }

    public func start(_ requestedItem: ReadBoardPlaybackItem) {
        if item?.id == requestedItem.id {
            hasUserStartedPlayback = true
            if errorMessage != nil || (!usesWebPlayer && avPlayer == nil) {
                prepareCurrentItem(autoplay: true)
            }
            else if usesWebPlayer, isLoading {
                shouldAutoplayWeb = true
            } else {
                togglePlayback()
            }
            return
        }
        item = requestedItem
        hasUserStartedPlayback = true
        prepareCurrentItem(autoplay: true)
    }

    public func prepare(_ requestedItem: ReadBoardPlaybackItem) {
        guard !hasUserStartedPlayback, item?.id != requestedItem.id else { return }
        item = requestedItem
        prepareCurrentItem(autoplay: false)
    }

    /// 详情页离开时只清理尚未播放的临时预加载；已经启动过的后台任务必须保留。
    public func discardPrepared(itemID: Int64) {
        guard !hasUserStartedPlayback, item?.id == itemID else { return }
        stop()
    }

    public func togglePlayback() {
        guard let item else { return }
        hasUserStartedPlayback = true
        switch item.kind {
        case .audio:
            guard let avPlayer else {
                prepareCurrentItem(autoplay: true)
                return
            }
            if avPlayer.timeControlStatus == .playing || avPlayer.rate > 0 {
                avPlayer.pause()
                isPlaying = false
            } else {
                errorMessage = nil
                avPlayer.defaultRate = Float(playbackRate)
                avPlayer.playImmediately(atRate: Float(playbackRate))
                isPlaying = true
            }
        case .youtube, .bilibili:
            if !isPlaying { shouldAutoplayWeb = true }
            Task { await toggleWebPlayback() }
        }
    }

    public func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    public func seek(to seconds: Double) {
        guard let item else { return }
        let target = ReadBoardAudioPlayback.clampedTime(seconds, duration: duration)
        currentTime = target
        switch item.kind {
        case .audio:
            avPlayer?.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: 0.2, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 0.2, preferredTimescale: 600))
        case .youtube, .bilibili:
            Task { @MainActor [weak self] in
                await self?.seekWeb(to: target)
            }
        }
    }

    public func setPlaybackRate(_ value: Double) {
        let safe = ReadBoardAudioPlayback.speeds.contains(value) ? value : 1
        playbackRate = safe
        UserDefaults.standard.set(safe, forKey: "player.playbackRate")
        avPlayer?.defaultRate = Float(safe)
        if isPlaying { avPlayer?.rate = Float(safe) }
        if usesWebPlayer {
            Task { await applyWebRate() }
        }
    }

    public func stop() {
        tearDownCurrentEngine(clearsWebContent: true)
        item = nil
        hasUserStartedPlayback = false
        errorMessage = nil
    }

    func webPlayerPageDidFinish() {
        guard usesWebPlayer else { return }
        isLoading = false
        startWebPlayerPolling()
        Task {
            await applyWebRate()
            if shouldAutoplayWeb { await playWeb() }
        }
    }

    func parkWebPlayerView() {
        guard webPlayerView.superview !== webPlayerParkingView else { return }
        webPlayerView.removeFromSuperview()
        webPlayerView.translatesAutoresizingMaskIntoConstraints = false
        webPlayerParkingView.addSubview(webPlayerView)
        NSLayoutConstraint.activate([
            webPlayerView.leadingAnchor.constraint(equalTo: webPlayerParkingView.leadingAnchor),
            webPlayerView.trailingAnchor.constraint(equalTo: webPlayerParkingView.trailingAnchor),
            webPlayerView.topAnchor.constraint(equalTo: webPlayerParkingView.topAnchor),
            webPlayerView.bottomAnchor.constraint(equalTo: webPlayerParkingView.bottomAnchor),
        ])
    }

    private func prepareCurrentItem(autoplay: Bool) {
        guard let item else { return }
        tearDownCurrentEngine(clearsWebContent: true)
        generation += 1
        let currentGeneration = generation
        currentTime = 0
        duration = 0
        errorMessage = nil
        isPlaying = false
        isBuffering = false
        isLoading = true

        switch item.kind {
        case .audio:
            guard let url = item.mediaURL else {
                fail("音频地址无效", generation: currentGeneration)
                return
            }
            installAVPlayer(url: url, autoplay: autoplay, generation: currentGeneration)
        case .youtube:
            guard let videoID = item.videoID,
                  videoID.range(
                    of: #"^[A-Za-z0-9_-]{6,32}$"#,
                    options: .regularExpression) != nil else {
                fail("视频 ID 无效", generation: currentGeneration)
                return
            }
            shouldAutoplayWeb = autoplay
            webPlayerView.loadHTMLString(
                youtubeEmbedHTML(videoID: videoID, autoplay: autoplay),
                baseURL: URL(string: "https://readboard.local"))
            startWebPlayerPolling()
        case .bilibili:
            guard let bvid = item.videoID,
                  var components = URLComponents(
                    string: "https://player.bilibili.com/player.html") else {
                fail("B站视频 ID 无效", generation: currentGeneration)
                return
            }
            shouldAutoplayWeb = autoplay
            components.queryItems = [
                URLQueryItem(name: "bvid", value: bvid),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "high_quality", value: "1"),
                URLQueryItem(name: "danmaku", value: "0"),
                URLQueryItem(name: "autoplay", value: autoplay ? "1" : "0"),
            ]
            guard let url = components.url else {
                fail("B站播放地址无效", generation: currentGeneration)
                return
            }
            var request = URLRequest(url: url, timeoutInterval: 45)
            request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            webPlayerView.load(request)
            startWebPlayerPolling()
        }
    }

    private func installAVPlayer(
        url: URL,
        autoplay: Bool,
        generation expectedGeneration: Int
    ) {
        guard generation == expectedGeneration else { return }
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 5
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = Float(playbackRate)
        avPlayer = player
        isLoading = false
        installAVTimeObserver(player, generation: expectedGeneration)
        if autoplay {
            player.playImmediately(atRate: Float(playbackRate))
            isPlaying = true
        }
        loadTask = Task { [weak self, weak asset] in
            guard let asset else { return }
            do {
                let loadedDuration = try await asset.load(.duration).seconds
                guard let self, self.generation == expectedGeneration,
                      loadedDuration.isFinite, loadedDuration > 0 else { return }
                duration = loadedDuration
            } catch {
                // Streaming playback can still succeed when duration metadata is late.
            }
        }
    }

    private func installAVTimeObserver(_ player: AVPlayer, generation expectedGeneration: Int) {
        avTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                guard let self, let player,
                      self.generation == expectedGeneration else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = max(0, seconds) }
                if let currentItem = player.currentItem {
                    let loadedDuration = currentItem.duration.seconds
                    if loadedDuration.isFinite && loadedDuration > 0 {
                        self.duration = loadedDuration
                    }
                    if currentItem.status == .failed {
                        self.errorMessage = currentItem.error?.localizedDescription
                            ?? player.error?.localizedDescription ?? "媒体加载失败"
                    }
                }
                self.isPlaying = player.timeControlStatus == .playing
                self.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
    }

    private func startWebPlayerPolling() {
        webPlayerPollTimer?.invalidate()
        webPlayerPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in await self?.pollWebPlayer() }
        }
    }

    private func pollWebPlayer() async {
        guard usesWebPlayer else { return }
        let result = await runWebScript("""
            const video = document.querySelector('video');
            const youtube = window.rbPlayer;
            const youtubeReady = youtube && typeof youtube.getCurrentTime === 'function';
            if (!video && !youtubeReady) { return null; }
            const currentTime = video ? video.currentTime : youtube.getCurrentTime();
            const duration = video ? video.duration : youtube.getDuration();
            const paused = video ? video.paused : youtube.getPlayerState() !== 1;
            const waiting = video ? video.readyState < 3 : youtube.getPlayerState() === 3;
            return {
                currentTime: Number.isFinite(currentTime) ? currentTime : 0,
                duration: Number.isFinite(duration) ? duration : 0,
                paused,
                waiting,
                error: window.rbPlayerError || 0
            };
            """)
        guard let state = result as? [String: Any] else { return }
        if item?.kind == .youtube,
           let errorCode = state["error"] as? NSNumber,
           errorCode.intValue != 0 {
            shouldAutoplayWeb = false
            isPlaying = false
            isBuffering = false
            errorMessage = "YouTube 播放失败（错误 \(errorCode.intValue)）"
            return
        }
        if let value = state["currentTime"] as? NSNumber { currentTime = value.doubleValue }
        if let value = state["duration"] as? NSNumber, value.doubleValue > 0 {
            duration = value.doubleValue
        }
        if let paused = state["paused"] as? Bool {
            isPlaying = !paused
            if !paused { hasUserStartedPlayback = true }
        }
        if let waiting = state["waiting"] as? Bool { isBuffering = waiting && isPlaying }
        isLoading = false
        if shouldAutoplayWeb, !isPlaying {
            await playWeb()
        }
    }

    private func toggleWebPlayback() async {
        let result = await runWebScript("""
            const video = document.querySelector('video');
            if (video) {
                if (video.paused) { await video.play(); return true; }
                video.pause(); return false;
            }
            const youtube = window.rbPlayer;
            if (!youtube || typeof youtube.getPlayerState !== 'function') { return null; }
            if (youtube.getPlayerState() === 1) { youtube.pauseVideo(); return false; }
            youtube.playVideo(); return true;
            """)
        if let result = result as? Bool {
            isPlaying = result
            shouldAutoplayWeb = false
        }
    }

    private func seekWeb(to target: Double) async {
        _ = await runWebScript("""
            const video = document.querySelector('video');
            if (video) { video.currentTime = \(target); return true; }
            const youtube = window.rbPlayer;
            if (youtube && typeof youtube.seekTo === 'function') {
                youtube.seekTo(\(target), true); return true;
            }
            return false;
            """)
    }

    private func playWeb() async {
        let result = await runWebScript("""
            const video = document.querySelector('video');
            if (video) {
                video.playbackRate = \(playbackRate);
                await video.play();
                return true;
            }
            const youtube = window.rbPlayer;
            if (!youtube || typeof youtube.playVideo !== 'function') { return false; }
            youtube.setPlaybackRate(\(playbackRate));
            youtube.playVideo();
            return true;
            """)
        if result as? Bool == true {
            shouldAutoplayWeb = false
            isPlaying = true
        }
    }

    private func applyWebRate() async {
        _ = await runWebScript("""
            const video = document.querySelector('video');
            if (video) { video.playbackRate = \(playbackRate); return true; }
            const youtube = window.rbPlayer;
            if (youtube && typeof youtube.setPlaybackRate === 'function') {
                youtube.setPlaybackRate(\(playbackRate)); return true;
            }
            return false;
            """)
    }

    private func runWebScript(_ script: String) async -> Any? {
        guard usesWebPlayer else { return nil }
        do {
            return try await webPlayerView.callAsyncJavaScript(
                script,
                arguments: [:],
                in: nil,
                contentWorld: .page)
        } catch {
            return nil
        }
    }

    private func youtubeEmbedHTML(videoID: String, autoplay: Bool) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
          <style>
            html, body, #player { width:100%; height:100%; margin:0; background:#000; overflow:hidden; }
          </style>
        </head>
        <body>
          <div id="player"></div>
          <script src="https://www.youtube.com/iframe_api"></script>
          <script>
            window.rbPlayer = null;
            window.rbPlayerError = null;
            function onYouTubeIframeAPIReady() {
              window.rbPlayer = new YT.Player('player', {
                videoId: '\(videoID)',
                width: '100%', height: '100%',
                playerVars: {
                  autoplay: \(autoplay ? 1 : 0), controls: 1, playsinline: 1,
                  rel: 0, origin: 'https://readboard.local'
                },
                events: {
                  onReady: function(event) {
                    event.target.setPlaybackRate(\(playbackRate));
                    if (\(autoplay ? "true" : "false")) { event.target.playVideo(); }
                  },
                  onError: function(event) { window.rbPlayerError = event.data; }
                }
              });
            }
          </script>
        </body>
        </html>
        """
    }

    private func fail(_ message: String, generation expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        isLoading = false
        isBuffering = false
        isPlaying = false
        errorMessage = message
    }

    private var usesWebPlayer: Bool {
        guard let kind = item?.kind else { return false }
        return kind != .audio
    }

    private func tearDownCurrentEngine(clearsWebContent: Bool) {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        if let avTimeObserver, let avPlayer {
            avPlayer.removeTimeObserver(avTimeObserver)
        }
        avTimeObserver = nil
        avPlayer?.pause()
        avPlayer?.currentItem?.cancelPendingSeeks()
        avPlayer = nil
        webPlayerPollTimer?.invalidate()
        webPlayerPollTimer = nil
        shouldAutoplayWeb = false
        if clearsWebContent {
            webPlayerView.stopLoading()
            webPlayerView.loadHTMLString("", baseURL: nil)
        }
        isPlaying = false
        isLoading = false
        isBuffering = false
        currentTime = 0
        duration = 0
    }
}

@MainActor
private final class ReadBoardWebPlayerNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var player: ReadBoardGlobalMediaPlayer?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        player?.webPlayerPageDidFinish()
    }
}

public struct ReadBoardGlobalMediaPlayerView: View {
    public let item: ReadBoardPlaybackItem
    public let player: ReadBoardGlobalMediaPlayer

    public init(item: ReadBoardPlaybackItem, player: ReadBoardGlobalMediaPlayer) {
        self.item = item
        self.player = player
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ReadBoardDesign.Space.sm) {
            if item.kind != .audio {
                // 用无固有尺寸的画布决定布局；异步封面和 WKWebView 只作为覆盖层。
                // 否则 YouTube 的 hqdefault.jpg（480×360）加载完成后会把首屏撑回 4:3。
                Color.black
                    .aspectRatio(
                        ReadBoardMediaPlayerLayout.videoAspectRatio,
                        contentMode: .fit)
                    .overlay {
                        videoSurface
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
            }

            if isActive {
                ReadBoardPlaybackControls(player: player, compact: false)
            } else {
                HStack(spacing: ReadBoardDesign.Space.md) {
                    ReadBoardPlaybackArtwork(item: item, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .readBoardInterfaceFont(size: 12, weight: .semibold)
                            .lineLimit(1)
                        Text(item.sourceName)
                            .readBoardInterfaceFont(size: 10)
                            .foregroundStyle(ReadBoardDesign.C.text3)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button { player.start(item) } label: {
                        Label("播放", systemImage: "play.fill")
                    }
                    .buttonStyle(ReadBoardPrimaryButtonStyle())
                }
            }
        }
        .padding(ReadBoardDesign.Space.md)
        .background(ReadBoardDesign.C.surface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg)
                .strokeBorder(ReadBoardDesign.C.hairline, lineWidth: ReadBoardDesign.Line.hair)
        }
    }

    @ViewBuilder
    private var videoSurface: some View {
        if isActive {
            ReadBoardWebGlobalSurface(player: player)
        } else {
            ZStack {
                ReadBoardPlaybackArtwork(item: item, size: nil)
                if isActive, player.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { player.start(item) } label: {
                        Image(systemName: "play.circle.fill")
                            .readBoardInterfaceFont(size: 42, weight: .medium)
                            .foregroundStyle(.white)
                            .shadow(radius: 5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.black)
        }
    }

    private var isActive: Bool { player.item?.id == item.id }
}

public struct ReadBoardMiniPlayerView: View {
    public let player: ReadBoardGlobalMediaPlayer
    public let openCurrentItem: () -> Void

    public init(
        player: ReadBoardGlobalMediaPlayer,
        openCurrentItem: @escaping () -> Void
    ) {
        self.player = player
        self.openCurrentItem = openCurrentItem
    }

    public var body: some View {
        if let item = player.item {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Button(action: openCurrentItem) {
                        ReadBoardPlaybackArtwork(item: item, size: 38)
                    }
                    .buttonStyle(.plain)
                    .help("返回正在播放的内容")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .readBoardInterfaceFont(size: 10, weight: .semibold)
                            .foregroundStyle(ReadBoardDesign.C.text)
                            .lineLimit(1)
                        Text(item.sourceName)
                            .readBoardInterfaceFont(size: 9)
                            .foregroundStyle(ReadBoardDesign.C.text3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if player.isLoading || player.isBuffering {
                        ProgressView().controlSize(.mini)
                    }
                    Button { player.stop() } label: {
                        Image(systemName: "xmark")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(ReadBoardQuietButtonStyle())
                    .help("关闭播放器")
                }

                ReadBoardPlaybackControls(player: player, compact: true)
            }
            .padding(9)
            .background(ReadBoardDesign.C.surface.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg)
                    .strokeBorder(ReadBoardDesign.C.hairline, lineWidth: 0.5)
            }
            .background(alignment: .topLeading) {
                if item.kind != .audio {
                    ReadBoardWebParkingSurface(player: player)
                        .frame(width: 1, height: 1)
                        .opacity(0.001)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct ReadBoardPlaybackControls: View {
    let player: ReadBoardGlobalMediaPlayer
    let compact: Bool
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    var body: some View {
        VStack(spacing: compact ? 5 : 7) {
            if !compact {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.item?.title ?? "")
                            .readBoardInterfaceFont(size: 12, weight: .semibold)
                            .lineLimit(1)
                        Text(player.item?.sourceName ?? "")
                            .readBoardInterfaceFont(size: 10)
                            .foregroundStyle(ReadBoardDesign.C.text3)
                            .lineLimit(1)
                    }
                    Spacer()
                    if player.isLoading || player.isBuffering {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : player.currentTime },
                    set: { scrubTime = $0 }),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        scrubTime = player.currentTime
                        isScrubbing = true
                    } else {
                        isScrubbing = false
                        player.seek(to: scrubTime)
                    }
                })
                .tint(ReadBoardDesign.C.accent)
                .disabled(player.duration <= 0)

            Group {
                if compact {
                    HStack(spacing: 8) {
                        Text(ReadBoardAudioPlayback.formatTime(
                            isScrubbing ? scrubTime : player.currentTime))
                            .frame(minWidth: 34, alignment: .leading)
                        Spacer(minLength: 0)
                        transportControls
                        Spacer(minLength: 0)
                        speedMenu
                    }
                } else {
                    HStack(spacing: 10) {
                        Text(ReadBoardAudioPlayback.formatTime(
                            isScrubbing ? scrubTime : player.currentTime))
                            .frame(minWidth: 34, alignment: .leading)
                        Spacer(minLength: 0)
                        transportControls
                        speedMenu
                        Spacer(minLength: 0)
                        Text(ReadBoardAudioPlayback.formatTime(player.duration))
                            .frame(minWidth: 34, alignment: .trailing)
                    }
                }
            }
            .buttonStyle(ReadBoardQuietButtonStyle())
            .readBoardInterfaceFont(size: compact ? 9 : 10)
            .foregroundStyle(ReadBoardDesign.C.text3)

            if let error = player.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .readBoardInterfaceFont(size: 9)
                    .foregroundStyle(ReadBoardDesign.C.scoreLow)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var transportControls: some View {
        HStack(spacing: compact ? 7 : 10) {
            Button { player.skip(by: -30) } label: {
                Image(systemName: "gobackward.30")
            }
            .help("后退 30 秒")
            Button { player.togglePlayback() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            Button { player.skip(by: 30) } label: {
                Image(systemName: "goforward.30")
            }
            .help("前进 30 秒")
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach(ReadBoardAudioPlayback.speeds, id: \.self) { value in
                Button {
                    player.setPlaybackRate(value)
                } label: {
                    if player.playbackRate == value {
                        Label(ReadBoardAudioPlayback.formatRate(value), systemImage: "checkmark")
                    } else {
                        Text(ReadBoardAudioPlayback.formatRate(value))
                    }
                }
            }
        } label: {
            Text(ReadBoardAudioPlayback.formatRate(player.playbackRate))
                .monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct ReadBoardPlaybackArtwork: View {
    let item: ReadBoardPlaybackItem
    let size: CGFloat?

    var body: some View {
        Group {
            if let url = item.artworkURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .frame(maxWidth: size == nil ? .infinity : nil, maxHeight: size == nil ? .infinity : nil)
        .clipped()
        .background(item.kind == .audio
            ? ReadBoardDesign.C.podcast.opacity(0.14)
            : Color.black)
        .clipShape(RoundedRectangle(cornerRadius: size == nil
            ? ReadBoardDesign.Radius.lg
            : ReadBoardDesign.Radius.md))
    }

    private var placeholder: some View {
        Image(systemName: item.kind == .audio ? "mic.fill" : "play.rectangle.fill")
            .readBoardInterfaceFont(size: size == nil ? 32 : 16, weight: .medium)
            .foregroundStyle(item.kind == .audio ? ReadBoardDesign.C.podcast : .white.opacity(0.82))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(macOS)
private struct ReadBoardGlobalAVPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Void) {
        view.player = nil
    }
}

private struct ReadBoardWebGlobalSurface: NSViewRepresentable {
    let player: ReadBoardGlobalMediaPlayer

    final class Coordinator {
        weak var player: ReadBoardGlobalMediaPlayer?
        init(player: ReadBoardGlobalMediaPlayer) { self.player = player }
    }

    func makeCoordinator() -> Coordinator { Coordinator(player: player) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(player.webPlayerView, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.player = player
        attach(player.webPlayerView, to: container)
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        container.subviews.forEach { $0.removeFromSuperview() }
        coordinator.player?.parkWebPlayerView()
    }

    private func attach(_ webView: WKWebView, to container: NSView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

private struct ReadBoardWebParkingSurface: NSViewRepresentable {
    let player: ReadBoardGlobalMediaPlayer

    func makeNSView(context: Context) -> NSView { player.webPlayerParkingView }

    func updateNSView(_ view: NSView, context: Context) {
        if player.webPlayerView.superview == nil { player.parkWebPlayerView() }
    }
}
#else
private struct ReadBoardGlobalAVPlayerSurface: View {
    let player: AVPlayer
    var body: some View { VideoPlayer(player: player) }
}

private struct ReadBoardWebGlobalSurface: UIViewRepresentable {
    let player: ReadBoardGlobalMediaPlayer

    final class Coordinator {
        weak var player: ReadBoardGlobalMediaPlayer?
        init(player: ReadBoardGlobalMediaPlayer) { self.player = player }
    }

    func makeCoordinator() -> Coordinator { Coordinator(player: player) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        attach(player.webPlayerView, to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        context.coordinator.player = player
        attach(player.webPlayerView, to: container)
    }

    static func dismantleUIView(_ container: UIView, coordinator: Coordinator) {
        container.subviews.forEach { $0.removeFromSuperview() }
        coordinator.player?.parkWebPlayerView()
    }

    private func attach(_ webView: WKWebView, to container: UIView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

private struct ReadBoardWebParkingSurface: UIViewRepresentable {
    let player: ReadBoardGlobalMediaPlayer

    func makeUIView(context: Context) -> UIView { player.webPlayerParkingView }

    func updateUIView(_ view: UIView, context: Context) {
        if player.webPlayerView.superview == nil { player.parkWebPlayerView() }
    }
}
#endif
