import Foundation

/// 用原文图片标记校正译文图片标记。
///
/// LLM 会保留图片位置，但历史全文提取曾把真实懒加载地址写成透明 data URI，导致译文
/// 永久保存旧占位图。只在原文和译文图片数量一致时逐项替换，避免猜测位置或改动译文文字。
enum MarkdownImageReconciler {
    private static let imagePattern = #"!\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s\)]+))(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^\)]*\)))?\s*\)"#

    static func reconcile(translation: String?, source: String?) -> String? {
        guard let translation, !translation.isEmpty,
              let source, !source.isEmpty,
              let regex = try? NSRegularExpression(pattern: imagePattern) else {
            return translation
        }
        let sourceMatches = regex.matches(
            in: source, range: NSRange(source.startIndex..., in: source))
        let translationMatches = regex.matches(
            in: translation, range: NSRange(translation.startIndex..., in: translation))
        guard !sourceMatches.isEmpty,
              sourceMatches.count == translationMatches.count else {
            return translation
        }

        let sourceText = source as NSString
        let allSourceImagesUsable = sourceMatches.allSatisfy { match in
            let url = [1, 2].compactMap { group -> String? in
                let range = match.range(at: group)
                return range.location == NSNotFound ? nil : sourceText.substring(with: range)
            }.first ?? ""
            return isUsableSourceURL(url)
        }
        guard allSourceImagesUsable else { return translation }

        let result = NSMutableString(string: translation)
        for (sourceMatch, translationMatch) in zip(sourceMatches, translationMatches).reversed() {
            result.replaceCharacters(
                in: translationMatch.range,
                with: sourceText.substring(with: sourceMatch.range))
        }
        return result as String
    }

    private static func isUsableSourceURL(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty &&
            !normalized.hasPrefix("data:image/") &&
            normalized != "about:blank" &&
            !normalized.hasPrefix("javascript:") &&
            !normalized.hasPrefix("blob:")
    }
}
