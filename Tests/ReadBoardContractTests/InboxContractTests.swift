import XCTest
@testable import ReadBoardContract

final class InboxContractTests: XCTestCase {
    func testConfigurationDefaultsDoNotSpendAIRequests() {
        let value = InboxConfiguration()
        XCTAssertTrue(value.articleTargets.fulltext)
        XCTAssertFalse(value.articleTargets.score)
        XCTAssertFalse(value.articleTargets.summary)
        XCTAssertFalse(value.articleTargets.translate)
        XCTAssertFalse(value.podcastTargets.transcribe)
        XCTAssertFalse(value.videoTargets.transcribe)
    }

    func testLegacyContentFilterStillDecodesWithoutInboxField() throws {
        let data = Data("""
        {"includeUnscored":false,"readState":"all","exportedOnly":false,
         "processing":[],"unmetProcessingOnly":false}
        """.utf8)
        let value = try JSONDecoder().decode(ContentFilter.self, from: data)
        XCTAssertNil(value.inboxOnly)
    }

    func testInboxWriteReusesExistingLibraryWritePermission() {
        XCTAssertTrue(RemoteAccessScope.reader.contains(.updateReadingState))
    }
}
