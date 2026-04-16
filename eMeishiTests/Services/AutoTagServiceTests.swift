import Testing
import CoreData
@testable import eMeishi

// MARK: - AutoTagService テスト（AI エンジン選択・ガード条件）
//
// Foundation Models は実機 + Apple Intelligence 環境でしか動かないため、
// テスト可能なのは「エンジン非依存のガード条件」と「Qwen モデル未ロード時の挙動」のみ。

@MainActor
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

        let ctx = makeTestContext()
        let tag = eMeishi.Tag(context: ctx)
        tag.id   = UUID()
        tag.name = "IT"

        let result = await AutoTagService.shared.suggestTags(
            cardInfo: AutoTagService.CardInfo(company: "テック株式会社"),
            tags: [tag]
        )
        #expect(result.isEmpty)
    }
}
