import Foundation

public enum ProcessingEnginePhase: String, Codable, Equatable, Sendable {
    case idle
    case scanning
    case working
}

public struct ProcessingQueueSnapshot: Codable, Equatable, Sendable {
    public let score: Int
    public let translate: Int
    public let summarize: Int
    public let transcribe: Int
    public let items: Int
    public let unread: Int

    public init(
        score: Int = 0,
        translate: Int = 0,
        summarize: Int = 0,
        transcribe: Int = 0,
        items: Int = 0,
        unread: Int = 0
    ) {
        self.score = score
        self.translate = translate
        self.summarize = summarize
        self.transcribe = transcribe
        self.items = items
        self.unread = unread
    }
}

public struct ActiveProcessingItem: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let title: String
    public let stage: String

    public init(id: Int64, title: String, stage: String) {
        self.id = id
        self.title = title
        self.stage = stage
    }
}

public struct RuntimeStatusSnapshot: Codable, Equatable, Sendable {
    public let phase: ProcessingEnginePhase
    public let lastSummary: String
    public let queue: ProcessingQueueSnapshot
    public let activeItems: [ActiveProcessingItem]
    public let processedCount: Int
    public let pausedFailureCount: Int
    public let updatedAt: TimeInterval

    public init(
        phase: ProcessingEnginePhase = .idle,
        lastSummary: String = "",
        queue: ProcessingQueueSnapshot = .init(),
        activeItems: [ActiveProcessingItem] = [],
        processedCount: Int = 0,
        pausedFailureCount: Int = 0,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.phase = phase
        self.lastSummary = lastSummary
        self.queue = queue
        self.activeItems = activeItems
        self.processedCount = processedCount
        self.pausedFailureCount = pausedFailureCount
        self.updatedAt = updatedAt
    }

    public var isRunning: Bool { phase != .idle }
}

public protocol RuntimeStatusGateway: Sendable {
    func snapshot(refreshCounts: Bool) async -> RuntimeStatusSnapshot
    func runProcessingScan() async
}
