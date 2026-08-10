import Foundation
import ReadBoardContract

public struct LocalMediaPlaybackGateway: MediaPlaybackGateway {
    public init() {}

    public func youtubeStream(videoID: String) async throws -> MediaPlaybackSource {
        let pattern = #"^[A-Za-z0-9_-]{6,32}$"#
        guard videoID.range(of: pattern, options: .regularExpression) != nil else {
            throw MediaPlaybackGatewayError.invalidVideoID
        }
        let url = try await YouTubeStreamResolver.resolve(videoId: videoID)
        return MediaPlaybackSource(
            url: url.absoluteString,
            expiresAt: Date().addingTimeInterval(9 * 60).timeIntervalSince1970)
    }
}
