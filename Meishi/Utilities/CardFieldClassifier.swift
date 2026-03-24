import Foundation

// Foundation Models が利用不可の場合に使う正規表現ベースのフィールド分類器
struct CardFieldClassifier {

    struct ParsedCard {
        var name: String = ""
        var company: String = ""
        var title: String = ""
        var phone: String = ""
        var email: String = ""
        var address: String = ""
        var website: String = ""
    }

    // テキスト行の配列を受け取り、各フィールドに分類して返す
    func classify(lines: [String]) -> ParsedCard {
        var result = ParsedCard()
        var remainingLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if result.email.isEmpty, let email = extractEmail(from: trimmed) {
                result.email = email
            } else if result.phone.isEmpty, let phone = extractPhone(from: trimmed) {
                result.phone = phone
            } else if result.website.isEmpty, let url = extractURL(from: trimmed) {
                result.website = url
            } else if result.address.isEmpty, isAddress(trimmed) {
                result.address = trimmed
            } else {
                remainingLines.append(trimmed)
            }
        }

        // 残った行から氏名・会社名・役職をヒューリスティックで推定
        // 1行目=氏名、2行目=会社名、3行目以降=役職
        if remainingLines.count >= 1 { result.name    = remainingLines[0] }
        if remainingLines.count >= 2 { result.company = remainingLines[1] }
        if remainingLines.count >= 3 { result.title   = remainingLines[2] }

        return result
    }

    // MARK: - 正規表現ヘルパー

    private func extractEmail(from text: String) -> String? {
        let pattern = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
        return firstMatch(pattern: pattern, in: text)
    }

    private func extractPhone(from text: String) -> String? {
        // 国内電話番号・携帯・国際番号に対応
        let pattern = #"(?:\+?81[-\s]?|0)\d{1,4}[-\s]?\d{1,4}[-\s]?\d{4}"#
        return firstMatch(pattern: pattern, in: text)
    }

    private func extractURL(from text: String) -> String? {
        // http/https で始まるURL
        if let url = firstMatch(pattern: #"https?://[^\s]+"#, in: text) {
            return url
        }
        // www. で始まるものも拾う
        return firstMatch(pattern: #"www\.[^\s]+"#, in: text)
    }

    private func isAddress(_ text: String) -> Bool {
        // 都道府県・市区町村・番地などの住所パターン
        let pattern = #"(東京都|大阪府|京都府|北海道|沖縄県|[^\x00-\x7F]{2,3}[都道府県]|[^\x00-\x7F]+[市区町村])"#
        return matches(pattern: pattern, in: text)
    }

    private func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private func matches(pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
