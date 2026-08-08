import Foundation

public enum ProcessingOperation: String, Codable, CaseIterable, Sendable {
    case allEnabled
    case fulltext
    case score
    case summarize
    case translate
    case transcribe
    case deleteTranscript
}

/// `requestID` 由客户端生成并在重试时保持不变，服务端据此保证命令幂等。
public struct ProcessingCommand: Codable, Equatable, Sendable {
    public let requestID: String
    public let contentID: Int64
    public let operation: ProcessingOperation

    public init(
        requestID: String = UUID().uuidString,
        contentID: Int64,
        operation: ProcessingOperation
    ) {
        self.requestID = requestID
        self.contentID = contentID
        self.operation = operation
    }
}

public enum ProcessingCommandState: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case noWork
    case busy

    public var isTerminal: Bool {
        switch self {
        case .queued, .running: false
        case .succeeded, .failed, .noWork, .busy: true
        }
    }
}

public struct ProcessingCommandSnapshot: Codable, Equatable, Sendable {
    public let requestID: String
    public let contentID: Int64
    public let operation: ProcessingOperation
    public let state: ProcessingCommandState
    public let message: String
    public let contentChanged: Bool
    public let updatedAt: Int64

    public init(
        requestID: String,
        contentID: Int64,
        operation: ProcessingOperation,
        state: ProcessingCommandState,
        message: String,
        contentChanged: Bool,
        updatedAt: Int64
    ) {
        self.requestID = requestID
        self.contentID = contentID
        self.operation = operation
        self.state = state
        self.message = message
        self.contentChanged = contentChanged
        self.updatedAt = updatedAt
    }
}

public struct ProcessingCapabilities: Codable, Equatable, Sendable {
    public let llmAvailable: Bool
    public let transcriptionAvailable: Bool
    public let fulltextAvailable: Bool

    public init(
        llmAvailable: Bool,
        transcriptionAvailable: Bool,
        fulltextAvailable: Bool
    ) {
        self.llmAvailable = llmAvailable
        self.transcriptionAvailable = transcriptionAvailable
        self.fulltextAvailable = fulltextAvailable
    }
}

public enum ProcessingGatewayError: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest
    case commandNotFound(String)
    case storageUnavailable
    case contentNotFound(Int64)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "处理请求无效"
        case .commandNotFound: return "处理任务不存在或已过期"
        case .storageUnavailable: return "内容存储不可用"
        case .contentNotFound: return "内容不存在或已被删除"
        }
    }
}

/// 长任务使用提交＋状态查询模型。远程实现可在内部映射为 Job API，
/// 不要求客户端维持一个可能持续数十分钟的 HTTP 请求。
public protocol ProcessingGateway: Sendable {
    func capabilities() async -> ProcessingCapabilities
    func submit(_ command: ProcessingCommand) async throws -> ProcessingCommandSnapshot
    func status(requestID: String) async throws -> ProcessingCommandSnapshot
}
