import XCTest
@testable import ReadBoardContract

final class ServiceBoundaryContractTests: XCTestCase {
    func testRemoteAccessPresetsKeepHostMaintenanceOutOfOperatorRole() {
        XCTAssertEqual(RemoteAccessPreset.reader.scopes, RemoteAccessScope.reader)
        XCTAssertEqual(RemoteAccessPreset.operatorAccess.scopes, RemoteAccessScope.operatorAccess)
        XCTAssertFalse(RemoteAccessScope.operatorAccess.contains(.manageConfiguration))
        XCTAssertFalse(RemoteAccessScope.operatorAccess.contains(.manageMaintenance))
        XCTAssertTrue(RemoteAccessScope.operatorAccess.contains(.runProcessing))
        XCTAssertTrue(RemoteAccessScope.operatorAccess.contains(.manageSources))
        XCTAssertEqual(RemoteAccessPreset.administrator.scopes, RemoteAccessScope.fullControl)
        XCTAssertEqual(RemoteAccessPreset.fullControl.scopes, RemoteAccessScope.fullControl)
    }

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

    func testRemoteServerProfileJSONRoundTrip() throws {
        let value = RemoteServerProfile(apiVersion: "1", serverName: "ReadBoard Pro",
            capabilities: RemoteServiceCapability.allCases,
            grantedScopes: RemoteAccessScope.reader, transportSecurity: "none")
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(RemoteServerProfile.self, from: data), value)
    }

    func testSourceOperationJobRoundTripAndTerminalState() throws {
        let value = SourceOperationJobSnapshot(
            id: "job-1",
            kind: .processingBackfill,
            scope: SourceScope(kind: .folder, id: 42),
            phase: .running,
            progress: 0.5,
            message: "处理中",
            startedAt: 1)
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(SourceOperationJobSnapshot.self, from: data), value)
        XCTAssertFalse(value.phase.isTerminal)
        XCTAssertTrue(SourceOperationJobPhase.succeeded.isTerminal)
    }

    func testDataRevisionRoundTripKeepsIndependentMonotonicDomains() throws {
        let value = DataRevisionSnapshot(library: 101, sources: 22, operations: 303)
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(DataRevisionSnapshot.self, from: data), value)
    }
}
