import Testing
@testable import eMeishi

// MARK: - DuplicateChecker 類似度テスト

@MainActor
struct DuplicateCheckerSimilarityTests {

    let checker = DuplicateChecker()

    @Test func identicalStrings() {
        #expect(checker.similarity("山田太郎", "山田太郎") == 1.0)
    }

    @Test func bothEmpty() {
        #expect(checker.similarity("", "") == 1.0)
    }

    @Test func oneEmpty() {
        #expect(checker.similarity("山田", "") == 0.0)
        #expect(checker.similarity("", "山田") == 0.0)
    }

    @Test func singleCharDifference() {
        // "abc" vs "aXc" → 編集距離 1、最大長 3 → similarity = 1 - 1/3
        let sim = checker.similarity("abc", "aXc")
        #expect(abs(sim - (1.0 - 1.0 / 3.0)) < 0.001)
    }

    @Test func completelyDifferentStrings() {
        let sim = checker.similarity("abc", "xyz")
        #expect(sim < 0.5)
    }

    @Test func caseInsensitive() {
        #expect(checker.similarity("ABC", "abc") == 1.0)
    }

    @Test func trailingWhitespaceTrimmed() {
        #expect(checker.similarity("山田 ", "山田") == 1.0)
    }

    @Test func partialOverlap() {
        // "山田" vs "山本" → 編集距離 1、最大長 2 → similarity = 0.5
        let sim = checker.similarity("山田", "山本")
        #expect(abs(sim - 0.5) < 0.001)
    }
}
