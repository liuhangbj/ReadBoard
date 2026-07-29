import Foundation

/// 内容语言的统一规范化与兜底识别。
/// Feed 声明优先；声明缺失时，只对特征足够明确的中文文本做推断，避免误判日文/韩文。
enum ContentLanguage {
    static func normalize(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "_", with: "-")
        if let first = value.split(separator: ",").first {
            value = String(first).trimmingCharacters(in: .whitespaces)
        }
        if ["auto", "und", "unknown", "mul"].contains(value) { return nil }
        if value == "cn" || value == "chinese" || value == "中文" || value == "mandarin"
            || value == "zho" || value == "chi" || value == "cmn" {
            return "zh"
        }
        if value == "english" || value == "eng" { return "en" }
        return value
    }

    static func isChinese(_ raw: String?) -> Bool {
        guard let value = normalize(raw) else { return false }
        return value == "zh" || value.hasPrefix("zh-")
    }

    /// Whisper CLI 接受的 ISO-639-1 参数；未知语言交给模型自动识别。
    static func whisperCode(_ raw: String?) -> String {
        guard let value = normalize(raw) else { return "auto" }
        if isChinese(value) { return "zh" }
        let prefix = value.split(separator: "-").first.map(String.init) ?? value
        let supported: Set<String> = ["en", "ja", "ko", "fr", "de", "es", "it", "pt", "ru"]
        return supported.contains(prefix) ? prefix : "auto"
    }

    /// 只在没有可靠语言声明时使用。至少 8 个汉字且汉字占主要文字字符，
    /// 同时排除明显包含假名或韩文的文本。
    static func looksChinese(_ text: String) -> Bool {
        var han = 0, latin = 0, kana = 0, hangul = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                han += 1
            case 0x0041...0x005A, 0x0061...0x007A:
                latin += 1
            case 0x3040...0x30FF, 0x31F0...0x31FF:
                kana += 1
            case 0xAC00...0xD7AF:
                hangul += 1
            default:
                break
            }
        }
        guard han >= 8, kana < 3, hangul < 3 else { return false }
        return Double(han) / Double(max(han + latin, 1)) >= 0.35
    }

    /// Feed 声明优先；未声明时允许从标题、简介或转录稿推断中文。
    static func isChinese(declared raw: String?, fallbackText: String) -> Bool {
        if let normalized = normalize(raw) { return isChinese(normalized) }
        return looksChinese(fallbackText)
    }

    /// 转录完成后补齐可确定的语言。中文优先识别；明显拉丁文本记为英文。
    static func resolvedAfterTranscription(declared raw: String?, transcript: String) -> String? {
        if let normalized = normalize(raw) { return normalized }
        if looksChinese(transcript) { return "zh" }
        let letters = transcript.unicodeScalars.filter {
            (0x0041...0x005A).contains($0.value) || (0x0061...0x007A).contains($0.value)
        }.count
        return letters >= 20 ? "en" : nil
    }

    static func shouldTranslateTranscript(declared raw: String?, transcript: String) -> Bool {
        !isChinese(resolvedAfterTranscription(declared: raw, transcript: transcript))
    }
}
