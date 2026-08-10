import Foundation

/// 服务端解析后返回的短期媒体播放地址。客户端不得持久化该 URL；过期后重新请求。
public struct MediaPlaybackSource: Codable, Equatable, Sendable {
    public let url: String
    public let expiresAt: TimeInterval?

    public init(url: String, expiresAt: TimeInterval? = nil) {
        self.url = url
        self.expiresAt = expiresAt
    }
}

public struct MediaPlaybackRequest: Codable, Equatable, Sendable {
    public let videoID: String

    public init(videoID: String) {
        self.videoID = videoID
    }
}

/// 阅读器媒体端口。需要本机工具解析的工作留在服务端，远程 Reader 只接收可播放地址。
public protocol MediaPlaybackGateway: Sendable {
    func youtubeStream(videoID: String) async throws -> MediaPlaybackSource
}

public enum MediaPlaybackGatewayError: LocalizedError, Equatable, Sendable {
    case invalidVideoID

    public var errorDescription: String? {
        switch self {
        case .invalidVideoID: "视频 ID 无效"
        }
    }
}
