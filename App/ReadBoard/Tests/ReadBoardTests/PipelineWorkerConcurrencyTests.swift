import XCTest
@testable import ReadBoard

final class PipelineWorkerConcurrencyTests: XCTestCase {
    private actor ActivityProbe {
        private var active = 0
        private var peak = 0

        func enter() {
            active += 1
            peak = max(peak, active)
        }

        func leave() {
            active -= 1
        }

        func peakValue() -> Int { peak }
    }

    func testLLMLaneHonorsConfiguredConcurrencyLimit() async {
        let scheduler = PipelineWorkScheduler(llmLimit: 2)
        let probe = ActivityProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try? await scheduler.run(in: .llm) {
                        await probe.enter()
                        try await Task.sleep(nanoseconds: 40_000_000)
                        await probe.leave()
                        return true
                    }
                }
            }
        }

        let peak = await probe.peakValue()
        XCTAssertEqual(peak, 2)
    }

    func testTranscriptionLaneIsAlwaysSerial() async {
        // 即使 LLM 通道配到最大值，Whisper 通道仍固定为 1。
        let scheduler = PipelineWorkScheduler(llmLimit: 4)
        let probe = ActivityProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    _ = try? await scheduler.run(in: .transcription) {
                        await probe.enter()
                        try await Task.sleep(nanoseconds: 30_000_000)
                        await probe.leave()
                        return true
                    }
                }
            }
        }

        let peak = await probe.peakValue()
        XCTAssertEqual(peak, 1)
    }
}
