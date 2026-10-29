import Foundation
import Testing
@testable import eMeishi

// パスはすべて架空。実在する端末のコンテナパスは使わない。
nonisolated struct IncomingVCardFileTests {
    private let home = URL(fileURLWithPath: "/synthetic/container/home", isDirectory: true)

    @Test func acceptsVCardExtensionsRegardlessOfCase() {
        #expect(IncomingVCardFile.isVCard(URL(fileURLWithPath: "/synthetic/Inbox/contact.vcf")))
        #expect(IncomingVCardFile.isVCard(URL(fileURLWithPath: "/synthetic/Inbox/CONTACT.VCF")))
    }

    @Test func rejectsOtherFilesAndNonFileURLs() {
        #expect(!IncomingVCardFile.isVCard(URL(fileURLWithPath: "/synthetic/Inbox/cards.csv")))
        #expect(!IncomingVCardFile.isVCard(URL(fileURLWithPath: "/synthetic/Inbox/no-extension")))
        #expect(!IncomingVCardFile.isVCard(URL(string: "https://example.com/contact.vcf")!))
    }

    @Test func copiesInsideTheAppContainerAreRemovable() {
        let inboxCopy = home.appendingPathComponent("Documents/Inbox/contact.vcf")
        let temporaryCopy = home.appendingPathComponent("tmp/eMeishi-Inbox/contact.vcf")

        #expect(IncomingVCardFile.isCopyInsideApp(inboxCopy, homeDirectory: home))
        #expect(IncomingVCardFile.isCopyInsideApp(temporaryCopy, homeDirectory: home))
    }

    @Test func filesOutsideTheAppContainerAreKept() {
        let sibling = URL(fileURLWithPath: "/synthetic/container/home-other/contact.vcf")
        let escaped = home.appendingPathComponent("Documents/../../escaped.vcf")
        let remote = URL(string: "https://example.com/contact.vcf")!

        #expect(!IncomingVCardFile.isCopyInsideApp(sibling, homeDirectory: home))
        #expect(!IncomingVCardFile.isCopyInsideApp(escaped, homeDirectory: home))
        #expect(!IncomingVCardFile.isCopyInsideApp(remote, homeDirectory: home))
        #expect(!IncomingVCardFile.isCopyInsideApp(home, homeDirectory: home))
    }
}
