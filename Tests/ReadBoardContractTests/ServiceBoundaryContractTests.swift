import XCTest
@testable import ReadBoardContract

final class ServiceBoundaryContractTests: XCTestCase {
    func testConfigurationNeverContainsPlaintextAPIKey() throws {
        let value = ServiceConfigurationSnapshot(llmProfiles: [
            LLMProfileMetadata(id: 0, baseURL: "https://example.com", model: "model",
                               hasAPIKey: true)
        ])
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertTrue(text.contains("hasAPIKey"))
        XCTAssertFalse(text.contains("\"apiKey\":"))
    }

    func testOperationalContractsRoundTripAsTransportValues() throws {
        let value = MaintenanceSnapshot(policy: CleanupPolicy(), usage: StorageUsage(),
            backups: [BackupRecord(id: "opaque", date: Date(timeIntervalSince1970: 1),
                                   sizeBytes: 42, displayName: "backup")], trash: [])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(MaintenanceSnapshot.self, from: data), value)
    }
}
