import Testing
import CoreGraphics
import Vision
import UIKit
@testable import eMeishi

// MARK: - OCR 後処理テスト

struct OCRServiceTests {

    @Test func cardRectangleRequestKeepsLegacyCropSettings() {
        let request = OCRService.cardRectangleRequest()

        #expect(abs(request.minimumAspectRatio - 0.32) < 0.001)
        #expect(abs(request.maximumAspectRatio - 1.0) < 0.001)
        #expect(abs(request.minimumConfidence - 0.45) < 0.001)
        #expect(abs(request.minimumSize - 0.04) < 0.001)
        #expect(request.maximumObservations == 20)
    }

    @Test func cardRectangleRequestPerformsWithNewVisionAspectRange() async throws {
        let image = makeSyntheticCardImage(size: CGSize(width: 640, height: 960))
        let cgImage = try #require(image.cgImage)
        let request = OCRService.cardRectangleRequest()

        _ = try await request.perform(on: cgImage)
    }

    @Test func bestCardRectPrefersBusinessCardCandidateOverWideContainer() throws {
        let candidates: [(rect: CGRect, confidence: Float)] = [
            (CGRect(x: 0.04, y: 0.52, width: 0.92, height: 0.29), 1.0),
            (CGRect(x: 0.07, y: 0.53, width: 0.43, height: 0.26), 1.0),
        ]

        let index = try #require(OCRService.bestCardRectIndex(candidates: candidates))

        #expect(index == 1)
    }

    @Test func bestCardRectKeepsVisionOrderForPlausibleFirstCandidate() throws {
        let candidates: [(rect: CGRect, confidence: Float)] = [
            (CGRect(x: 0.12, y: 0.24, width: 0.62, height: 0.36), 1.0),
            (CGRect(x: 0.14, y: 0.26, width: 0.58, height: 0.34), 1.0),
        ]

        let index = try #require(OCRService.bestCardRectIndex(candidates: candidates))

        #expect(index == 0)
    }

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

private func makeSyntheticCardImage(size: CGSize) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
        UIColor.black.setFill()
        context.fill(CGRect(origin: .zero, size: size))

        UIColor.white.setFill()
        let cardRect = CGRect(x: size.width * 0.22, y: size.height * 0.18, width: size.width * 0.56, height: size.height * 0.64)
        context.fill(cardRect)

        UIColor.lightGray.setStroke()
        context.cgContext.setLineWidth(2)
        context.cgContext.stroke(cardRect)
    }
}
