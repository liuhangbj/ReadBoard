import AppKit
import Foundation
import ReadBoardContract

@MainActor
final class InboxURLHandler {
    static let shared = InboxURLHandler()

    private var inbox: (any InboxGateway)?
    private var pending: [URL] = []

    private init() {}

    func configure(inbox: any InboxGateway) {
        self.inbox = inbox
        let values = pending
        pending.removeAll()
        values.forEach(handle)
    }

    func handle(_ url: URL) {
        guard let request = Self.importRequest(from: url) else { return }
        guard let inbox else {
            pending.append(url)
            return
        }
        Task {
            do {
                let result = try await inbox.importURL(request)
                NotificationCenter.default.post(
                    name: .readBoardInboxImportCompleted, object: result)
            } catch {
                NotificationCenter.default.post(
                    name: .readBoardInboxImportFailed,
                    object: error.localizedDescription)
            }
        }
    }

    private static func importRequest(from callback: URL) -> InboxImportRequest? {
        guard callback.host == "inbox" || callback.host == "add" else { return nil }
        let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        guard let raw = components?.queryItems?.first(where: { $0.name == "url" })?.value else {
            return nil
        }
        let requestID = components?.queryItems?.first(where: { $0.name == "request_id" })?.value
            ?? UUID().uuidString
        let rawKind = components?.queryItems?.first(where: { $0.name == "kind" })?.value
        let kind = rawKind.flatMap(InboxContentKind.init(rawValue:)) ?? .automatic
        return InboxImportRequest(requestID: requestID, url: raw, suggestedKind: kind)
    }
}

extension Notification.Name {
    static let readBoardInboxImportCompleted = Notification.Name("readBoardInboxImportCompleted")
    static let readBoardInboxImportFailed = Notification.Name("readBoardInboxImportFailed")
}
