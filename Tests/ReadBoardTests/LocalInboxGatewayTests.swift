import XCTest
@testable import ReadBoard
import ReadBoardContract

final class LocalInboxGatewayTests: XCTestCase {
    func testInvalidURLIsRejectedBeforeNetworkAccess() async {
        let gateway = LocalInboxGateway()
        do {
            _ = try await gateway.importURL(InboxImportRequest(url: "not a url"))
            XCTFail("expected invalid URL")
        } catch let error as InboxGatewayError {
            XCTAssertEqual(error, .invalidURL)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
