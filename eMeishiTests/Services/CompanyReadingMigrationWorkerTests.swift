import CoreData
import Foundation
import Testing
@testable import eMeishi

@MainActor
struct CompanyReadingMigrationWorkerTests {
    @Test func legalEntityMigrationRunsOffViewContextAndPreservesManualReadings() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        let generated = BusinessCard(context: context)
        generated.id = UUID()
        generated.company = "株式会社サンプル"
        generated.companyReading = "かぶしきがいしゃさんぷる"

        let manual = BusinessCard(context: context)
        manual.id = UUID()
        manual.company = "サンプル合同会社"
        manual.companyReading = "独自の読み"
        try context.save()

        let result = await CompanyReadingMigrationWorker.shared.migrate(
            coordinatorReference: PersistentStoreCoordinatorReference(
                coordinator: controller.container.persistentStoreCoordinator
            ),
            migrateLegalEntity: true,
            migrateLatinInitialism: false
        )

        #expect(result.failureMessage == nil)
        #expect(result.completedLegalEntity)
        #expect(result.changedCount == 1)

        context.refresh(generated, mergeChanges: false)
        context.refresh(manual, mergeChanges: false)
        #expect(generated.companyReading == "さんぷる")
        #expect(manual.companyReading == "独自の読み")
    }
}
