import Foundation
import ReadBoardContract

public final class LocalRuntimeStatusGateway: RuntimeStatusGateway, @unchecked Sendable {
    public init() {}

    public func snapshot(refreshCounts: Bool) async -> RuntimeStatusSnapshot {
        if refreshCounts {
            await MainActor.run { PipelineWorker.shared.requestPendingRefresh() }
        }
        return await MainActor.run {
            let worker = PipelineWorker.shared
            return RuntimeStatusSnapshot(
                phase: Self.makePhase(worker.phase),
                lastSummary: worker.lastSummary,
                queue: .init(
                    score: worker.pendingBreakdown.score,
                    translate: worker.pendingBreakdown.translate,
                    summarize: worker.pendingBreakdown.summarize,
                    transcribe: worker.pendingBreakdown.transcribe,
                    items: worker.pendingBreakdown.items,
                    unread: worker.pendingBreakdown.unread),
                activeItems: worker.currentItems.map {
                    .init(id: $0.id, title: $0.title, stage: $0.stage)
                },
                processedCount: worker.processedCount,
                pausedFailureCount: worker.deadLetterCount)
        }
    }

    public func runProcessingScan() async {
        await PipelineWorker.shared.runOnce()
    }

    private static func makePhase(_ phase: PipelineWorker.EnginePhase) -> ProcessingEnginePhase {
        switch phase {
        case .idle: .idle
        case .scanning: .scanning
        case .working: .working
        }
    }
}
