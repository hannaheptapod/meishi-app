import Foundation

// 正規表現によるメール・電話・URLの抽出
enum ContactPatternExtractor {

    static func extractEmail(from text: String) -> String? {
        firstMatch(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, in: text)
    }

    static func extractPhone(from text: String) -> String? {
        firstMatch(pattern: #"(?:\+?81[-\s]?|0)\d{1,4}[-\s]?\d{1,4}[-\s]?\d{4}"#, in: text)
    }

    static func extractURL(from text: String) -> String? {
        if let url = firstMatch(pattern: #"https?://[^\s]+"#, in: text) { return url }
        return firstMatch(pattern: #"www\.[^\s]+"#, in: text)
    }

    static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    static func matches(pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
