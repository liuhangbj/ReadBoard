import ReadBoardContract

public struct RemoteMediaPlaybackGateway: MediaPlaybackGateway {
    private let client: ReadBoardHTTPClient

    public init(client: ReadBoardHTTPClient) {
        self.client = client
    }

    public func youtubeStream(videoID: String) async throws -> MediaPlaybackSource {
        try await client.post(
            "api/v1/media/youtube/stream",
            body: MediaPlaybackRequest(videoID: videoID),
            as: MediaPlaybackSource.self)
    }
}
