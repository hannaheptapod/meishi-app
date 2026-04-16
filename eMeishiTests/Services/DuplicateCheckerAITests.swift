import Testing
import CoreData
@testable import eMeishi

// MARK: - DuplicateChecker AI 二次判定テスト
//
// Foundation Models / Qwen いずれも実行環境に依存するため、
// テスト可能なのは「ルールベース結果との等価性」と「モデル未ロード時の非追加」のみ。

// SettingsStore.shared.readingMethod を書き換えるテストが含まれるため、
// 並列実行時の干渉を防ぐために Suite 内を直列化する
@MainActor
@Suite(.serialized)
struct DuplicateCheckerAITests {

    let context = makeTestContext()

    // ボーダーラインペアが存在しない場合（全ペアが閾値以上）は findDuplicates と同じ結果
    @Test func findDuplicatesWithAIMatchesRuleBasedWhenNoBorderline() async {
        // 完全一致ペア → score=1.0（閾値以上・ボーダーラインなし）
        let a = makeCard(context: context, lastName: "山田", firstName: "太郎")
        let b = makeCard(context: context, lastName: "山田", firstName: "太郎")
        let checker = DuplicateChecker(threshold: 0.75)

        let ruled = checker.findDuplicates(in: [a, b])
        let ai    = await checker.findDuplicatesWithAI(in: [a, b])

        #expect(Set(ruled.map { $0.id }) == Set(ai.map { $0.id }))
    }

    // 閾値以上のペアは AI 判定結果に必ず含まれる（デグレなし）
    @Test func findDuplicatesWithAIPreservesConfirmedPairs() async {
        let a = makeCard(context: context, lastName: "田中", firstName: "花子")
        let b = makeCard(context: context, lastName: "田中", firstName: "花子")
        let checker = DuplicateChecker(threshold: 0.75)

        let ai  = await checker.findDuplicatesWithAI(in: [a, b])
        let aURI = a.objectID.uriRepresentation().absoluteString
        let bURI = b.objectID.uriRepresentation().absoluteString
        #expect(ai.contains { pair in
            (pair.cardAIDURI == aURI && pair.cardBIDURI == bURI) ||
            (pair.cardAIDURI == bURI && pair.cardBIDURI == aURI)
        })
    }

    // Qwen モデル未ロード時はボーダーラインペアが結果に追加されない
    //
    // スコア計算（threshold=0.75, lowerBound=0.5）:
    //   fullName: "山田 太郎" vs "山田 次郎" → levenshtein=1/5文字 → nameSim=0.80
    //   company:  "ABC" vs "XYZ" → levenshtein=3/3文字 → companySim=0.0
    //   score = 0.80*0.7 + 0.0*0.3 = 0.56 → ボーダーライン（0.5以上・0.75未満）
    @Test func findDuplicatesWithAIBorderlineNotAddedWithoutModel() async {
        let original = SettingsStore.shared.readingMethod
        SettingsStore.shared.readingMethod = .localLLM
        defer { SettingsStore.shared.readingMethod = original }

        let a = makeCard(context: context, lastName: "山田", firstName: "太郎", company: "ABC")
        let b = makeCard(context: context, lastName: "山田", firstName: "次郎", company: "XYZ")
        let checker = DuplicateChecker(threshold: 0.75)

        // ルールベースではペアなし（score=0.56 < threshold=0.75）
        let ruled = checker.findDuplicates(in: [a, b])
        #expect(ruled.isEmpty)

        // Qwen 未ロードのためボーダーラインペアは追加されない
        let ai = await checker.findDuplicatesWithAI(in: [a, b])
        #expect(ai.isEmpty)
    }
}
