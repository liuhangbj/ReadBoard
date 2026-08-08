import XCTest
@testable import ReadBoard

final class HTTPTransportTests: XCTestCase {
    func testHealthDoesNotExposeConfigurationOrRequireToken() async throws {
        let router = ReadBoardHTTPRouter(services: .live, bearerToken: "secret")
        let response = await router.handle(.init(method: "GET", path: "/health", headers: [:]))
        XCTAssertEqual(response.status, 200)
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(text.contains("apiVersion"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("database"))
    }

    func testProtectedRouteRejectsMissingBearerToken() async throws {
        let router = ReadBoardHTTPRouter(services: .live, bearerToken: "secret")
        let response = await router.handle(.init(method: "GET", path: "/api/v1/configuration",
            headers: ["X-ReadBoard-API-Version": "1"]))
        XCTAssertEqual(response.status, 401)
    }

    func testProtectedRouteRejectsVersionMismatchBeforeDispatch() async throws {
        let router = ReadBoardHTTPRouter(services: .live, bearerToken: "secret")
        let response = await router.handle(.init(method: "GET", path: "/api/v1/configuration",
            headers: ["Authorization": "Bearer secret", "X-ReadBoard-API-Version": "2"]))
        XCTAssertEqual(response.status, 426)
        XCTAssertEqual(response.headers[ReadBoardAPI.versionHeader], ReadBoardAPI.version)
    }
}
