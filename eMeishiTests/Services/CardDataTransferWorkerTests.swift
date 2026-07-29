import CoreData
import Foundation
import Testing
@testable import eMeishi

@MainActor
struct CardDataTransferWorkerTests {
    @Test func bulkExportSnapshotDoesNotRequireImageData() async throws {
        let context = makeTestContext()
        let card = makeCard(
            context: context,
            lastName: "架空",
            firstName: "担当",
            company: "例示商事株式会社",
            email: "staff@example.com",
            phone: "03-0000-0000\n050-0000-0000"
        )
        card.imageData = Data(repeating: 0x2A, count: 64)
        try context.save()

        let coordinator = try #require(context.persistentStoreCoordinator)
        let worker = CardDataTransferWorker()
        let snapshots = try await worker.loadCards(
            orderedCardIDs: [try #require(card.id)],
            coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator)
        )

        let snapshot = try #require(snapshots.first)
        #expect(snapshot.lastName == "架空")
        #expect(snapshot.email == "staff@example.com")
        #expect(snapshot.phoneList == ["03-0000-0000", "050-0000-0000"])
    }

    @Test func contactSnapshotLoadsImageOnlyForSingleContactExport() async throws {
        let context = makeTestContext()
        let card = makeCard(
            context: context,
            lastName: "架空",
            firstName: "担当"
        )
        let expectedImage = Data(repeating: 0x3B, count: 48)
        card.imageData = expectedImage
        try context.save()

        let coordinator = try #require(context.persistentStoreCoordinator)
        let request = ContactExportRequest(
            objectURI: card.objectID.uriRepresentation(),
            coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator)
        )
        let snapshot = try await CardDataTransferWorker().loadContact(request)

        #expect(snapshot.card.fullName == "架空 担当")
        #expect(snapshot.imageData == expectedImage)
    }

    @Test func privateWriterFiltersEmptyContactsAndPersistsValues() async throws {
        let context = makeTestContext()
        let coordinator = try #require(context.persistentStoreCoordinator)
        let contacts = [
            ImportedContact(),
            ImportedContact(
                lastName: "架空",
                firstName: "担当",
                company: "例示商事株式会社",
                email: "staff@example.com"
            ),
        ]

        let count = try await ContactImportStoreWriter().insert(
            contacts: contacts,
            coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let request = BusinessCard.fetchRequest()
        let cards = try context.fetch(request)

        #expect(count == 1)
        #expect(cards.count == 1)
        #expect(cards.first?.company == "例示商事株式会社")
        #expect(cards.first?.email == "staff@example.com")
    }

    @Test func privateWriterDeletesAllCards() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, company: "例示商事株式会社")
        _ = makeCard(context: context, company: "架空産業株式会社")
        try context.save()
        let coordinator = try #require(context.persistentStoreCoordinator)

        try await ContactImportStoreWriter().deleteAll(
            coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator)
        )

        let count = try context.count(for: BusinessCard.fetchRequest())
        #expect(count == 0)
    }
}
