import Contacts
import Foundation

// vCardファイル（.vcf）からの名刺インポート（Issue #204）。
// 解析は`CNContactVCardSerialization`に任せ、次の2点だけを自前で補う。
// 1. 文字コード: vCard 4.0のUTF-8をそのまま渡すと日本語が文字化けするため、UTF-16へ変換してから渡す
// 2. 読み仮名: `X-PHONETIC-ORG`・`N;SORT-AS`・`SOUND;X-IRMC-N`・`SORT-STRING`は解析結果に含まれないため直接読む

nonisolated enum VCardImportError: LocalizedError, Equatable {
    case unreadableEncoding
    case noContacts
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .unreadableEncoding:
            return "vCardファイルの文字コードを判別できませんでした。UTF-8またはShift_JISで保存されたファイルを選んでください。"
        case .noContacts:
            return "vCardファイルに連絡先が含まれていませんでした。"
        case .invalidFormat:
            return "vCardファイルを読み込めませんでした。ファイルが壊れていないか確認してください。"
        }
    }
}

/// `CNContactVCardSerialization`が読まない読み仮名。vCard内の各`BEGIN:VCARD`ブロックに1対1で対応する。
nonisolated struct VCardReadingSupplement: Sendable, Equatable {
    var lastNameReading: String?
    var firstNameReading: String?
    var companyReading: String?

    static let empty = VCardReadingSupplement()

    /// 先に見つかった読みを優先し、未設定の項目だけを埋める。
    mutating func fillNameReadings(last: String?, first: String?) {
        if lastNameReading == nil { lastNameReading = last }
        if firstNameReading == nil { firstNameReading = first }
    }
}

/// 取込元の読み仮名を名刺の保存形式（ひらがな・全角）へ揃える。
nonisolated enum ImportedReadingNormalizer {
    static func normalize(_ reading: String?) -> String {
        guard let reading else { return "" }
        var text = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        // 半角カナ（SOUND;X-IRMC-N等）だけを全角化する。英数字まで全角化しないよう対象を限定する。
        if text.unicodeScalars.contains(where: { (0xFF61...0xFF9F).contains($0.value) }) {
            text = text.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? text
        }
        return NameReadingGenerator.katakanaToHiragana(text)
    }
}

