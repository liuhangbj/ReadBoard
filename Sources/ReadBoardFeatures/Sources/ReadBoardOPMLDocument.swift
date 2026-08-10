import Foundation
import ReadBoardContract
import SwiftUI
import UniformTypeIdentifiers

public struct ReadBoardOPMLDocument: FileDocument {
    public static let contentType = UTType(filenameExtension: "opml") ?? .xml
    public static var readableContentTypes: [UTType] { [contentType, .xml] }

    public var text: String

    public init(text: String) {
        self.text = text
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw ReadBoardOPMLError.unreadableDocument
        }
        text = String(decoding: data, as: UTF8.self)
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

public enum ReadBoardOPMLError: LocalizedError {
    case unreadableDocument
    case invalidDocument
    case noSources

    public var errorDescription: String? {
        switch self {
        case .unreadableDocument: "无法读取 OPML 文件"
        case .invalidDocument: "OPML 文件格式无效"
        case .noSources: "OPML 文件中没有可导入的订阅源"
        }
    }
}

public enum ReadBoardOPMLParser {
    public static func parse(_ data: Data) throws -> [SourceBatchImportItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ReadBoardOPMLError.invalidDocument }
        guard !delegate.items.isEmpty else { throw ReadBoardOPMLError.noSources }
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [SourceBatchImportItem] = []
        private var folderStack: [String] = []
        private var outlineKinds: [Bool] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard elementName.lowercased() == "outline" else { return }
            let identifier = first(attributeDict, keys: ["xmlUrl", "xmlurl", "url", "htmlUrl"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let identifier, !identifier.isEmpty {
                outlineKinds.append(false)
                let name = first(attributeDict, keys: ["title", "text", "name"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let type = sourceType(attributes: attributeDict, identifier: identifier)
                let mode = SourceFetchMode(rawValue:
                    first(attributeDict, keys: ["fetchMode", "fetch_mode"]) ?? "")
                    ?? .automatic
                items.append(SourceBatchImportItem(
                    name: name?.isEmpty == false ? name! : identifier,
                    identifier: identifier,
                    sourceType: type,
                    folderName: folderStack.last,
                    policy: SourcePolicySnapshot(
                        autoScore: bool(attributeDict, "auto_score"),
                        autoTranslate: bool(attributeDict, "auto_translate"),
                        autoTranscribe: bool(attributeDict, "auto_transcribe"),
                        autoSummarize: bool(attributeDict, "auto_summarize")),
                    fetchMode: mode))
            } else {
                let folder = first(attributeDict, keys: ["title", "text", "name"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                outlineKinds.append(true)
                folderStack.append(folder)
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard elementName.lowercased() == "outline", let wasFolder = outlineKinds.popLast()
            else { return }
            if wasFolder { _ = folderStack.popLast() }
        }

        private func first(_ attributes: [String: String], keys: [String]) -> String? {
            for key in keys {
                if let value = attributes[key] { return value }
                if let value = attributes.first(where: {
                    $0.key.caseInsensitiveCompare(key) == .orderedSame
                })?.value { return value }
            }
            return nil
        }

        private func bool(_ attributes: [String: String], _ key: String) -> Bool {
            guard let raw = first(attributes, keys: [key])?.lowercased() else { return false }
            return ["1", "true", "yes", "on"].contains(raw)
        }

        private func sourceType(
            attributes: [String: String],
            identifier: String
        ) -> String {
            if let explicit = first(attributes, keys: ["sourceType", "source_type", "stype"]),
               !explicit.isEmpty { return explicit }
            let value = identifier.lowercased()
            if value.contains("youtube.com") || value.contains("youtu.be") { return "youtube" }
            if value.contains("bilibili.com") || value.hasPrefix("bvid:") { return "bilibili" }
            if value.contains("mp.weixin.qq.com") { return "wechat" }
            if first(attributes, keys: ["type"])?.lowercased() == "podcast" { return "podcast" }
            return "article"
        }
    }
}
