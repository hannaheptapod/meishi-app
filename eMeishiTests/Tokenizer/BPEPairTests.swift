import Testing
@testable import eMeishi

// MARK: - BPEPair テスト

@MainActor
struct BPEPairTests {

    @Test func hashEquality() {
        let p1 = BPEPair("hello", "world")
        let p2 = BPEPair("hello", "world")
        let p3 = BPEPair("world", "hello")
        #expect(p1 == p2)
        #expect(p1 != p3)
        var set = Set<BPEPair>()
        set.insert(p1)
        set.insert(p2)
        #expect(set.count == 1, "同じペアは重複なく格納される")
    }
}
