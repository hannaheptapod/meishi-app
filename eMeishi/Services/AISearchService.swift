import Foundation
import CoreData
import CoreML
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// 対話型 AI 検索サービス
///
/// 設計方針:
/// 1. まずクエリを分析し、フィールド特定可能な検索（住所・名前・会社名）はルールベースで直接フィルタ
/// 2. 概念的検索（「食品関係」「IT系」等）のみ LLM に委譲
/// 3. LLM にはフィルタ済み候補ではなく全カードを渡すが、判定はカード単位の yes/no
class AISearchService {

    static let shared = AISearchService()

    // MARK: - チャットメッセージ

    struct ChatMessage: Identifiable {
        let id = UUID()
        let role: Role
        let text: String
        var matchedCardIDs: [UUID]

        enum Role {
            case user, assistant
        }
    }

    // MARK: - クエリ種別

    private enum QueryType {
        case location(keywords: [String])   // 住所・地名で検索
        case name(keywords: [String])       // 人名で検索
        case company(keywords: [String])    // 会社名で検索
        case conceptual(query: String)      // 概念的・意味的検索（LLM必要）
    }

    // MARK: - 公開 API

    func search(
        query: String,
        cards: [BusinessCard],
        conversationHistory: [ChatMessage]
    ) async -> ChatMessage {
        let method = SettingsStore.shared.readingMethod
        AppLogger.search.info("検索開始: query=\(query, privacy: .private) method=\(method.rawValue, privacy: .public) cards=\(cards.count, privacy: .public)件")

        let queryType = classifyQuery(query)
        AppLogger.search.info("クエリ種別: \(String(describing: queryType), privacy: .public)")

        // フィールド特定可能な検索はルールベースで処理（LLM不要）
        switch queryType {
        case .location(let keywords):
            return fieldSearch(cards: cards, query: query, keywords: keywords, field: \.address, label: "住所")
        case .name(let keywords):
            return nameSearch(cards: cards, query: query, keywords: keywords)
        case .company(let keywords):
            return fieldSearch(cards: cards, query: query, keywords: keywords, field: \.company, label: "会社")
        case .conceptual:
            break // LLM で処理
        }

        // 概念的検索 → 設定に応じたエンジンで処理
        switch method {
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                AppLogger.search.info("Apple Intelligence で概念検索")
                if let result = await searchWithFoundationModels(query: query, cards: cards) {
                    AppLogger.search.info("完了: \(result.matchedCardIDs.count, privacy: .public)件マッチ")
                    return result
                }
            }
            #endif
            return noModelAvailableMessage(query: query)

        case .localLLM:
            AppLogger.search.info("Qwen で概念検索")
            if let result = await searchWithQwen(query: query, cards: cards) {
                AppLogger.search.info("完了: \(result.matchedCardIDs.count, privacy: .public)件マッチ")
                return result
            }
            return noModelAvailableMessage(query: query)

        case .automatic:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                if case .available = SystemLanguageModel.default.availability {
                    AppLogger.search.info("Foundation Models で概念検索")
                    if let result = await searchWithFoundationModels(query: query, cards: cards) {
                        AppLogger.search.info("完了: \(result.matchedCardIDs.count, privacy: .public)件マッチ")
                        return result
                    }
                    return errorMessage(query: query, engine: "Apple Intelligence")
                }
            }
            #endif

