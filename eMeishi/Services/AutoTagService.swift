import Foundation
import CoreML
import CoreData
import os

// AI自動タグ提案サービス
// 名刺スキャン後、既存タグから該当するものをAIが提案する
//
// 処理方式:
//   各タグについて1回 forward pass で「このカードはこのタグに該当するか？」を yes/no 分類
//   タグ10個 ≈ 500ms（Prefillモデル使用）
//
// フォールバック: モデル未ロード時は空配列を返す
class AutoTagService {

    static let shared = AutoTagService()

    // MARK: - 公開API

    /// 名刺情報からタグ提案を返す
    /// - Parameters:
    ///   - cardInfo: 名刺のフィールド情報（会社・部署・役職など）
    ///   - tags: 既存タグ一覧
    /// - Returns: 該当すると判定されたタグのID一覧
    func suggestTags(cardInfo: CardInfo, tags: [Tag]) async -> [UUID] {
        guard !tags.isEmpty else { return [] }
        // タグが多すぎる場合は最初の20個に制限（レイテンシ対策）
        let targetTags = Array(tags.prefix(20))

        let llm = LocalLLMService.shared
        guard let models = llm.ensureModelLoaded() else { return [] }

        let cardSummary = buildCardSummary(cardInfo)
        var suggestedIDs: [UUID] = []

        for tag in targetTags {
            guard let tagID = tag.id, let tagName = tag.name, !tagName.isEmpty else { continue }

            let matches = classifyTagMatch(
                tagName: tagName,
                cardSummary: cardSummary,
                prefill: models.prefill,
                tokenizer: models.tokenizer
            )
            if matches {
                suggestedIDs.append(tagID)
            }
        }

        return suggestedIDs
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

    // MARK: - 内部処理

    /// カード情報を1行のサマリに変換
    private func buildCardSummary(_ info: CardInfo) -> String {
        var parts: [String] = []
        if !info.company.isEmpty { parts.append("company=\(info.company)") }
        if !info.department.isEmpty { parts.append("department=\(info.department)") }
        if !info.title.isEmpty { parts.append("title=\(info.title)") }
        if !info.address.isEmpty { parts.append("address=\(info.address)") }
        if !info.email.isEmpty { parts.append("email=\(info.email)") }
        return parts.joined(separator: " ")
    }

    /// 1タグ1回の forward pass で yes/no 分類
    private func classifyTagMatch(tagName: String, cardSummary: String,
                                  prefill: MLModel, tokenizer: Qwen25Tokenizer) -> Bool {
        let prompt = buildTagMatchPrompt(tagName: tagName, cardSummary: cardSummary)
        let ids = tokenizer.encode(prompt)

        do {
            let logits = try LocalLLMService.shared.forwardPrefill(model: prefill, ids: ids, seqLen: ids.count)
            guard let tokenId = LocalLLMService.shared.argmaxLastToken(logits: logits) else { return false }
            let decoded = tokenizer.decode([tokenId]).lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // "yes" / "y" / "はい" で始まれば該当
            return decoded.hasPrefix("y") || decoded.hasPrefix("はい") || decoded.hasPrefix("yes")
        } catch {
            AppLogger.autoTag.error("分類エラー: \(error)")
            return false
        }
    }

    /// タグマッチ判定用 ChatML プロンプト
    private func buildTagMatchPrompt(tagName: String, cardSummary: String) -> String {
        "<|im_start|>system\nDoes this business card match the tag? Reply yes or no.<|im_end|>\n<|im_start|>user\nTag: \"\(tagName)\"\nCard: \(cardSummary)\nMatch?<|im_end|>\n<|im_start|>assistant\n/no_think\n"
    }
}
