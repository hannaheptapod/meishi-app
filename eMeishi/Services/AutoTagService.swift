import Foundation
import CoreML
import CoreData
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

// AI自動タグ提案サービス
// 名刺スキャン後、既存タグから該当するものをAIが提案する
//
// エンジン選択（readingMethod に従う）:
//   Foundation Models: 全タグを1プロンプトで一括判定（推奨・高速）
//   Qwen: 各タグについて1回 forward pass で yes/no 分類（非対応端末フォールバック）
//
// フォールバック: モデル未対応・未ロード時は空配列を返す
class AutoTagService {

    static let shared = AutoTagService()

    // MARK: - 公開API

    /// 名刺情報からタグ提案を返す（readingMethod に従いエンジンを選択）
    /// - Parameters:
    ///   - cardInfo: 名刺のフィールド情報（会社・部署・役職など）
    ///   - tags: 既存タグ一覧
    /// - Returns: 該当すると判定されたタグのID一覧
    func suggestTags(cardInfo: CardInfo, tags: [Tag]) async -> [UUID] {
        guard !tags.isEmpty else { return [] }
        // タグが多すぎる場合は最初の20個に制限（レイテンシ対策）
        let targetTags = Array(tags.prefix(20))
        let cardSummary = buildCardSummary(cardInfo)

        switch SettingsStore.shared.readingMethod {
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                return await suggestTagsWithFoundationModels(cardSummary: cardSummary, tags: targetTags)
            }
            #endif
            return []

        case .localLLM:
            return await suggestTagsWithQwen(cardSummary: cardSummary, tags: targetTags)

        case .automatic:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                if case .available = SystemLanguageModel.default.availability {
                    return await suggestTagsWithFoundationModels(cardSummary: cardSummary, tags: targetTags)
                }
            }
            #endif
            return await suggestTagsWithQwen(cardSummary: cardSummary, tags: targetTags)
        }
    }

    // MARK: - カード情報構造体

    struct CardInfo {
        var company: String = ""
        var department: String = ""
        var title: String = ""
        var address: String = ""
        var email: String = ""
        var website: String = ""
    }

    // MARK: - Foundation Models（全タグ一括判定）

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func suggestTagsWithFoundationModels(cardSummary: String, tags: [Tag]) async -> [UUID] {
        let tagList = tags.enumerated().compactMap { (i, tag) -> String? in
            guard let name = tag.name, !name.isEmpty else { return nil }
            return "\(i): \(name)"
        }.joined(separator: "\n")

        let instructions = """
            名刺情報の内容からタグの意味に合致するものの番号のみ出力せよ。
            明確に合致するもののみ選べ。曖昧なものは除外。出力: 番号のみカンマ区切り。該当なしは none。
            """
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(temperature: 0)
        let prompt = "名刺: \(cardSummary)\n\nタグ:\n\(tagList)\n\n該当タグ番号:"

        do {
            let response = try await session.respond(to: prompt, options: options)
            let text = String(describing: response.content)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            AppLogger.autoTag.debug("Foundation Models タグ提案応答: \(text, privacy: .private)")

            if text == "none" || text == "なし" || text.isEmpty { return [] }

            let numbers = text.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap { Int($0) }

            var result: [UUID] = []
            var seen = Set<UUID>()
            for num in numbers {
                guard num >= 0 && num < tags.count,
                      let tagID = tags[num].id,
                      !seen.contains(tagID) else { continue }
                seen.insert(tagID)
                result.append(tagID)
            }
            return result
        } catch {
            AppLogger.autoTag.error("Foundation Models タグ提案エラー: \(error)")
            return []
        }
    }
    #endif

    // MARK: - Qwen（タグ1件ずつ yes/no 判定・非対応端末フォールバック）

    private func suggestTagsWithQwen(cardSummary: String, tags: [Tag]) async -> [UUID] {
        let llm = LocalLLMService.shared
        guard let models = llm.ensureModelLoaded() else { return [] }

        var suggestedIDs: [UUID] = []
        for tag in tags {
            guard let tagID = tag.id, let tagName = tag.name, !tagName.isEmpty else { continue }
            let matches = await classifyTagMatchWithQwen(
                tagName: tagName,
                cardSummary: cardSummary,
                prefill: models.prefill,
                tokenizer: models.tokenizer
            )
            if matches { suggestedIDs.append(tagID) }
        }
        return suggestedIDs
    }

    // MARK: - 内部処理

    /// カード情報を1行のサマリに変換
    private func buildCardSummary(_ info: CardInfo) -> String {
        var parts: [String] = []
        if !info.company.isEmpty    { parts.append("会社: \(info.company)") }
        if !info.department.isEmpty { parts.append("部署: \(info.department)") }
        if !info.title.isEmpty      { parts.append("役職: \(info.title)") }
        if !info.address.isEmpty    { parts.append("住所: \(info.address)") }
        if !info.email.isEmpty      { parts.append("メール: \(info.email)") }
        return parts.joined(separator: " / ")
    }

    /// 1タグ1回の forward pass で yes/no 分類（Qwen）
    private func classifyTagMatchWithQwen(tagName: String, cardSummary: String,
                                          prefill: MLModel, tokenizer: Qwen25Tokenizer) async -> Bool {
        let prompt = buildTagMatchPrompt(tagName: tagName, cardSummary: cardSummary)
        let ids = tokenizer.encode(prompt)
        do {
            let logits = try await LocalLLMService.shared.forwardPrefill(model: prefill, ids: ids, seqLen: ids.count)
            guard let tokenId = LocalLLMService.shared.argmaxLastToken(logits: logits) else { return false }
            let decoded = tokenizer.decode([tokenId]).lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return decoded.hasPrefix("y") || decoded.hasPrefix("はい") || decoded.hasPrefix("yes")
        } catch {
            AppLogger.autoTag.error("Qwen タグ分類エラー: \(error)")
            return false
        }
    }

    /// タグマッチ判定用 ChatML プロンプト
    private func buildTagMatchPrompt(tagName: String, cardSummary: String) -> String {
        "<|im_start|>system\nDoes this business card match the tag? Reply yes or no.<|im_end|>\n<|im_start|>user\nTag: \"\(tagName)\"\nCard: \(cardSummary)\nMatch?<|im_end|>\n<|im_start|>assistant\n/no_think\n"
    }
}
