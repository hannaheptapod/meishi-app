import Foundation
import UIKit

// CardFormViewModel の依存サービスを抽象化するプロトコル群。
// テスト時に Mock を注入できるようにし、OCR・分類・LLM・AutoTag の
// 各パスをユニットテスト可能にする。

// MARK: - OCR

protocol OCRServiceProtocol {
    func detectAndCropCard(from image: UIImage) async -> UIImage
    func recognizeText(from image: UIImage) async throws -> [RecognizedLine]
}

extension OCRService: OCRServiceProtocol {}

// MARK: - フィールド分類

protocol CardFieldClassifierProtocol {
    func classifyStructuredFields(lines: [RecognizedLine]) -> CardFieldClassifier.StructuredFieldsResult
}

extension CardFieldClassifier: CardFieldClassifierProtocol {}

// MARK: - ローカル LLM (Qwen)

protocol LocalLLMServiceProtocol {
    var isModelAvailable: Bool { get }
    func classifyUnclassifiedLines(_ lines: [String]) async -> CardFieldClassifier.ParsedCard?
    func resolveFields(request: CardFieldResolutionRequest) async -> [CardFieldDecision]
}

extension LocalLLMServiceProtocol {
    func resolveFields(request: CardFieldResolutionRequest) async -> [CardFieldDecision] { [] }
}

extension LocalLLMService: LocalLLMServiceProtocol {}

// MARK: - AutoTag

protocol AutoTagServiceProtocol {
    func suggestTags(cardInfo: AutoTagService.CardInfo, tags: [AutoTagService.TagInfo]) async -> [UUID]
}

extension AutoTagService: AutoTagServiceProtocol {}

// MARK: - 設定

@MainActor
protocol SettingsProviding {
    var readingMethod: ReadingMethod { get }
}

extension SettingsStore: SettingsProviding {}
