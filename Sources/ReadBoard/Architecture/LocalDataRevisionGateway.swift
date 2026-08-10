import ReadBoardContract

public struct LocalDataRevisionGateway: DataRevisionGateway, Sendable {
    public init() {}

    public func snapshot() async throws -> DataRevisionSnapshot {
        return await Task.detached(priority: .utility) { () -> DataRevisionSnapshot in
            let rows = Database.shared.queryRows(
                "SELECT domain, revision FROM data_revision")
            var values: [String: Int64] = [:]
            for row in rows {
                guard let domain = row["domain"], let raw = row["revision"],
                      let revision = Int64(raw) else { continue }
                values[domain] = revision
            }
            return DataRevisionSnapshot(
                library: values["library"] ?? 0,
                sources: values["sources"] ?? 0,
                operations: values["operations"] ?? 0)
        }.value
    }
}
