import Testing
import CoreData
@testable import eMeishi

// MARK: - ExportService vCard テスト

@MainActor
struct ExportServiceVCardTests {

    let service = ExportService()
    let context = makeTestContext()

    @Test func vCardStructure() {
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("BEGIN:VCARD"))
        #expect(vcf.contains("VERSION:3.0"))
        #expect(vcf.contains("END:VCARD"))
    }

    @Test func nField() {
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("N:山田;太郎;;;"))
    }

    @Test func fnField() {
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("FN:山田 太郎"))
    }

    @Test func orgWithDepartment() {
        let card = makeCard(context: context, company: "テスト株式会社", companyReading: "てすと", department: "営業部")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("ORG:テスト株式会社;営業部"))
    }

    @Test func orgWithoutDepartment() {
        let card = makeCard(context: context, company: "テスト株式会社", companyReading: "てすと")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("ORG:テスト株式会社;"))
    }

    @Test func noOrgWhenBothEmpty() {
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ")
        let vcf = service.vCardString(from: [card])
        #expect(!vcf.contains("ORG:"))
    }

    @Test func titleField() {
        let card = makeCard(context: context, title: "営業部長")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("TITLE:営業部長"))
    }

    @Test func telField() {
        let card = makeCard(context: context, phone: "090-1234-5678")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("TEL;TYPE=WORK:090-1234-5678"))
    }

    @Test func emailField() {
        let card = makeCard(context: context, email: "yamada@test.co.jp")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("EMAIL;TYPE=WORK:yamada@test.co.jp"))
    }

    @Test func adrField() {
        let card = makeCard(context: context, address: "東京都渋谷区1-2-3")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("ADR;TYPE=WORK:;;東京都渋谷区1-2-3;;;;"))
    }

    @Test func urlField() {
        let card = makeCard(context: context, website: "https://example.com")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("URL:https://example.com"))
    }

    @Test func noteField() {
        let card = makeCard(context: context, notes: "備考欄")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("NOTE:備考欄"))
    }

    @Test func escapesComma() {
        let card = makeCard(context: context, company: "A,B Corp")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("A\\,B Corp"))
    }

    @Test func escapesSemicolon() {
        let card = makeCard(context: context, company: "A;B Corp")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("A\\;B Corp"))
    }

    @Test func escapesBackslash() {
        let card = makeCard(context: context, notes: "パス: C:\\test")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("C:\\\\test"))
    }

    @Test func multipleCards() {
        let a = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        let b = makeCard(context: context, lastName: "田中", lastNameReading: "たなか", firstName: "花子", firstNameReading: "はなこ")
        let vcf = service.vCardString(from: [a, b])
        let count = vcf.components(separatedBy: "BEGIN:VCARD").count - 1
        #expect(count == 2)
    }

    @Test func omitsEmptyOptionalFields() {
        // 値が空のフィールドは vCard に含まれない
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ")
        let vcf = service.vCardString(from: [card])
        #expect(!vcf.contains("TITLE:"))
        #expect(!vcf.contains("EMAIL"))
        #expect(!vcf.contains("ADR"))
        #expect(!vcf.contains("URL:"))
        #expect(!vcf.contains("NOTE:"))
    }
}
