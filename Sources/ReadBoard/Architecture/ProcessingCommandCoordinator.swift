import Foundation
import ReadBoardContract

/// 把稳定命令状态映射到现有 SwiftUI 状态库。未来 HTTP Gateway 仍复用这一层。
@MainActor
enum ProcessingCommandCoordinator {
    static func start(
        gateway: any ProcessingGateway,
        contentID: Int64,
        title: String,
        operation: ProcessingOperation,
        trackProgress: Bool = true,
        onCompletion: (@MainActor (ProcessingCommandSnapshot) -> Void)? = nil
    ) {
        let command = ProcessingCommand(contentID: contentID, operation: operation)
        Task {
            do {
                var snapshot = try await gateway.submit(command)
                if snapshot.state == .busy {
                    if trackProgress {
                        ContentProcessingStateStore.shared.notice(
                            contentId: contentID, message: "⏳ \(snapshot.message)")
                    }
                    onCompletion?(snapshot)
                    return
                }

                if trackProgress {
                    ContentProcessingStateStore.shared.enqueue(
                        contentId: contentID,
                        title: title,
                        operation: operationName(operation))
                    apply(snapshot)
                }

                while !snapshot.state.isTerminal {
                    try await Task.sleep(for: .milliseconds(300))
                    snapshot = try await gateway.status(requestID: command.requestID)
                    if trackProgress { apply(snapshot) }
                }

                if snapshot.contentChanged {
                    NotificationCenter.default.post(name: .contentUpdated, object: nil)
                }
                onCompletion?(snapshot)
            } catch {
                if trackProgress {
                    ContentProcessingStateStore.shared.finish(
                        contentId: contentID,
                        message: "❌ \(error.localizedDescription)",
                        succeeded: false)
                }
            }
        }
    }

    private static func apply(_ snapshot: ProcessingCommandSnapshot) {
        switch snapshot.state {
        case .queued:
            break
        case .running:
            ContentProcessingStateStore.shared.begin(
                contentId: snapshot.contentID,
                message: snapshot.message)
        case .succeeded, .noWork:
            ContentProcessingStateStore.shared.finish(
                contentId: snapshot.contentID,
                message: snapshot.message,
                succeeded: true)
        case .failed:
            ContentProcessingStateStore.shared.finish(
                contentId: snapshot.contentID,
                message: snapshot.message.contains("❌")
                    ? snapshot.message : "❌ \(snapshot.message)",
                succeeded: false)
        case .busy:
            ContentProcessingStateStore.shared.notice(
                contentId: snapshot.contentID,
                message: "⏳ \(snapshot.message)")
        }
    }

    private static func operationName(_ operation: ProcessingOperation) -> String {
        switch operation {
        case .allEnabled: "内容处理"
        case .fulltext: "提取全文"
        case .score: "AI 评分"
        case .summarize: "AI 摘要"
        case .translate: "AI 翻译"
        case .transcribe: "AI 转录"
        case .deleteTranscript: "删除转录稿"
        }
    }
}
