import XCTest
@testable import ReadBoardContract

final class ProcessingContractTests: XCTestCase {
    func testCommandAndSnapshotRoundTripWithStableRequestID() throws {
        let command = ProcessingCommand(
            requestID: "request-1", contentID: 42, operation: .transcribe)
        let commandData = try JSONEncoder().encode(command)
        XCTAssertEqual(
            try JSONDecoder().decode(ProcessingCommand.self, from: commandData),
            command)

        let snapshot = ProcessingCommandSnapshot(
            requestID: command.requestID,
            contentID: command.contentID,
            operation: command.operation,
            state: .running,
            message: "转录中…",
            contentChanged: false,
            updatedAt: 1_700_000_000)
        let snapshotData = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(
            try JSONDecoder().decode(ProcessingCommandSnapshot.self, from: snapshotData),
            snapshot)
        XCTAssertFalse(snapshot.state.isTerminal)
        XCTAssertTrue(ProcessingCommandState.succeeded.isTerminal)
    }
}
