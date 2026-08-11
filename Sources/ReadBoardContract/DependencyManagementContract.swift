import Foundation

public enum DependencyTaskOperation: String, Codable, CaseIterable, Sendable {
    case install
    case update
    case redetect
}

public enum DependencyTaskPhase: String, Codable, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

public struct DependencyTaskRequest: Codable, Equatable, Sendable {
    public let dependencyID: String
    public let operation: DependencyTaskOperation

    public init(dependencyID: String, operation: DependencyTaskOperation) {
        self.dependencyID = dependencyID
        self.operation = operation
    }
}

public struct DependencyTaskSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let dependencyID: String
    public let operation: DependencyTaskOperation
    public let phase: DependencyTaskPhase
    public let progress: Double?
    public let message: String
    public let startedAt: TimeInterval
    public let finishedAt: TimeInterval?

    public init(
        id: String,
        dependencyID: String,
        operation: DependencyTaskOperation,
        phase: DependencyTaskPhase,
        progress: Double? = nil,
        message: String,
        startedAt: TimeInterval = Date().timeIntervalSince1970,
        finishedAt: TimeInterval? = nil
    ) {
        self.id = id
        self.dependencyID = dependencyID
        self.operation = operation
        self.phase = phase
        self.progress = progress
        self.message = message
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct DependencyManagementSnapshot: Codable, Equatable, Sendable {
    public let dependencies: [DependencyStatus]
    public let tasks: [DependencyTaskSnapshot]

    public init(
        dependencies: [DependencyStatus] = [],
        tasks: [DependencyTaskSnapshot] = []
    ) {
        self.dependencies = dependencies
        self.tasks = tasks
    }
}

public protocol DependencyManagementGateway: Sendable {
    func snapshot() async throws -> DependencyManagementSnapshot
    func submit(_ request: DependencyTaskRequest) async throws -> DependencyTaskSnapshot
    func cancel(taskID: String) async
}
