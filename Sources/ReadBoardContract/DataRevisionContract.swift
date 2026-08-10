import Foundation

/// 服务端数据域的单调版本。客户端只比较版本，不依赖数据库时间或本机时钟。
public struct DataRevisionSnapshot: Codable, Equatable, Sendable {
    public let library: Int64
    public let sources: Int64
    public let operations: Int64

    public init(library: Int64 = 0, sources: Int64 = 0, operations: Int64 = 0) {
        self.library = library
        self.sources = sources
        self.operations = operations
    }
}

public protocol DataRevisionGateway: Sendable {
    func snapshot() async throws -> DataRevisionSnapshot
}

/// 兼容不提供版本接口的环境；值保持不变，不触发无意义刷新。
public struct StaticDataRevisionGateway: DataRevisionGateway {
    public init() {}
    public func snapshot() async throws -> DataRevisionSnapshot { DataRevisionSnapshot() }
}
