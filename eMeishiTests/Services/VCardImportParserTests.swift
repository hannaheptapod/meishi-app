import CoreData
import Foundation
import Testing
@testable import eMeishi

// テストデータはすべて架空の人物・会社・番号。
nonisolated struct VCardImportParserTests {
    private func vcf(_ lines: [String]) -> String {
        lines.joined(separator: "\r\n") + "\r\n"
    }

    @Test func parsesAppleStyleVCard30WithReadingsAndMultipleValues() throws {
        let text = vcf([
            "BEGIN:VCARD",
            "VERSION:3.0",
            "N:山田;太郎;;;",
            "FN:山田 太郎",
            "X-PHONETIC-LAST-NAME:ヤマダ",
            "X-PHONETIC-FIRST-NAME:タロウ",
            "ORG:例示商事株式会社;営業部",
            "X-PHONETIC-ORG:れいじしょうじ",
            "TITLE:部長",
            "TEL;TYPE=WORK:03-0000-1111",
            "TEL;TYPE=CELL:090-0000-2222",
            "EMAIL;TYPE=WORK:taro@example.com",
            "EMAIL;TYPE=HOME:taro.home@example.com",
            "URL:https://example.com",
            "NOTE:展示会で交換",
            "END:VCARD",
        ])

        let contacts = try VCardImportParser.parse(Data(text.utf8))
        let contact = try #require(contacts.first)

        #expect(contacts.count == 1)
        #expect(contact.lastName == "山田")
        #expect(contact.firstName == "太郎")
        #expect(contact.lastNameReading == "やまだ")
        #expect(contact.firstNameReading == "たろう")
        #expect(contact.company == "例示商事株式会社")
        #expect(contact.companyReading == "れいじしょうじ")
        #expect(contact.department == "営業部")
        #expect(contact.title == "部長")
        #expect(contact.phone == "03-0000-1111\n090-0000-2222")
        #expect(contact.email == "taro@example.com")
        #expect(contact.website == "https://example.com")
        #expect(contact.notes.contains("展示会で交換"))
        #expect(contact.notes.contains("メール: taro.home@example.com"))
    }

    @Test func parsesVCard40Utf8WithoutMojibake() throws {
        let text = vcf([
            "BEGIN:VCARD",
            "VERSION:4.0",
            "N;SORT-AS=\"すずき,いちろう\":鈴木;一郎;;;",
            "FN:鈴木 一郎",
            "ORG:架空テック",
            "TEL;VALUE=uri;TYPE=work:tel:+81-3-0000-3333",
            "END:VCARD",
        ])

        let contact = try #require(try VCardImportParser.parse(Data(text.utf8)).first)

        #expect(contact.lastName == "鈴木")
        #expect(contact.firstName == "一郎")
        #expect(contact.company == "架空テック")
        #expect(contact.lastNameReading == "すずき")
        #expect(contact.firstNameReading == "いちろう")
        #expect(contact.phone == "+81-3-0000-3333")
    }

    @Test func readsHalfwidthKanaSoundReadingAsHiragana() throws {
        let text = vcf([
            "BEGIN:VCARD",
            "VERSION:2.1",
            "N;CHARSET=UTF-8:高橋;次郎",
            "SOUND;X-IRMC-N;CHARSET=UTF-8:ﾀｶﾊｼ;ｼﾞﾛｳ",
            "TEL;WORK:03-0000-4444",
            "END:VCARD",
        ])

        let contact = try #require(try VCardImportParser.parse(Data(text.utf8)).first)

        #expect(contact.lastNameReading == "たかはし")
        #expect(contact.firstNameReading == "じろう")
    }

    @Test func decodesShiftJISFile() throws {
        let text = vcf([
            "BEGIN:VCARD",
            "VERSION:3.0",
            "N:伊藤;花子;;;",
            "FN:伊藤 花子",
            "ORG:架空物産",
            "END:VCARD",
        ])
        let data = try #require(text.data(using: .shiftJIS))

        let contact = try #require(try VCardImportParser.parse(data).first)

        #expect(contact.lastName == "伊藤")
        #expect(contact.company == "架空物産")
    }

    @Test func alignsReadingSupplementsWithEachCard() throws {
        let text = vcf([
            "BEGIN:VCARD",
            "VERSION:3.0",
            "N:佐藤;一;;;",
            "ORG:架空A",
            "X-PHONETIC-ORG:かくうえー",
            "END:VCARD",
            "BEGIN:VCARD",
            "VERSION:3.0",
            "N:田中;二;;;",
            "ORG:架空B",
            "X-PHONETIC-ORG:かくうびー",
            "END:VCARD",
        ])

        let contacts = try VCardImportParser.parse(Data(text.utf8))

        #expect(contacts.map(\.companyReading) == ["かくうえー", "かくうびー"])
    }

    @Test func rejectsFileWithoutContacts() {
        #expect(throws: VCardImportError.self) {
            _ = try VCardImportParser.parse(Data("これはvCardではありません".utf8))
        }
    }

    @Test func resultMessageGuidesToDuplicateCheckOnlyWhenCardsExisted() {
        let withExisting = CardListViewModel.vCardImportResultMessage(insertedCount: 3, hadExistingCards: true)
        let firstImport = CardListViewModel.vCardImportResultMessage(insertedCount: 3, hadExistingCards: false)

        #expect(withExisting.contains("重複チェック"))
        #expect(!firstImport.contains("重複チェック"))
        #expect(firstImport.hasPrefix("3件の名刺をインポートしました"))
    }
}

@MainActor
struct VCardFileImportViewModelTests {
    @Test func importsVCardFileAndRemovesPickerCopy() async throws {
        let context = makeTestContext()
        let text = [
            "BEGIN:VCARD",
            "VERSION:3.0",
            "N:山田;太郎;;;",
            "X-PHONETIC-LAST-NAME:やまだ",
            "X-PHONETIC-FIRST-NAME:たろう",
            "ORG:例示商事株式会社",
            "X-PHONETIC-ORG:れいじしょうじ",
            "TEL:03-0000-1111",
            "TEL:090-0000-2222",
            "END:VCARD",
        ].joined(separator: "\r\n") + "\r\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString).vcf")
        try Data(text.utf8).write(to: url)

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingListUpdate()
        await vm.importFromVCardFile(at: url)
        await vm.waitForPendingListUpdate()

        let request = BusinessCard.fetchRequest()
        let card = try #require(try context.fetch(request).first)
        #expect(card.lastName == "山田")
        #expect(card.lastNameReading == "やまだ")
        #expect(card.firstNameReading == "たろう")
        #expect(card.companyReading == "れいじしょうじ")
        #expect(card.phoneList == ["03-0000-1111", "090-0000-2222"])
        #expect(vm.importResultMessage == "1件の名刺をインポートしました")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
