import Foundation
import XCTest
@testable import ReadBoard
import ReadBoardContract

final class RemoteAccessSecurityTests: XCTestCase {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("readboard-remote-tests-\(UUID().uuidString)")
            .appendingPathComponent("devices.json")
    }

    func testIssuedTokenIsPersistedOnlyAsHashAndCanBeRevoked() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = RemoteDeviceStore(fileURL: file)

        let credential = try await store.issue(deviceName: "My iPad")
        let initiallyValid = await store.validate(token: credential.token)
        XCTAssertTrue(initiallyValid)

        let persisted = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(persisted.contains(credential.token))
        XCTAssertTrue(persisted.contains(RemoteDeviceStore.hash(credential.token)))

        try await store.revoke(id: credential.deviceID)
        let validAfterRevoke = await store.validate(token: credential.token)
        XCTAssertFalse(validAfterRevoke)
    }

    func testPairingCodeIsSingleUse() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = RemoteDeviceStore(fileURL: file)
        let pairing = RemotePairingService(deviceStore: store)
        let challenge = await pairing.begin(serviceURLs: ["http://10.0.0.5:7331"])

        let credential = try await pairing.redeem(
            RemotePairingRequest(code: challenge.code, deviceName: "MacBook"))
        let valid = await store.validate(token: credential.token)
        XCTAssertTrue(valid)

        do {
            _ = try await pairing.redeem(
                RemotePairingRequest(code: challenge.code, deviceName: "Replay"))
            XCTFail("Expected a consumed pairing code")
        } catch let error as RemotePairingError {
            guard case .noActiveChallenge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHTTPPairingIssuesADeviceTokenWithoutBearerThenAuthorizesIt() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = RemoteDeviceStore(fileURL: file)
        let pairing = RemotePairingService(deviceStore: store)
        let challenge = await pairing.begin(serviceURLs: ["http://10.0.0.5:7331"])
        let router = ReadBoardHTTPRouter(services: .live, deviceStore: store,
                                         pairingService: pairing)
        let body = try JSONEncoder().encode(
            RemotePairingRequest(code: challenge.code, deviceName: "iPhone"))

        let paired = await router.handle(ReadBoardHTTPRequest(
            method: "POST", path: "/api/v1/pair",
            headers: ["X-ReadBoard-API-Version": ReadBoardAPI.version], body: body))
        XCTAssertEqual(paired.status, 201)
        let credential = try JSONDecoder().decode(RemotePairingCredential.self, from: paired.body)

        let authorized = await router.handle(ReadBoardHTTPRequest(
            method: "GET", path: "/api/v1/missing",
            headers: ["X-ReadBoard-API-Version": ReadBoardAPI.version,
                      "Authorization": "Bearer \(credential.token)"]))
        XCTAssertEqual(authorized.status, 404)

        try await store.revoke(id: credential.deviceID)
        let revoked = await router.handle(ReadBoardHTTPRequest(
            method: "GET", path: "/api/v1/missing",
            headers: ["X-ReadBoard-API-Version": ReadBoardAPI.version,
                      "Authorization": "Bearer \(credential.token)"]))
        XCTAssertEqual(revoked.status, 401)
    }

    func testFailedRevokeKeepsDeviceAuthorizedInMemory() async throws {
        let file = temporaryFile()
        let directory = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RemoteDeviceStore(fileURL: file)
        let credential = try await store.issue(deviceName: "Durable Device")

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        do {
            try await store.revoke(id: credential.deviceID)
            XCTFail("Expected persistence failure")
        } catch {
            let stillValid = await store.validate(token: credential.token)
            XCTAssertTrue(stillValid)
        }
    }

    func testReaderPairingCanInspectProfileButCannotManageConfiguration() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = RemoteDeviceStore(fileURL: file)
        let pairing = RemotePairingService(deviceStore: store)
        let challenge = await pairing.begin(serviceURLs: ["http://10.0.0.5:7331"],
                                            scopes: RemoteAccessScope.reader)
        let credential = try await pairing.redeem(
            RemotePairingRequest(code: challenge.code, deviceName: "ReadBoard Go"))
        let router = ReadBoardHTTPRouter(services: .live, deviceStore: store,
                                         pairingService: pairing)
        let headers = ["X-ReadBoard-API-Version": ReadBoardAPI.version,
                       "Authorization": "Bearer \(credential.token)"]

        let profileResponse = await router.handle(ReadBoardHTTPRequest(
            method: "GET", path: "/api/v1/server/profile", headers: headers))
        XCTAssertEqual(profileResponse.status, 200)
        let profile = try JSONDecoder().decode(RemoteServerProfile.self,
                                               from: profileResponse.body)
        XCTAssertEqual(profile.grantedScopes, RemoteAccessScope.reader)
        XCTAssertTrue(profile.capabilities.contains(.sourceManagement))

        let configurationResponse = await router.handle(ReadBoardHTTPRequest(
            method: "GET", path: "/api/v1/configuration", headers: headers))
        XCTAssertEqual(configurationResponse.status, 403)
    }

    func testLegacyDeviceRecordWithoutScopesReceivesFullControl() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let token = "legacy-secret"
        let json = """
        [{"id":"legacy","name":"旧设备","tokenHash":"\(RemoteDeviceStore.hash(token))",\
        "createdAt":1}]
        """
        try Data(json.utf8).write(to: file)
        let store = RemoteDeviceStore(fileURL: file)

        let scopes = await store.authorization(token: token)
        XCTAssertEqual(scopes, RemoteAccessScope.fullControl)
    }
}
