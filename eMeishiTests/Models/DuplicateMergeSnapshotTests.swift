import Testing
@testable import eMeishi

@MainActor
struct DuplicateMergeSnapshotTests {
    @Test func snapshotDoesNotRetainLaterManagedObjectChanges() {
        let context = makeTestContext()
        let card = makeCard(
            context: context,
            lastName: "試験",
            firstName: "利用者",
            company: "Example Corporation",
            email: "person@example.invalid"
        )
        let snapshot = DuplicateMergeCardSnapshot(card: card)

        card.company = "Updated Example Corporation"

        #expect(snapshot.company == "Example Corporation")
        #expect(!snapshot.matchesCurrentValues(of: card))
    }

    @Test func selectionPrefersTheOnlyNonemptySnapshotValue() {
        let context = makeTestContext()
        let cardA = makeCard(context: context)
        let cardB = makeCard(context: context, company: "Example Corporation")
        let snapshotA = DuplicateMergeCardSnapshot(card: cardA)
        let snapshotB = DuplicateMergeCardSnapshot(card: cardB)

        let selection = DuplicateMergeSelection(cardA: snapshotA, cardB: snapshotB)

        #expect(selection.company == .b)
        #expect(selection.name == .a)
    }

    @Test func snapshotRejectsReadingChangesThatWouldAffectMerge() {
        let context = makeTestContext()
        let card = makeCard(context: context, lastName: "試験")
        card.lastNameReading = "しけん"
        let snapshot = DuplicateMergeCardSnapshot(card: card)

        card.lastNameReading = "べつのよみ"

        #expect(!snapshot.matchesCurrentValues(of: card))
    }
}
