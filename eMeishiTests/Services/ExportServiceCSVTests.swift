import Testing
import Foundation
@testable import eMeishi

// MARK: - ExportService CSV テスト

@MainActor
struct ExportServiceCSVTests {

    let service = ExportService()

    @Test func headerRow() {
        let firstLine = service.csvString(from: []).components(separatedBy: "\n").first ?? ""
        #expect(firstLine == "姓,名,会社名,部署,役職,電話番号,メールアドレス,住所,Webサイト,メモ,登録日時")
    }

    @Test func emptyCardsOnlyHeader() {
        let lines = service.csvString(from: []).components(separatedBy: "\n")
        #expect(lines.count == 1)
    }

    @Test func singleCardRowCount() {
        let card = makeDTO(lastName: "山田", firstName: "太郎")
        let lines = service.csvString(from: [card]).components(separatedBy: "\n")
        #expect(lines.count == 2)
    }

    @Test func rowFieldOrder() {
        // 姓,名,会社名,部署,役職,電話番号,メールアドレス,住所,Webサイト,メモ,登録日時
        let card = makeDTO(lastName: "山田", firstName: "太郎",
                           company: "テスト株式会社", title: "部長",
                           email: "yamada@test.co.jp")
        let row = service.csvString(from: [card]).components(separatedBy: "\n")[1]
        #expect(row.hasPrefix("山田,太郎,テスト株式会社,,部長,,yamada@test.co.jp"))
    }

    @Test func multiplePhonesSeparated() {
        let card = makeDTO(phone: "090-1111-1111\n090-2222-2222")
        let row = service.csvString(from: [card]).components(separatedBy: "\n")[1]
        #expect(row.contains("090-1111-1111 / 090-2222-2222"))
    }

    @Test func escapesComma() {
        let card = makeDTO(address: "東京都渋谷区, 1-2-3")
        let csv = service.csvString(from: [card])
        #expect(csv.contains("\"東京都渋谷区, 1-2-3\""))
    }

    @Test func escapesDoubleQuote() {
        let card = makeDTO(notes: "メモに\"引用\"あり")
        let csv = service.csvString(from: [card])
        #expect(csv.contains("\"メモに\"\"引用\"\"あり\""))
    }

    @Test func escapesNewline() {
        let card = makeDTO(notes: "1行目\n2行目")
        let csv = service.csvString(from: [card])
        #expect(csv.contains("\"1行目\n2行目\""))
    }

    @Test func noEscapeForPlainText() {
        let card = makeDTO(lastName: "山田", firstName: "太郎")
        let csv = service.csvString(from: [card])
        #expect(csv.contains("山田,太郎"))
    }

    @Test func multipleCardsMultipleRows() {
        let a = makeDTO(lastName: "山田")
        let b = makeDTO(lastName: "田中")
        let lines = service.csvString(from: [a, b]).components(separatedBy: "\n")
        // ヘッダー + 2行
        #expect(lines.count == 3)
    }

    @Test func departmentIncludedInRow() {
        let card = makeDTO(company: "テスト株式会社", department: "営業部")
        let row = service.csvString(from: [card]).components(separatedBy: "\n")[1]
        // 3列目=会社名, 4列目=部署
        let fields = row.components(separatedBy: ",")
        #expect(fields[2] == "テスト株式会社")
        #expect(fields[3] == "営業部")
    }
}
