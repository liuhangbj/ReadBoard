import XCTest
import ReadBoardContract
@testable import ReadBoard

final class LocalProcessingGatewayTests: XCTestCase {
    private let sourceID: Int64 = 9_262_001
    private let contentID: Int64 = 9_262_011

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["READBOARD_DB"] != nil else {
            throw XCTSkip("需要 READBOARD_DB 指向隔离临时数据库")
        }
        let db = Database.shared
        XCTAssertTrue(db.open())
        cleanup()
        XCTAssertTrue(db.execute("""
            INSERT INTO content_source(id, stype, name, identifier, config, enabled)
            VALUES (?, 'podcast', '处理 Gateway 测试源', ?, '{}', 1);
            """, params: [sourceID, "https://test.invalid/processing-source-\(sourceID)"]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content(
                id, source_id, ctype, guid, source, title, url, excerpt,
                fetch_status, content_md, llm_transcript_md, meta)
            VALUES (?, ?, 'podcast', ?, 'podcast', '处理契约测试', ?, '简介',
                    4, '# 原文', '待删除转录稿',
                    '{"audio_url":"https://example.com/audio.mp3"}');
            """, params: [
                contentID, sourceID, "processing-guid-\(contentID)",
                "https://test.invalid/processing/\(contentID)"
            ]))
        XCTAssertTrue(db.execute("""
            INSERT INTO content_job(content_id, jtype, status)
            VALUES (?, 'transcribe', 2);
            """, params: [contentID]))
    }

    override func tearDownWithError() throws {
        if ProcessInfo.processInfo.environment["READBOARD_DB"] != nil { cleanup() }
    }

    func testNoEnabledWorkCompletesAndRetryReturnsSameCommand() async throws {
        let gateway = LocalProcessingGateway(database: .shared)
        let command = ProcessingCommand(
            requestID: "no-work-command", contentID: contentID, operation: .allEnabled)

        _ = try await gateway.submit(command)
        let finished = try await waitForTerminal(command.requestID, gateway: gateway)
        XCTAssertEqual(finished.state, .noWork)
        XCTAssertFalse(finished.contentChanged)

        let retried = try await gateway.submit(command)
        XCTAssertEqual(retried, finished)
    }

    func testDeleteTranscriptIsAtomicAndIdempotentByRequestID() async throws {
        let gateway = LocalProcessingGateway(database: .shared)
        let command = ProcessingCommand(
            requestID: "delete-transcript-command",
            contentID: contentID,
            operation: .deleteTranscript)

        _ = try await gateway.submit(command)
        let finished = try await waitForTerminal(command.requestID, gateway: gateway)

        XCTAssertEqual(finished.state, .succeeded)
        XCTAssertTrue(finished.contentChanged)
        XCTAssertNil(Database.shared.scalarString(
            "SELECT llm_transcript_md FROM content WHERE id=?", params: [contentID]))
        XCTAssertEqual(Database.shared.scalarInt(
            "SELECT COUNT(*) FROM content_job WHERE content_id=? AND jtype='transcribe'",
            params: [contentID]), 0)
        let retried = try await gateway.submit(command)
        XCTAssertEqual(retried, finished)
    }

    func testBusyContentReturnsTerminalBusyWithoutRunningPipeline() async throws {
        let gateway = LocalProcessingGateway(database: .shared)
        let targetContentID = contentID
        let locked = await MainActor.run {
            PipelineWorker.shared.tryLockContent(targetContentID)
        }
        XCTAssertTrue(locked)

        let snapshot = try await gateway.submit(ProcessingCommand(
            requestID: "busy-command", contentID: targetContentID, operation: .score))
        await MainActor.run { PipelineWorker.shared.unlockContent(targetContentID) }

        XCTAssertEqual(snapshot.state, .busy)
        XCTAssertTrue(snapshot.state.isTerminal)
        XCTAssertFalse(snapshot.contentChanged)
    }

    private func waitForTerminal(
        _ requestID: String,
        gateway: LocalProcessingGateway
    ) async throws -> ProcessingCommandSnapshot {
        for _ in 0..<100 {
            let snapshot = try await gateway.status(requestID: requestID)
            if snapshot.state.isTerminal { return snapshot }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("处理命令未在测试时限内完成")
        return try await gateway.status(requestID: requestID)
    }

    private func cleanup() {
        let db = Database.shared
        db.execute("DELETE FROM content_job WHERE content_id=?", params: [contentID])
        db.execute("DELETE FROM content WHERE id=?", params: [contentID])
        db.execute("DELETE FROM content_source WHERE id=?", params: [sourceID])
    }
}
