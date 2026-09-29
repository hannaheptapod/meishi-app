import CoreData
import Foundation
import Testing
@testable import eMeishi

// テストデータはすべて架空の人物・会社・番号。
@MainActor
struct CardListViewModelIncomingVCardTests {
    private func writeVCard(company: String, to url: URL) throws {
        let text = [
            "BEGIN:VCARD",
            "VERSION:3.0",
            "N:架空;担当;;;",
            "FN:架空 担当",
            "ORG:\(company)",
            "EMAIL:staff@example.com",
            "END:VCARD",
        ].joined(separator: "\r\n") + "\r\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// iOSが「このAppで開く」のたびに作るInboxのコピーを、アプリのtmp配下で再現する。
    private func makeInboxDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomingVCardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func incomingFilesAreImportedInOrderAndInboxCopiesAreRemoved() async throws {
        let context = makeTestContext()
        let viewModel = CardListViewModel(context: context)
        let inbox = try makeInboxDirectory()
        defer { try? FileManager.default.removeItem(at: inbox) }
        let first = inbox.appendingPathComponent("first.vcf")
        let second = inbox.appendingPathComponent("second.vcf")
        try writeVCard(company: "例示商事株式会社", to: first)
        try writeVCard(company: "架空産業株式会社", to: second)

        viewModel.enqueueIncomingVCardFile(first)
        viewModel.enqueueIncomingVCardFile(second)
        await viewModel.waitForIncomingVCardImports()

        let companies = try context.fetch(BusinessCard.fetchRequest()).compactMap(\.company).sorted()
        #expect(companies == ["例示商事株式会社", "架空産業株式会社"])
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(!viewModel.isImporting)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func incomingFileWaitsForAnImportAlreadyInProgress() async throws {
        let context = makeTestContext()
        let viewModel = CardListViewModel(context: context)
        let inbox = try makeInboxDirectory()
        defer { try? FileManager.default.removeItem(at: inbox) }
        let file = inbox.appendingPathComponent("waiting.vcf")
        try writeVCard(company: "例示商事株式会社", to: file)

        // 連絡先・ファイル選択からの取り込み中を再現する。
        viewModel.isImporting = true
        viewModel.enqueueIncomingVCardFile(file)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try context.count(for: BusinessCard.fetchRequest()) == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))

        viewModel.isImporting = false
        await viewModel.waitForIncomingVCardImports()

        #expect(try context.count(for: BusinessCard.fetchRequest()) == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func unreadableIncomingFileReportsAnErrorAndIsStillRemoved() async throws {
        let context = makeTestContext()
        let viewModel = CardListViewModel(context: context)
        let inbox = try makeInboxDirectory()
        defer { try? FileManager.default.removeItem(at: inbox) }
        let file = inbox.appendingPathComponent("broken.vcf")
        try "not a vcard".write(to: file, atomically: true, encoding: .utf8)

        viewModel.enqueueIncomingVCardFile(file)
        await viewModel.waitForIncomingVCardImports()

        #expect(viewModel.errorMessage != nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try context.count(for: BusinessCard.fetchRequest()) == 0)
    }
}
