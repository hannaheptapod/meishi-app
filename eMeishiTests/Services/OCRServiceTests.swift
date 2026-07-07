import Testing
import CoreGraphics
@testable import eMeishi

// MARK: - OCR 後処理テスト

struct OCRServiceTests {

    @Test func mergeAdjacentFragmentsKeepsHorizontalNameMerge() {
        let lines = [
            makeLine("田中", midX: 0.42, midY: 0.70, width: 0.12, height: 0.06),
            makeLine("花子", midX: 0.55, midY: 0.70, width: 0.08, height: 0.06),
        ]

        let merged = OCRService.mergeAdjacentFragments(lines)

        #expect(merged.count == 1)
        #expect(merged.first?.text == "田中花子")
    }

    @Test func mergeAdjacentFragmentsDoesNotUseVerticalModeForHorizontalCards() {
        let lines = [
            makeLine("田中", midX: 0.42, midY: 0.70, width: 0.12, height: 0.06),
            makeLine("花子", midX: 0.55, midY: 0.70, width: 0.08, height: 0.06),
        ]

        let merged = OCRService.mergeAdjacentFragments(lines, isVerticalCard: false)

        #expect(merged.count == 1)
        #expect(merged.first?.text == "田中花子")
    }

    @Test func mergeAdjacentFragmentsDoesNotVerticallyMergeHorizontalTextOnPortraitCard() {
        let lines = [
            makeLine("田中 花子", midX: 0.30, midY: 0.72, width: 0.20, height: 0.05),
            makeLine("サンプル株式会社", midX: 0.32, midY: 0.62, width: 0.28, height: 0.05),
            makeLine("営業部", midX: 0.28, midY: 0.54, width: 0.12, height: 0.05),
        ]

        let merged = OCRService.mergeAdjacentFragments(lines, isVerticalCard: true)
        let texts = merged.map { $0.text }

        #expect(texts.contains("田中 花子"))
        #expect(texts.contains("サンプル株式会社"))
        #expect(texts.contains("営業部"))
        #expect(!texts.contains("田中 花子サンプル株式会社営業部"))
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
            makeLine("hanako", midX: 0.72, midY: 0.82, width: 0.18, height: 0.04),
            makeLine("tanaka@example.com", midX: 0.72, midY: 0.72, width: 0.30, height: 0.04),
            makeLine("03-0000-0000", midX: 0.72, midY: 0.62, width: 0.24, height: 0.04),
        ]

        let merged = OCRService.mergeAdjacentFragments(lines, isVerticalCard: true)
        let texts = merged.map { $0.text }

        #expect(texts.contains("hanako"))
        #expect(texts.contains("tanaka@example.com"))
        #expect(texts.contains("03-0000-0000"))
        #expect(!texts.contains("hanakotanaka@example.com03-0000-0000"))
    }
}
