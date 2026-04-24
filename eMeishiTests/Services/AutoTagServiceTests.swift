import Testing
import Foundation
@testable import eMeishi

// MARK: - AutoTagService テスト（AI エンジン選択・ガード条件）
//
// Foundation Models は実機 + Apple Intelligence 環境でしか動かないため、
// テスト可能なのは「エンジン非依存のガード条件」と「Qwen モデル未ロード時の挙動」のみ。

// SettingsStore.shared.readingMethod を書き換えるテストが含まれるため、
// 並列実行時の干渉を防ぐために Suite 内を直列化する
@MainActor
@Suite(.serialized)
struct AutoTagServiceTests {

    // タグが空の場合は AI 呼び出しなしに即 [] を返す（全 readingMethod 共通）
    @Test func suggestTagsWithEmptyTagsReturnsEmpty() async {
        let result = await AutoTagService.shared.suggestTags(
            cardInfo: AutoTagService.CardInfo(company: "テスト株式会社"),
            tags: []
        )
        #expect(result.isEmpty)
    }

    // readingMethod=.localLLM でモデル未ロードなら [] を返す
    // テスト環境に Qwen モデルファイルが存在しないため ensureModelLoaded() が nil を返す
    @Test func suggestTagsLocalLLMWithoutModelReturnsEmpty() async {
        let original = SettingsStore.shared.readingMethod
        SettingsStore.shared.readingMethod = .localLLM
        defer { SettingsStore.shared.readingMethod = original }

        let tagInfo = AutoTagService.TagInfo(id: UUID(), name: "IT")

        let result = await AutoTagService.shared.suggestTags(
            cardInfo: AutoTagService.CardInfo(company: "テック株式会社"),
            tags: [tagInfo]
        )
        #expect(result.isEmpty)
    }
}
