import Testing
import Foundation
@testable import eMeishi

// MARK: - ExportService vCard テスト

struct ExportServiceVCardTests {

    let service = ExportService()

    @Test func vCardStructure() {
        let card = makeDTO(lastName: "山田", firstName: "太郎")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("BEGIN:VCARD"))
        #expect(vcf.contains("VERSION:3.0"))
        #expect(vcf.contains("END:VCARD"))
    }

    @Test func nField() {
        let card = makeDTO(lastName: "山田", firstName: "太郎")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("N:山田;太郎;;;"))
    }

    @Test func fnField() {
        let card = makeDTO(lastName: "山田", firstName: "太郎")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("FN:山田 太郎"))
    }

    @Test func orgWithDepartment() {
        let card = makeDTO(company: "テスト株式会社", department: "営業部")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("ORG:テスト株式会社;営業部"))
    }

    @Test func orgWithoutDepartment() {
        let card = makeDTO(company: "テスト株式会社")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("ORG:テスト株式会社;"))
    }

    @Test func noOrgWhenBothEmpty() {
        let card = makeDTO(lastName: "山田")
        let vcf = service.vCardString(from: [card])
        #expect(!vcf.contains("ORG:"))
    }

    @Test func titleField() {
        let card = makeDTO(title: "営業部長")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("TITLE:営業部長"))
    }

    @Test func telField() {
        let card = makeDTO(phone: "090-1234-5678")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("TEL;TYPE=WORK:090-1234-5678"))
    }

    @Test func emailField() {
        let card = makeDTO(email: "yamada@test.co.jp")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("EMAIL;TYPE=WORK:yamada@test.co.jp"))
    }

    @Test func adrField() {
        let card = makeDTO(address: "東京都渋谷区1-2-3")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("ADR;TYPE=WORK:;;東京都渋谷区1-2-3;;;;"))
    }

    @Test func urlField() {
        let card = makeDTO(website: "https://example.com")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("URL:https://example.com"))
    }

    @Test func noteField() {
        let card = makeDTO(notes: "備考欄")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("NOTE:備考欄"))
    }

    @Test func escapesComma() {
        let card = makeDTO(company: "A,B Corp")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("A\\,B Corp"))
    }

    @Test func escapesSemicolon() {
        let card = makeDTO(company: "A;B Corp")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("A\\;B Corp"))
    }

    @Test func escapesBackslash() {
        let card = makeDTO(notes: "パス: C:\\test")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("C:\\\\test"))
    }

    @Test func multipleCards() {
        let a = makeDTO(lastName: "山田", firstName: "太郎")
        let b = makeDTO(lastName: "田中", firstName: "花子")
        let vcf = service.vCardString(from: [a, b])
        let count = vcf.components(separatedBy: "BEGIN:VCARD").count - 1
        #expect(count == 2)
    }

    @Test func omitsEmptyOptionalFields() {
        // 値が空のフィールドは vCard に含まれない
        let card = makeDTO(lastName: "山田")
        let vcf = service.vCardString(from: [card])
        #expect(!vcf.contains("TITLE:"))
        #expect(!vcf.contains("EMAIL"))
        #expect(!vcf.contains("ADR"))
        #expect(!vcf.contains("URL:"))
        #expect(!vcf.contains("NOTE:"))
    }
}
