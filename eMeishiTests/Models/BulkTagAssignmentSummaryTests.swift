import Foundation
import Testing
@testable import eMeishi

struct BulkTagAssignmentSummaryTests {
    @Test func reportsNoneWhenSelectionContainsNoResolvableCards() {
        let tagID = UUID()
        let summary = BulkTagAssignmentSummary(
            selectedCardCount: 0,
            countsByTagID: [tagID: 0]
        )

        #expect(summary.assignment(for: tagID) == .none)
    }

    @Test func distinguishesPartialAndCompleteAssignments() {
        let partialTagID = UUID()
        let completeTagID = UUID()
        let summary = BulkTagAssignmentSummary(
            selectedCardCount: 3,
            countsByTagID: [partialTagID: 1, completeTagID: 3]
        )

        #expect(summary.assignment(for: partialTagID) == .some)
        #expect(summary.assignment(for: completeTagID) == .all)
        #expect(summary.assignment(for: UUID()) == .none)
    }
}
