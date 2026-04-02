import Foundation
import os

// エクスポート処理のエラー型
enum ExportError: LocalizedError {
    case csvWriteFailed(Error)
    case vcardWriteFailed(Error)

    var errorDescription: String? {
        switch self {
        case .csvWriteFailed(let e):
            return "CSVの書き出しに失敗しました: \(e.localizedDescription)"
        case .vcardWriteFailed(let e):
            return "vCardの書き出しに失敗しました: \(e.localizedDescription)"
        }
    }
}

// CSV・vCard（.vcf）エクスポートサービス
class ExportService {

    static let shared = ExportService()

    // MARK: - CSV エクスポート

    /// 複数の BusinessCard を CSV 形式の文字列に変換する
    func csvString(from cards: [BusinessCard]) -> String {
        let header = "姓,名,会社名,部署,役職,電話番号,メールアドレス,住所,Webサイト,メモ,登録日時"
        let rows = cards.map { csvRow(from: $0) }
        return ([header] + rows).joined(separator: "\n")
    }

    /// CSV を一時ファイルに書き出して URL を返す
    func exportCSV(from cards: [BusinessCard]) throws -> URL {
        let csv = csvString(from: cards)
        let url = temporaryFileURL(name: "meishi_export", ext: "csv")
        // BOM付きUTF-8 でExcel等での文字化けを防ぐ
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: csv.utf8)
        do {
            try data.write(to: url)
            AppLogger.export.info("CSVエクスポート完了: \(cards.count, privacy: .public)件")
        } catch {
            AppLogger.export.error("CSVエクスポート失敗: \(error)")
            throw ExportError.csvWriteFailed(error)
        }
        return url
    }

    private func csvRow(from card: BusinessCard) -> String {
        let fields: [String?] = [
            card.lastName,
            card.firstName,
            card.company,
            card.department,
            card.title,
            card.phoneList.isEmpty ? nil : card.phoneList.joined(separator: " / "),
            card.email,
            card.address,
            card.website,
            card.notes,
            card.createdAt.map { ISO8601DateFormatter().string(from: $0) }
        ]
        return fields
            .map { escapeCsv($0 ?? "") }
            .joined(separator: ",")
    }

    /// CSV のフィールドをクォートしてエスケープする
    private func escapeCsv(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    // MARK: - vCard エクスポート

    /// 複数の BusinessCard を vCard 3.0 形式の文字列に変換する
    func vCardString(from cards: [BusinessCard]) -> String {
        cards.map { vCard(from: $0) }.joined(separator: "\n")
    }

    /// vCard を一時ファイルに書き出して URL を返す
    func exportVCard(from cards: [BusinessCard]) throws -> URL {
        let vcf = vCardString(from: cards)
        let url = temporaryFileURL(name: "meishi_export", ext: "vcf")
        do {
            try vcf.write(to: url, atomically: true, encoding: .utf8)
            AppLogger.export.info("vCardエクスポート完了: \(cards.count, privacy: .public)件")
        } catch {
            AppLogger.export.error("vCardエクスポート失敗: \(error)")
            throw ExportError.vcardWriteFailed(error)
        }
        return url
    }

    private func vCard(from card: BusinessCard) -> String {
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]

        let last  = card.lastName  ?? ""
        let first = card.firstName ?? ""
        // vCard の N フィールド：姓;名;ミドルネーム;敬称;敬称（後）
        lines.append("N:\(vcEscape(last));\(vcEscape(first));;;")
        lines.append("FN:\(vcEscape(card.fullName))")

        // ORG: 会社名;部署（RFC 2426 のセミコロン区切り階層形式）
        let company    = card.company    ?? ""
        let department = card.department ?? ""
        if !company.isEmpty || !department.isEmpty {
            lines.append("ORG:\(vcEscape(company));\(vcEscape(department))")
        }
        if let title = card.title, !title.isEmpty {
            lines.append("TITLE:\(vcEscape(title))")
        }
        for phone in card.phoneList {
            lines.append("TEL;TYPE=WORK:\(phone)")
        }
        if let email = card.email, !email.isEmpty {
            lines.append("EMAIL;TYPE=WORK:\(vcEscape(email))")
        }
        if let address = card.address, !address.isEmpty {
            lines.append("ADR;TYPE=WORK:;;\(vcEscape(address));;;;")
        }
        if let website = card.website, !website.isEmpty {
            lines.append("URL:\(vcEscape(website))")
        }
        if let notes = card.notes, !notes.isEmpty {
            lines.append("NOTE:\(vcEscape(notes))")
        }

        lines.append("END:VCARD")
        return lines.joined(separator: "\r\n")
    }

    /// vCard の特殊文字をエスケープする（RFC 6350）
    private func vcEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ",",  with: "\\,")
            .replacingOccurrences(of: ";",  with: "\\;")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - ヘルパー

    private func temporaryFileURL(name: String, ext: String) -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        return FileManager.default
            .temporaryDirectory
            .appendingPathComponent("\(name)_\(timestamp).\(ext)")
    }
}
