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

    @Test func bestCardRectPrefersOuterCardOverCenteredLogoAndQRCode() throws {
        let candidates: [(rect: CGRect, confidence: Float)] = [
            (CGRect(x: 0.08, y: 0.22, width: 0.84, height: 0.49), 0.88),
            (CGRect(x: 0.34, y: 0.38, width: 0.32, height: 0.20), 0.99),
            (CGRect(x: 0.72, y: 0.28, width: 0.14, height: 0.14), 0.99),
        ]

        let index = try #require(OCRService.bestCardRectIndex(candidates: candidates))

        #expect(index == 0)
    }

    @Test func bestCardRectRejectsOnlyTinyInnerCandidates() {
        let candidates: [(rect: CGRect, confidence: Float)] = [
            (CGRect(x: 0.42, y: 0.44, width: 0.12, height: 0.08), 1.0),
            (CGRect(x: 0.75, y: 0.65, width: 0.10, height: 0.10), 1.0),
        ]

        #expect(OCRService.bestCardRectIndex(candidates: candidates) == nil)
    }

    // #187: 影で名刺外周が検出できず、内側のロゴ矩形だけが高confidenceで
    // 返った場合は候補なしとし、誤クロップせず元画像維持へ倒す。
    @Test func bestCardRectRejectsLoneCenteredLogoRectangle() {
        let candidates: [(rect: CGRect, confidence: Float)] = [
            (CGRect(x: 0.34, y: 0.38, width: 0.32, height: 0.20), 0.99),
        ]

        #expect(OCRService.bestCardRectIndex(candidates: candidates) == nil)
    }

    // #187: 影の影響でconfidenceが下がった名刺外周でも、
    // 高confidenceの小さな内側矩形より優先される。
    @Test func bestCardRectPrefersShadowedOuterCardOverConfidentInnerLogo() throws {
        let candidates: [(rect: CGRect, confidence: Float)] = [
            (CGRect(x: 0.36, y: 0.40, width: 0.34, height: 0.20), 0.99),
            (CGRect(x: 0.06, y: 0.20, width: 0.86, height: 0.50), 0.50),
        ]

        let index = try #require(OCRService.bestCardRectIndex(candidates: candidates))

        #expect(index == 1)
    }

    // 寄り撮影では名刺が画面の大半を占め、正規化座標のアスペクト比が 1.0 へ
    // 近づく。旧実装は上限 0.90 の足切りで候補ゼロ（= 無補正）にしていた。
    @Test func bestCardRectAcceptsCloseUpCardFillingFrame() throws {
        let candidates: [(rect: CGRect, confidence: Float)] = [
            (CGRect(x: 0.01, y: 0.03, width: 0.98, height: 0.92), 0.95),
        ]

        let index = try #require(OCRService.bestCardRectIndex(candidates: candidates))

        #expect(index == 0)
    }

    // 画像の外縁とほぼ一致する矩形は枠検出の誤りとして明示的に棄却する。
    @Test func bestCardRectRejectsFullFrameRectangle() {
        let candidates: [(rect: CGRect, confidence: Float)] = [
            (CGRect(x: 0, y: 0, width: 1.0, height: 0.97), 1.0),
        ]

        #expect(OCRService.bestCardRectIndex(candidates: candidates) == nil)
    }

    // 画面の大半を覆う背景パネルより、名刺比率の矩形を優先する（漸増ペナルティ）。
    @Test func bestCardRectPrefersCardOverBackgroundPanel() throws {
        let candidates: [(rect: CGRect, confidence: Float)] = [
            (CGRect(x: 0.02, y: 0.10, width: 0.96, height: 0.78), 0.90),
            (CGRect(x: 0.15, y: 0.30, width: 0.70, height: 0.42), 1.0),
        ]

        let index = try #require(OCRService.bestCardRectIndex(candidates: candidates))

        #expect(index == 1)
    }

    // 補正後アスペクト検証: 名刺の実比率（日本 0.604 / US 0.571）を含む範囲を通す。
    @Test func isPlausibleCardAspectAcceptsBusinessCardProportions() {
        #expect(OCRService.isPlausibleCardAspect(CGSize(width: 91, height: 55)))
        #expect(OCRService.isPlausibleCardAspect(CGSize(width: 55, height: 91)))
        #expect(OCRService.isPlausibleCardAspect(CGSize(width: 350, height: 200)))
    }

    // 極端に細長い補正出力は部分矩形（罫線帯など）の誤検出とみなす。
    @Test func isPlausibleCardAspectRejectsElongatedOutput() {
        #expect(!OCRService.isPlausibleCardAspect(CGSize(width: 1_000, height: 250)))
    }

    // 正方形に近い補正出力は頂点の取り違えを示す。
    @Test func isPlausibleCardAspectRejectsNearSquareOutput() {
        #expect(!OCRService.isPlausibleCardAspect(CGSize(width: 500, height: 480)))
        #expect(!OCRService.isPlausibleCardAspect(CGSize(width: 0, height: 100)))
    }

    // Vision の返却順はスコア順ではないため、順序が変わっても同じ矩形を選ぶ。
    @Test func bestCardRectIsIndependentOfVisionOrder() throws {
        let candidates: [(rect: CGRect, confidence: Float)] = [
            (CGRect(x: 0.72, y: 0.28, width: 0.14, height: 0.14), 0.99),
            (CGRect(x: 0.34, y: 0.38, width: 0.32, height: 0.20), 0.99),
            (CGRect(x: 0.08, y: 0.22, width: 0.84, height: 0.49), 0.88),
        ]

        let index = try #require(OCRService.bestCardRectIndex(candidates: candidates))

        #expect(index == 2)
    }

    // スコア差がトレランス未満の同点候補では Vision が先に返した候補を選ぶ。
    @Test func bestCardRectFallsBackToVisionOrderOnNearTie() throws {
        let cardRect = CGRect(x: 0.12, y: 0.24, width: 0.62, height: 0.36)
        let candidates: [(rect: CGRect, confidence: Float)] = [
            (cardRect, 1.0),
            (cardRect, 1.0),
        ]

        let index = try #require(OCRService.bestCardRectIndex(candidates: candidates))

        #expect(index == 0)
    }

    // スコア正規化（0〜1）後も旧絶対値 5.3（= 0.609）と同じ分割で採否が決まる。
    // 下の候補は confidence 以外の項が同一で、閾値 0.61 を挟んで採用・棄却が分かれる。
    @Test func bestCardRectScoreThresholdMatchesLegacyAbsoluteScale() {
        let boundaryRect = CGRect(x: 0.30, y: 0.35, width: 0.40, height: 0.24)

        let justAbove = OCRService.bestCardRectIndex(
            candidates: [(rect: boundaryRect, confidence: 0.92)]
        )
        let justBelow = OCRService.bestCardRectIndex(
            candidates: [(rect: boundaryRect, confidence: 0.78)]
        )

        #expect(justAbove == 0)
        #expect(justBelow == nil)
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

    // 横位置の名刺を縦向きに撮ると画像は縦長になるが、横書き行（.leftToRight）が
    // 検出されていれば縦書き名刺ではない。形状フォールバックで縦結合しない。
    @Test func mergeAdjacentFragmentsIgnoresPortraitAspectWhenHorizontalTextDetected() {
        let lines = [
            makeLine("役員", midX: 0.30, midY: 0.70, width: 0.05, height: 0.09, textDirection: .leftToRight),
            makeLine("秘書", midX: 0.30, midY: 0.55, width: 0.05, height: 0.09, textDirection: .leftToRight),
        ]

        let merged = OCRService.mergeAdjacentFragments(lines, isVerticalCard: true)
        let texts = merged.map { $0.text }

        #expect(texts.contains("役員"))
        #expect(texts.contains("秘書"))
        #expect(!texts.contains("役員秘書"))
    }

    // 横長画像でも Vision が .topToBottom を報告した行は縦書きとして結合する。
    @Test func mergeAdjacentFragmentsUsesVerticalModeForLandscapeCardWithTopToBottomText() {
        let lines = [
            makeLine("山", midX: 0.62, midY: 0.78, width: 0.04, height: 0.05, textDirection: .topToBottom),
            makeLine("田", midX: 0.62, midY: 0.70, width: 0.04, height: 0.05, textDirection: .topToBottom),
        ]

        let merged = OCRService.mergeAdjacentFragments(lines, isVerticalCard: false)

        #expect(merged.map { $0.text } == ["山田"])
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
