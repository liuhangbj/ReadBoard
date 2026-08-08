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

    func testRemoteAccessContractRoundTripDoesNotContainServerTokenHashes() throws {
        let value = RemoteAccessSnapshot(
            configuration: RemoteAccessConfiguration(enabled: true, allowLAN: true, port: 7331),
            state: .running,
            serviceURLs: ["http://10.0.0.5:7331"],
            devices: [PairedRemoteDevice(id: "device", name: "iPad", createdAt: 1)])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(RemoteAccessSnapshot.self, from: data), value)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("tokenHash"))
        XCTAssertFalse(text.contains("token\":"))
    }
}
