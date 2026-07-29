import Foundation

// MARK: - OPML 导入/导出
// 订阅资产命脉：从 FreshRSS/Follo 迁入订阅，备份导出。
// OPML 结构: <outline text="文件夹"><outline text="源名" type="rss" xmlUrl="..."/></outline>

/// 单个待导入源（解析阶段产出，尚未写库）
public struct OPMLOutline: Identifiable, Hashable {
    public let id = UUID()
    var title: String
    var url: String
    var stypeGuess: String       // 解析阶段按 rb:stype / URL 猜（预检会按内容校正）
    var folderName: String?      // nil = 未分组
}

/// 无副作用的导入解析结果：仅收集所有 outline + 已存在计数，不写库。
/// 真正写库由 OPMLImportSummary 确认后调用 SourceStore 完成。
public struct OPMLImportPlan {
    var outlines: [OPMLOutline] = []    // 全部叶子（含文件夹关系），去重前
    var parseError: String? = nil
}

/// 汇总确认页的一行：已检测类型 + 全文模式 + 是否已在库
public struct OPMLImportItem: Identifiable {
    public let id = UUID()
    var name: String
    var url: String
    var stype: String            // article / podcast / youtube（内容探测结果，可改）
    var fetchModeRaw: String     // FetchMode rawValue（检测所得，可改）
    var folderName: String?      // nil = 未分组
    var inLibrary: Bool          // 该 url 已在订阅源列表（确认时跳过）
    var detecting: Bool = false  // 后台检测进行中
    var status: ImportRowStatus = .pending   // 行内状态：正常 / 地址不通(红) / 列表内重复(黄)
}

/// OPML 导入单行状态（红=地址不通将跳过；黄=列表内重复将跳过；二者都应提示）
public enum ImportRowStatus: Equatable {
    case pending      // 未检测 / 正常待添加
    case duplicate    // 与本次列表内其他项 url 重复（黄色叹号，确认时跳过）
    case unreachable  // 地址不通（红色叹号，确认时跳过）
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

    /// 无副作用解析：从 OPML 字符串读出全部 outline + 统计已存在项，不写库。
    /// 真正导入由确认页调用 SourceStore 完成。
    func parseOPML(_ xml: String) -> OPMLImportPlan {
        var plan = OPMLImportPlan()
        guard let data = xml.data(using: .utf8) else {
            plan.parseError = "非 UTF-8 文本"
            return plan
        }
        let parser = OPMLXMLParser()
        guard parser.parse(data: data) else {
            plan.parseError = "OPML 解析失败（非合法 OPML）"
            return plan
        }
        // 扁平化：每个叶子成一个 OPMLOutline，带上所属文件夹名
        for group in parser.groups {
            for src in group.sources {
                plan.outlines.append(OPMLOutline(
                    title: src.title, url: src.url,
                    stypeGuess: src.stype, folderName: group.folderName
                ))
            }
        }
        return plan
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
        // YouTube
        if u.contains("youtube.com/feeds/videos.xml") || u.contains("youtube.com/feeds/") { return "youtube" }
        // 播客托管平台（buzzsprout/megaphone/simplecast/transistor 等）
        if u.contains("buzzsprout.com") || u.contains("megaphone.fm") || u.contains("simplecast.com")
            || u.contains("transistor.fm") || u.contains("anchor.fm") || u.contains("podbean.com")
            || u.contains("libsyn.com") || u.contains("spreaker.com") { return "podcast" }
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
