import Foundation

nonisolated enum ExternalURLNormalizer {
    /// スキーム省略時はhttpsを補い、Webリンクとして許可するのはhttp/httpsだけに限定する。
    static func websiteURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if let colon = trimmed.firstIndex(of: ":") {
            let prefix = String(trimmed[..<colon])
            let isExplicitScheme = !prefix.contains(".")
                && prefix.range(
                    of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#,
                    options: .regularExpression
                ) != nil
            if isExplicitScheme {
                let scheme = prefix.lowercased()
                guard scheme == "http" || scheme == "https" else { return nil }
                candidate = trimmed
            } else {
                // example.com:8443 のようなスキーム省略 + ポート指定。
                candidate = "https://\(trimmed)"
            }
        } else {
            candidate = "https://\(trimmed)"
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}