nonisolated enum VCardImportParser {
    /// vCardのバイト列を名刺インポート用の値へ変換する。
    static func parse(_ data: Data) throws -> [ImportedContact] {
        guard let text = decodeText(data) else { throw VCardImportError.unreadableEncoding }
        guard let utf16Data = text.data(using: .utf16) else { throw VCardImportError.unreadableEncoding }

        let contacts: [CNContact]
        do {
            contacts = try CNContactVCardSerialization.contacts(with: utf16Data)
        } catch {
            throw VCardImportError.invalidFormat
        }
        guard !contacts.isEmpty else { throw VCardImportError.noContacts }

        // ブロック数が一致しない場合は対応関係が保証できないため、補完を使わない。
        let supplements = readingSupplements(in: text)
        let aligned = supplements.count == contacts.count
        return contacts.enumerated().map { index, contact in
            ImportedContact(
                cnContact: contact,
                supplement: aligned ? supplements[index] : .empty
            )
        }
    }

    /// UTF-8（BOM有無）→ UTF-16（BOM付き）→ Shift_JIS の順に判定する。
    /// 古い国内アプリや携帯電話の書き出しはShift_JISのことがある。
    static func decodeText(_ data: Data) -> String? {
        let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
        if data.starts(with: utf8BOM) {
            return String(data: data.dropFirst(utf8BOM.count), encoding: .utf8)
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .shiftJIS)
    }

    /// `BEGIN:VCARD`ごとに読み仮名の補完値を集める。
    static func readingSupplements(in text: String) -> [VCardReadingSupplement] {
        var result: [VCardReadingSupplement] = []
        var current: VCardReadingSupplement?

        for line in unfoldedLines(text) {
            guard let property = VCardProperty(line: line) else { continue }
            switch property.name {
            case "BEGIN" where property.value.uppercased() == "VCARD":
                current = VCardReadingSupplement()
            case "END" where property.value.uppercased() == "VCARD":
                if let current { result.append(current) }
                current = nil
            case "X-PHONETIC-ORG":
                current?.companyReading = nonEmpty(unescape(property.value))
            case "N":
                // vCard 4.0: N;SORT-AS="やまだ,たろう":山田;太郎;;;
                if let sortAs = property.parameter("SORT-AS") {
                    let parts = splitSortAs(sortAs)
                    current?.fillNameReadings(
                        last: parts.first.flatMap(nonEmpty),
                        first: parts.dropFirst().first.flatMap(nonEmpty)
                    )
                }
            case "SOUND" where property.hasParameter("X-IRMC-N"):
                // 携帯電話系のvCard 2.1: SOUND;X-IRMC-N:ﾔﾏﾀﾞ;ﾀﾛｳ;;;
                guard !property.isQuotedPrintable else { continue }
                let parts = property.value.components(separatedBy: ";").map(unescape)
                current?.fillNameReadings(
                    last: parts.first.flatMap(nonEmpty),
                    first: parts.dropFirst().first.flatMap(nonEmpty)
                )
            case "SORT-STRING":
                // vCard 3.0: 姓名の区切りが仕様上ないため、空白で2語に分かれる場合だけ使う。
                let parts = unescape(property.value)
                    .split(whereSeparator: { $0 == " " || $0 == "　" })
                    .map(String.init)
                if parts.count == 2 {
                    current?.fillNameReadings(last: parts[0], first: parts[1])
                }
            default:
                continue
            }
        }
        return result
    }

    /// RFC 6350/2425の折り返し（行頭の空白・タブ）を連結する。
    private static func unfoldedLines(_ text: String) -> [String] {
        var lines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) where !rawLine.isEmpty {
            if let first = rawLine.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += rawLine.dropFirst()
            } else {
                lines.append(rawLine)
            }
        }
        return lines
    }

    private static func splitSortAs(_ value: String) -> [String] {
        value.components(separatedBy: ",").map(unescape)
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\N", with: " ")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

/// vCardの1行（`group.NAME;PARAM=VALUE:value`）。値の中の`:`は区切りとして扱わない。
private nonisolated struct VCardProperty {
    let name: String
    let parameters: [String]
    let value: String

    init?(line: String) {
        var inQuotes = false
        var separator: String.Index?
        for index in line.indices {
            let character = line[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if character == ":", !inQuotes {
                separator = index
                break
            }
        }
        guard let separator else { return nil }
        let head = line[..<separator]
        var components = head.components(separatedBy: ";")
        guard !components.isEmpty else { return nil }
        let rawName = components.removeFirst()
        // `item1.X-PHONETIC-ORG`のようなグループ接頭辞を外す。
        name = (rawName.split(separator: ".").last.map(String.init) ?? rawName).uppercased()
        parameters = components
        value = String(line[line.index(after: separator)...])
    }

    var isQuotedPrintable: Bool {
        parameters.contains { $0.uppercased().contains("QUOTED-PRINTABLE") }
    }

    func hasParameter(_ name: String) -> Bool {
        parameters.contains { $0.uppercased() == name.uppercased() }
    }

    func parameter(_ name: String) -> String? {
        for parameter in parameters {
            let pair = parameter.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, pair[0].uppercased() == name.uppercased() else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }
}

/// ファイル読み込みと解析をMainActor外で行う。
/// ドキュメントピッカーが作ったコピーは個人情報を含むため、読み込み後に必ず削除する。
actor VCardImportService {
    func contacts(fromFileAt url: URL, removeAfterReading: Bool) throws -> [ImportedContact] {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isScoped { url.stopAccessingSecurityScopedResource() }
            if removeAfterReading { try? FileManager.default.removeItem(at: url) }
        }
        let data = try Data(contentsOf: url)
        return try VCardImportParser.parse(data)
    }
}
