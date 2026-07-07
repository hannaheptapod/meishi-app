import Testing
import CoreGraphics
@testable import eMeishi

// MARK: - OCR 後処理テスト

struct OCRServiceTests {

    @Test func mergeAdjacentFragmentsKeepsHorizontalNameMerge() {
        let lines = [
            makeLine("岸本", midX: 0.42, midY: 0.70, width: 0.12, height: 0.06),
            makeLine("仁", midX: 0.55, midY: 0.70, width: 0.05, height: 0.06),
        ]

        let merged = OCRService.mergeAdjacentFragments(lines)

        #expect(merged.count == 1)
        #expect(merged.first?.text == "岸本仁")
    }

    @Test func mergeAdjacentFragmentsDoesNotUseVerticalModeForHorizontalCards() {
        let lines = [
            makeLine("岸本", midX: 0.42, midY: 0.70, width: 0.12, height: 0.06, textDirection: .topToBottom),
            makeLine("仁", midX: 0.55, midY: 0.70, width: 0.05, height: 0.06, textDirection: .topToBottom),
        ]

        let merged = OCRService.mergeAdjacentFragments(lines, isVerticalCard: false)

        #expect(merged.count == 1)
        #expect(merged.first?.text == "岸本仁")
    }

    @Test func mergeAdjacentFragmentsMergesVerticalJapaneseColumnsRightToLeft() {
        let lines = [
            makeLine("株", midX: 0.80, midY: 0.82, width: 0.04, height: 0.05, textDirection: .topToBottom),
            makeLine("式", midX: 0.80, midY: 0.74, width: 0.04, height: 0.05, textDirection: .topToBottom),
            makeLine("会", midX: 0.80, midY: 0.66, width: 0.04, height: 0.05, textDirection: .topToBottom),
            makeLine("社", midX: 0.80, midY: 0.58, width: 0.04, height: 0.05, textDirection: .topToBottom),
            makeLine("山", midX: 0.62, midY: 0.78, width: 0.04, height: 0.05, textDirection: .topToBottom),
            makeLine("田", midX: 0.62, midY: 0.70, width: 0.04, height: 0.05, textDirection: .topToBottom),
        ]

        let merged = OCRService.mergeAdjacentFragments(lines, isVerticalCard: true)
        let texts = merged.map { $0.text }

        #expect(texts == ["株式会社", "山田"])
        #expect(merged.allSatisfy { $0.textDirection == .topToBottom })
    }

    @Test func mergeAdjacentFragmentsDoesNotVerticallyMergeAsciiContacts() {
        let lines = [
            makeLine("shinya", midX: 0.72, midY: 0.82, width: 0.18, height: 0.04),
            makeLine("sato@example.com", midX: 0.72, midY: 0.72, width: 0.30, height: 0.04),
            makeLine("03-1234-5678", midX: 0.72, midY: 0.62, width: 0.24, height: 0.04),
        ]

        let merged = OCRService.mergeAdjacentFragments(lines, isVerticalCard: true)
        let texts = merged.map { $0.text }

        #expect(texts.contains("shinya"))
        #expect(texts.contains("sato@example.com"))
        #expect(texts.contains("03-1234-5678"))
        #expect(!texts.contains("shinyasato@example.com03-1234-5678"))
    }
}
