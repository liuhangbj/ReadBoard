import Foundation

// MARK: - OPML 导入/导出
// 订阅资产命脉：从 FreshRSS/Follo 迁入订阅，备份导出。
// OPML 结构: <outline text="文件夹"><outline text="源名" type="rss" xmlUrl="..."/></outline>

public struct OPMLResult {
    var foldersCreated = 0
    var sourcesAdded = 0
    var sourcesSkipped = 0    // 已存在(identifier 重复)
    var errors: [String] = []
}

public final class OPMLService: @unchecked Sendable {
    static let shared = OPMLService()
    private let db = Database.shared
    private init() {}

    // MARK: 导出

    /// 导出全部源(含文件夹结构)为 OPML 字符串
    func exportOPML() -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>ReadBoard 订阅导出</title>
            <dateCreated>\(Self.rfc822Now())</dateCreated>
          </head>
          <body>

        """
        // 按文件夹分组
        let folders = queryAll("SELECT id, name FROM folder ORDER BY name;")
        for f in folders {
            let fid = f["id"] ?? ""
            let fname = Self.esc(f["name"] ?? "")
            xml += "    <outline text=\"\(fname)\">\n"
            let sources = queryAll("SELECT name, identifier, stype FROM content_source WHERE folder_id = ? ORDER BY name;", params: [Int(fid) ?? 0])
            for s in sources { xml += sourceLine(s, indent: "      ") }
            xml += "    </outline>\n"
        }
        // 未分组
        let ungrouped = queryAll("SELECT name, identifier, stype FROM content_source WHERE folder_id IS NULL ORDER BY name;")
        for s in ungrouped { xml += sourceLine(s, indent: "    ") }

        xml += "  </body>\n</opml>\n"
        return xml
    }

    private func sourceLine(_ s: [String: String], indent: String) -> String {
        let name = Self.esc(s["name"] ?? "")
        let url = Self.esc(s["identifier"] ?? "")
        let stype = s["stype"] ?? "rss"
        // OPML 标准 type 只有 rss；播客/YouTube 用 rb:stype 自定义属性保真，导入时认回
        return "\(indent)<outline text=\"\(name)\" type=\"rss\" xmlUrl=\"\(url)\" rb:stype=\"\(stype)\"/>\n"
    }

    // MARK: 导入

    /// 从 OPML 字符串导入。outline 嵌套层 = 文件夹，叶子 = 源。
    /// 已存在的 identifier 跳过。返回统计。
    func importOPML(_ xml: String) -> OPMLResult {
        var result = OPMLResult()
        guard let data = xml.data(using: .utf8) else {
            result.errors.append("非 UTF-8 文本")
            return result
        }
        let parser = OPMLXMLParser()
        guard parser.parse(data: data) else {
            result.errors.append("OPML 解析失败（非合法 OPML）")
            return result
        }

        // 建文件夹 + 源
        for group in parser.groups {
            var folderId: Int64? = nil
            if let fname = group.folderName, !fname.isEmpty {
                db.execute("INSERT OR IGNORE INTO folder (name) VALUES (?)", params: [fname])
                if let id = db.scalarInt("SELECT id FROM folder WHERE name = ?", params: [fname]) {
                    folderId = Int64(id)
                    result.foldersCreated += 1
                }
            }
            for src in group.sources {
                // 去重：identifier 已存在跳过
                if let _ = db.scalarInt("SELECT id FROM content_source WHERE identifier = ?", params: [src.url]) {
                    result.sourcesSkipped += 1
                    continue
                }
                let ok = db.execute(
                    "INSERT INTO content_source (stype, name, identifier, enabled, folder_id, config) VALUES (?, ?, ?, 1, ?, '{}')",
                    params: [src.stype, src.title, src.url, folderId.map { Int($0) }]
                )
                if ok { result.sourcesAdded += 1 }
                else { result.errors.append("插入失败: \(src.title)") }
            }
        }
        return result
    }

    // MARK: 私有

    private func queryAll(_ sql: String, params: [Any?] = []) -> [[String: String]] {
        db.queryRows(sql, params: params)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func rfc822Now() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: Date())
    }
}

// MARK: - OPML XML 解析

private struct OPMLSource {
    let title: String
    let url: String
    let stype: String    // rb:stype 自定义属性保真（rss/podcast/youtube/wechat），无则按 URL 猜
}

private struct OPMLGroup {
    var folderName: String?    // nil = 未分组
    var sources: [OPMLSource]
}

private final class OPMLXMLParser: NSObject, XMLParserDelegate {
    var groups: [OPMLGroup] = []
    private var currentFolder: String? = nil
    private var folderSources: [OPMLSource] = []
    private var topLevelSources: [OPMLSource] = []
    private var depth = 0

    func parse(data: Data) -> Bool {
        let p = XMLParser(data: data)
        p.delegate = self
        return p.parse()
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes attr: [String: String]) {
        guard element == "outline" else { return }
        depth += 1
        let hasXmlUrl = attr["xmlUrl"] != nil
        if depth == 1 && !hasXmlUrl {
            // 第一层非叶子 = 文件夹
            currentFolder = attr["text"] ?? attr["title"]
            folderSources = []
        } else if hasXmlUrl, let url = attr["xmlUrl"] {
            let title = attr["text"] ?? attr["title"] ?? url
            // 类型保真：优先 rb:stype 自定义属性；无则按 URL 特征猜（YouTube feed / 音频型）
            let stype = attr["rb:stype"] ?? Self.guessType(url: url)
            let src = OPMLSource(title: title, url: url, stype: stype)
            if currentFolder != nil { folderSources.append(src) }
            else { topLevelSources.append(src) }
        }
    }

    /// 无 rb:stype 时按 URL 猜类型（兼容 FreshRSS/Follo 导出的纯 OPML）
    private static func guessType(url: String) -> String {
        let u = url.lowercased()
        if u.contains("youtube.com/feeds/videos.xml") || u.contains("youtube.com/feeds/") { return "youtube" }
        return "rss"
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName: String?) {
        guard element == "outline" else { return }
        if depth == 1, let fname = currentFolder {
            groups.append(OPMLGroup(folderName: fname, sources: folderSources))
            currentFolder = nil
            folderSources = []
        }
        depth -= 1
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        if !topLevelSources.isEmpty {
            groups.append(OPMLGroup(folderName: nil, sources: topLevelSources))
        }
    }
}