            AppLogger.search.info("Qwen で概念検索")
            if let result = await searchWithQwen(query: query, cards: cards) {
                AppLogger.search.info("完了: \(result.matchedCardIDs.count, privacy: .public)件マッチ")
                return result
            }
            return noModelAvailableMessage(query: query)
        }
    }

    // MARK: - クエリ分類

    /// クエリの種別を判定（住所？名前？会社？概念的？）
    private func classifyQuery(_ query: String) -> QueryType {
        let cleaned = stripParticles(query)

        // 住所・地名検索: 都道府県名 or 市区町村サフィックスを含む
        if containsLocationKeywords(query) {
            let keywords = cleaned.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            return .location(keywords: keywords)
        }

        // 会社名検索: 「株式会社」「(株)」等の法人格を含む
        let companyPatterns = ["株式会社", "有限会社", "合同会社", "合名会社", "(株)", "（株）"]
        if companyPatterns.contains(where: { query.contains($0) }) {
            let keywords = cleaned.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            return .company(keywords: keywords)
        }

        // 人名検索: 「さん」「氏」で終わる or 姓名パターン（2〜4文字 + スペース + 1〜4文字）
        let nameSuffixes = ["さん", "氏", "先生", "様"]
        for suffix in nameSuffixes {
            if query.hasSuffix(suffix) {
                let name = String(query.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    return .name(keywords: [name])
                }
            }
        }

        // その他 → 概念的検索
        return .conceptual(query: cleaned)
    }

    // MARK: - ルールベース検索

    /// 特定フィールドに対するキーワード検索
    private func fieldSearch(
        cards: [BusinessCard],
        query: String,
        keywords: [String],
        field: KeyPath<BusinessCard, String?>,
        label: String
    ) -> ChatMessage {
        let matched = cards.filter { card in
            guard let value = card[keyPath: field], !value.isEmpty else { return false }
            return keywords.allSatisfy { keyword in
                value.localizedCaseInsensitiveContains(keyword)
            }
        }
        let matchedIDs = matched.compactMap { $0.id }
        let text = matchedIDs.isEmpty
            ? "「\(query)」に該当する\(label)の名刺は見つかりませんでした。"
            : "\(matchedIDs.count)件見つかりました。"
        return ChatMessage(role: .assistant, text: text, matchedCardIDs: matchedIDs)
    }

    /// 名前検索（姓・名・フルネーム・ふりがなを横断検索）
    private func nameSearch(
        cards: [BusinessCard],
        query: String,
        keywords: [String]
    ) -> ChatMessage {
        let matched = cards.filter { card in
            let searchTargets = [
                card.fullName,
                card.lastName,
                card.firstName,
                card.lastNameReading,
                card.firstNameReading
            ].compactMap { $0 }

            return keywords.allSatisfy { keyword in
                searchTargets.contains { $0.localizedCaseInsensitiveContains(keyword) }
            }
        }
        let matchedIDs = matched.compactMap { $0.id }
        let text = matchedIDs.isEmpty
            ? "「\(query)」に該当する名刺は見つかりませんでした。"
            : "\(matchedIDs.count)件見つかりました。"
        return ChatMessage(role: .assistant, text: text, matchedCardIDs: matchedIDs)
    }

    // MARK: - メッセージヘルパー

    private func noModelAvailableMessage(query: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: "AI検索に必要なモデルが利用できません。設定からAIエンジンを確認してください。", matchedCardIDs: [])
    }

    private func errorMessage(query: String, engine: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: "「\(query)」の検索中に\(engine)でエラーが発生しました。もう一度お試しください。", matchedCardIDs: [])
    }

    // MARK: - Foundation Models（概念的検索のみ）

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func searchWithFoundationModels(
        query: String,
        cards: [BusinessCard]
    ) async -> ChatMessage? {
        let maxCardsPerBatch = 100
        let batches = stride(from: 0, to: cards.count, by: maxCardsPerBatch).map {
            Array(cards[$0..<min($0 + maxCardsPerBatch, cards.count)])
        }

        var allMatchedIDs: [UUID] = []

        for (batchIdx, batchCards) in batches.enumerated() {
            // 番号付きリスト（0-indexed）
            let cardList = batchCards.enumerated().map { (i, card) in
                let parts = [card.company, card.department, card.title]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                return "\(batchIdx * maxCardsPerBatch + i): \(parts.joined(separator: "/"))"
            }.joined(separator: "\n")

            let instructions = """
                番号付きリストから検索クエリに該当する番号だけ出力せよ。
                会社名・部署名・役職がクエリのテーマに直接属するもののみ選べ。
                外来語・略語・同義語も考慮（例: フード=食品、テック=技術）。
                出力: 番号のみカンマ区切り。該当なしは none。
                """

            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(temperature: 0)

            // few-shot: 正しい判定の厳しさを教える
            let fewShot = """
                例1:
                0: IT株式会社/開発部/エンジニア
                1: フードサービス株式会社/製造部/工場長
                2: 銀行/法人営業部/部長
                検索:「食品関係」
                回答: 1

                例2:
                0: 自動車メーカー/営業部/課長
                1: テックラボ株式会社/研究部/研究員
                2: 製薬会社/臨床部/マネージャー
                検索:「IT・技術系」
                回答: 1

                例3:
                0: コンサル会社/戦略部/コンサルタント
                1: 不動産会社/管理部/課長
                2: 物流会社/配送部/部長
                検索:「医療関係」
                回答: none

                """

            AppLogger.search.debug("カードリスト: \(cardList, privacy: .private)")
            let prompt = "\(fewShot)\(cardList)\n\n検索:「\(query)」\n回答:"

            do {
                let response = try await session.respond(to: prompt, options: options)
                let text = String(describing: response.content).trimmingCharacters(in: .whitespacesAndNewlines)
                AppLogger.search.debug("Foundation Models 応答: \(text, privacy: .private)")

                let matchedIDs = parseIndexResponse(text: text, cards: batchCards, offset: batchIdx * maxCardsPerBatch)
                AppLogger.search.info("マッチ: \(matchedIDs.count, privacy: .public)件")
                allMatchedIDs.append(contentsOf: matchedIDs)
            } catch {
                AppLogger.search.error("Foundation Models エラー: \(error)")
                continue
            }
        }

        let text = allMatchedIDs.isEmpty
            ? "「\(query)」に該当する名刺は見つかりませんでした。"
            : "\(allMatchedIDs.count)件見つかりました。"
        return ChatMessage(role: .assistant, text: text, matchedCardIDs: allMatchedIDs)
    }

    /// 番号リスト（"3,7,12" or "none"）をパースしてカードIDに変換
    private func parseIndexResponse(text: String, cards: [BusinessCard], offset: Int) -> [UUID] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned == "none" || cleaned == "なし" || cleaned.isEmpty { return [] }

        // 数字を抽出
        let numbers = cleaned.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }

        var matchedIDs: [UUID] = []
        var seenIDs = Set<UUID>()
        for num in numbers {
            let localIdx = num - offset
            guard localIdx >= 0 && localIdx < cards.count else { continue }
            if let cardID = cards[localIdx].id, !seenIDs.contains(cardID) {
                seenIDs.insert(cardID)
                matchedIDs.append(cardID)
            }
        }
        return matchedIDs
    }
    #endif

    // MARK: - Qwen3-0.6B（概念的検索のみ）

    private func searchWithQwen(
        query: String,
        cards: [BusinessCard]
    ) async -> ChatMessage? {
        let llm = LocalLLMService.shared
        guard let models = llm.ensureModelLoaded() else { return nil }

        var matchedIDs: [UUID] = []

        for card in cards {
            let summary = compactSummary(card: card)
            let isMatch = classifyRelevance(
                query: query,
                cardSummary: summary,
                prefill: models.prefill,
                tokenizer: models.tokenizer
            )
            if isMatch, let cardID = card.id {
                matchedIDs.append(cardID)
            }
        }

        let text = matchedIDs.isEmpty
            ? "「\(query)」に該当する名刺は見つかりませんでした。"
            : "\(matchedIDs.count)件見つかりました。"
        return ChatMessage(role: .assistant, text: text, matchedCardIDs: matchedIDs)
    }

    /// カード1枚の関連性を単一 forward pass で判定
    private func classifyRelevance(
        query: String,
        cardSummary: String,
        prefill: MLModel,
        tokenizer: Qwen25Tokenizer
    ) -> Bool {
        let systemInstruction = "この名刺が検索クエリに直接関連するか判定。会社名・部署名・役職に検索テーマと直接関係する語が含まれる場合のみyes。間接的な関連はno。迷ったらno。yesかnoのみ回答。"
        let prompt = "<|im_start|>system\n\(systemInstruction)<|im_end|>\n<|im_start|>user\n検索:「\(query)」\n名刺:\(cardSummary)\n関連する?<|im_end|>\n<|im_start|>assistant\n/no_think\n"

        let ids = tokenizer.encode(prompt)
        guard ids.count <= 1024 else { return false }

        let yesTokenIds = tokenizer.encode("yes")
        let noTokenIds = tokenizer.encode("no")
        guard let yesId = yesTokenIds.last, let noId = noTokenIds.last else { return false }

        do {
            let logits = try LocalLLMService.shared.forwardPrefill(model: prefill, ids: ids, seqLen: ids.count)

            let shape = logits.shape.map { $0.intValue }
            let vocabSize = shape.last ?? 0
            guard vocabSize > 0 else { return false }

            let totalElements = shape.reduce(1, *)
            let lastTokenOffset = totalElements - vocabSize

            if logits.dataType == .float16 {
                let ptr = logits.dataPointer.assumingMemoryBound(to: UInt16.self)
                let yesScore = float16ToFloat32(ptr[lastTokenOffset + yesId])
                let noScore = float16ToFloat32(ptr[lastTokenOffset + noId])
                return yesScore > noScore
            } else {
                let ptr = logits.dataPointer.assumingMemoryBound(to: Float32.self)
                let yesScore = ptr[lastTokenOffset + yesId]
                let noScore = ptr[lastTokenOffset + noId]
                return yesScore > noScore
            }
        } catch {
            AppLogger.search.error("Qwen 判定エラー: \(error)")
            return false
        }
    }

    /// Float16 (UInt16) → Float32 変換
    private func float16ToFloat32(_ bits: UInt16) -> Float32 {
        let sign     = UInt32(bits >> 15) & 1
        let exponent = UInt32(bits >> 10) & 0x1F
        let mantissa = UInt32(bits)       & 0x3FF

        if exponent == 0 {
            if mantissa == 0 { return sign == 1 ? -0.0 : 0.0 }
            var f = Float32(mantissa) / 1024.0
            f *= powf(2.0, -14.0)
            return sign == 1 ? -f : f
        } else if exponent == 31 {
            return mantissa == 0 ? (sign == 1 ? -.infinity : .infinity) : .nan
        }

        let f32Bits = (sign << 31) | ((exponent + 112) << 23) | (mantissa << 13)
        return Float32(bitPattern: f32Bits)
    }

    // MARK: - テキスト前処理

    private func stripParticles(_ text: String) -> String {
        var result = text
        let suffixes = ["の人", "した人", "関係の", "関係", "関連の", "関連",
                        "にいる", "にある", "の名刺", "会った", "もらった",
                        "交換した", "した", "という", "って", "系の", "系"]
        for s in suffixes {
            result = result.replacingOccurrences(of: s, with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func containsLocationKeywords(_ query: String) -> Bool {
        let prefectures = ["北海道", "青森", "岩手", "宮城", "秋田", "山形", "福島",
                           "茨城", "栃木", "群馬", "埼玉", "千葉", "東京", "神奈川",
                           "新潟", "富山", "石川", "福井", "山梨", "長野", "岐阜",
                           "静岡", "愛知", "三重", "滋賀", "京都", "大阪", "兵庫",
                           "奈良", "和歌山", "鳥取", "島根", "岡山", "広島", "山口",
                           "徳島", "香川", "愛媛", "高知", "福岡", "佐賀", "長崎",
                           "熊本", "大分", "宮崎", "鹿児島", "沖縄"]
        let locationSuffixes = ["都", "道", "府", "県", "市", "区", "町", "村", "郡"]

        for pref in prefectures {
            if query.contains(pref) { return true }
        }
        for suffix in locationSuffixes {
            if query.contains(suffix) { return true }
        }
        return false
    }

    // MARK: - カードサマリ生成

    private func compactSummary(card: BusinessCard) -> String {
        [card.fullName, card.company, card.department, card.title, card.address]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
