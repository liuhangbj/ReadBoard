#if os(macOS)
import AppKit
import UniformTypeIdentifiers

@objc(ReadBoardShareViewController)
public final class ShareViewController: NSViewController {
    private let statusLabel = NSTextField(labelWithString: "正在添加到 ReadBoard…")

    public override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 92))
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        self.view = view
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        extractURL()
    }

    private func extractURL() {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] value, _ in
                let url = value as? URL ?? (value as? String).flatMap(URL.init(string:))
                DispatchQueue.main.async { self?.finish(url) }
            }
            return
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] value, _ in
                let text = value as? String
                DispatchQueue.main.async {
                    self?.finish(text.flatMap(Self.firstWebURL))
                }
            }
            return
        }
        finish(nil)
    }

    private func finish(_ sharedURL: URL?) {
        guard let sharedURL,
              ["http", "https"].contains(sharedURL.scheme?.lowercased() ?? "") else {
            statusLabel.stringValue = "没有找到可用链接"
            complete(after: 0.8)
            return
        }
        let scheme = Bundle.main.object(forInfoDictionaryKey: "ReadBoardCallbackScheme") as? String
            ?? "readboard"
        var components = URLComponents()
        components.scheme = scheme
        components.host = "inbox"
        components.queryItems = [
            URLQueryItem(name: "url", value: sharedURL.absoluteString),
            URLQueryItem(name: "request_id", value: UUID().uuidString)
        ]
        guard let callback = components.url else {
            statusLabel.stringValue = "链接格式无效"
            complete(after: 0.8)
            return
        }
        extensionContext?.open(callback) { [weak self] opened in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = opened ? "已发送到 ReadBoard" : "无法打开 ReadBoard"
                self?.complete(after: opened ? 0.2 : 1.0)
            }
        }
    }

    private func complete(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private static func firstWebURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap(\.url).first {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "")
        }
    }
}
#endif
