import Foundation
import Vision
import UIKit
import CoreImage
import os

// OCR で認識した1行分のデータ（テキスト・位置・信頼度）
nonisolated enum RecognizedTextDirection: Sendable, Equatable {
    case leftToRight
    case rightToLeft
    case topToBottom
    case unknown
}

nonisolated struct RecognizedLine: Sendable {
    let text: String
    /// Vision 座標系（正規化済み。原点は画像左下、x/y は 0.0〜1.0）
    let boundingBox: CGRect
    /// Vision の認識信頼度（0.0〜1.0）
    let confidence: Float
    /// OCR が返した文字方向。縦書き名刺の後処理で使用する
    let textDirection: RecognizedTextDirection

    init(
        text: String,
        boundingBox: CGRect,
        confidence: Float,
        textDirection: RecognizedTextDirection = .unknown
    ) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.textDirection = textDirection
    }
}

// Vision Framework を使って名刺画像からテキストを抽出するサービス
actor OCRService {

    private static let ciContext = CIContext()

    // MARK: - 矩形検出 + パースペクティブ補正

    // 名刺の矩形を検出してトリミング・補正した画像を返す。
    // 矩形が見つからない場合は元画像をそのまま返す。
    func detectAndCropCard(from image: UIImage) async -> UIImage {
        // EXIF向き情報を適用した正規化済み画像を使う
        let normalized = Self.normalizeOrientation(image)
        guard let cgImage = normalized.cgImage else { return image }

        do {
            var request = DetectRectanglesRequest()
            // 名刺に近いアスペクト比（横長・縦長どちらも許容）
            request.minimumAspectRatio = 0.4
            request.maximumAspectRatio = 2.5
            request.minimumConfidence = 0.7
            request.maximumObservations = 1

            guard let rect = try await request.perform(on: cgImage).first else {
                // 矩形未検出 → 元画像を返す
                return normalized
            }
            return Self.perspectiveCorrected(cgImage: cgImage, observation: rect) ?? normalized
        } catch {
            return normalized
        }
    }

    // MARK: - パースペクティブ補正（CIPerspectiveCorrection）

    private static func perspectiveCorrected(
        cgImage: CGImage,
        observation: RectangleObservation
    ) -> UIImage? {
        let width  = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        // Vision の正規化座標（左下原点）→ Core Image のピクセル座標（左下原点）へ変換
        func toCI(_ point: CGPoint) -> CIVector {
            CIVector(x: point.x * width, y: point.y * height)
        }

        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(ciImage,                         forKey: kCIInputImageKey)
        filter.setValue(toCI(observation.topLeft.cgPoint), forKey: "inputTopLeft")
        filter.setValue(toCI(observation.topRight.cgPoint), forKey: "inputTopRight")
        filter.setValue(toCI(observation.bottomLeft.cgPoint), forKey: "inputBottomLeft")
        filter.setValue(toCI(observation.bottomRight.cgPoint), forKey: "inputBottomRight")

        guard let outputCIImage = filter.outputImage else { return nil }
        guard let outputCGImage = ciContext.createCGImage(outputCIImage, from: outputCIImage.extent) else { return nil }
        return UIImage(cgImage: outputCGImage)
    }

    // MARK: - 向き正規化

    private static func normalizeOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    // MARK: - テキスト認識

    // 画像から RecognizedLine の配列を返す（精度優先・言語補正あり）
    // 各行のテキスト・Vision 正規化座標での位置・認識信頼度を同時に返す
    func recognizeText(from image: UIImage) async throws -> [RecognizedLine] {
        guard let cgImage = image.cgImage else {
            throw OCRError.invalidImage
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        AppLogger.ocr.info("OCR開始")

        do {
            var request = RecognizeTextRequest()
            // 精度最大・言語補正あり・日本語＋英語対応
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = [
                Locale.Language(identifier: "ja-JP"),
                Locale.Language(identifier: "en-US"),
            ]

            let observations = try await request.perform(on: cgImage)
            let rawLines: [RecognizedLine] = observations.compactMap { obs in
                let text = obs.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return RecognizedLine(
                    text: text,
                    boundingBox: obs.boundingBox.cgRect,
                    confidence: obs.confidence,
                    textDirection: Self.mapDirection(obs.textDirection)
                )
            }

            // 近接する短い断片行を統合（OCR が名前等を文字単位で分割する問題への対策）
            let lines = Self.mergeAdjacentFragments(
                rawLines,
                isVerticalCard: image.size.height > image.size.width * 1.1
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            AppLogger.ocr.info("OCR完了: \(lines.count, privacy: .public)行認識 \(String(format: "%.1f", elapsed), privacy: .public)秒")
            return lines
        } catch {
            AppLogger.ocr.error("OCR失敗: \(error)")
            throw error
        }
    }

    private static func mapDirection(
        _ direction: RecognizedTextObservation.Direction?
    ) -> RecognizedTextDirection {
        switch direction {
        case .leftToRight:
            return .leftToRight
        case .rightToLeft:
            return .rightToLeft
        case .topToBottom:
            return .topToBottom
        case .some:
            return .unknown
        case nil:
            return .unknown
        }
    }

    // MARK: - 行統合

    /// Vision が等間隔文字や空白区切りで分断した行を統合する。
    ///
    /// 名刺では名前を均等配置する慣習があり、OCR が「田中」「花子」のように
    /// 1つの名前を複数の observation に分割することがある。
    /// 同一行（Y座標近接）かつ X 方向に近い短い断片を結合し、
    /// 下流の分類ロジックに安定した行を渡す。
    static func mergeAdjacentFragments(
        _ lines: [RecognizedLine],
        isVerticalCard: Bool = false
    ) -> [RecognizedLine] {
        guard lines.count > 1 else { return lines }

        let shouldUseVerticalMerge = lines.contains { isVerticalMergeCandidate($0, isVerticalCard: isVerticalCard) }

        guard shouldUseVerticalMerge else {
            return mergeHorizontalFragments(lines)
        }

        let verticalCandidates = lines.filter { isVerticalMergeCandidate($0, isVerticalCard: isVerticalCard) }
        let horizontalCandidates = lines.filter { !isVerticalMergeCandidate($0, isVerticalCard: isVerticalCard) }

        let mergedVertical = mergeVerticalFragments(verticalCandidates)
        let mergedHorizontal = mergeHorizontalFragments(horizontalCandidates)
        return sortForReadingOrder(mergedVertical + mergedHorizontal, preferVertical: true)
    }

    private static func mergeHorizontalFragments(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        guard lines.count > 1 else { return lines }

        // インデックス管理用
        var used = Set<Int>()
        var result: [RecognizedLine] = []

        // Y 座標降順（Vision座標系: 上が大きい → 名刺の上から処理）
        let indexed = lines.enumerated().sorted {
            $0.element.boundingBox.midY > $1.element.boundingBox.midY
        }

        for (i, anchor) in indexed {
            if used.contains(i) { continue }
            used.insert(i)

            // この行と同一行の断片を収集
            var group: [(index: Int, line: RecognizedLine)] = [(i, anchor)]
            let anchorH = anchor.boundingBox.height

            for (j, candidate) in indexed {
                if used.contains(j) { continue }
                let candH = candidate.boundingBox.height
                let maxH = max(anchorH, candH)

                // 同一行判定: Y 中心の差が行の高さの 60% 以内
                guard abs(candidate.boundingBox.midY - anchor.boundingBox.midY) < maxH * 0.6 else {
                    continue
                }

                // X 近接判定: 既にグループに入っている行との間隔をチェック
                // グループ全体の左端〜右端を計算
                let groupMinX = group.map { $0.line.boundingBox.minX }.min()!
                let groupMaxX = group.map { $0.line.boundingBox.maxX }.max()!

                let candMinX = candidate.boundingBox.minX
                let candMaxX = candidate.boundingBox.maxX

                // 断片間のギャップ（正値＝離れている、負値＝重なっている）
                let gap: CGFloat
                if candMinX > groupMaxX {
                    gap = candMinX - groupMaxX
                } else if candMaxX < groupMinX {
                    gap = groupMinX - candMaxX
                } else {
                    gap = 0 // 重なっている
                }

                // ギャップが行の高さの 2 倍以内なら同一論理行とみなす
                // （名刺の名前は文字間を広げることがあるが、別フィールドはもっと離れる）
                if gap < maxH * 2.0 {
                    // 短い断片のみ統合（長い行同士は別フィールドの可能性が高い）
                    let anchorChars = anchor.text.trimmingCharacters(in: .whitespaces).count
                    let candChars = candidate.text.trimmingCharacters(in: .whitespaces).count
                    if anchorChars <= 4 || candChars <= 4 {
                        used.insert(j)
                        group.append((j, candidate))
                    }
                }
            }

            if group.count == 1 {
                result.append(anchor)
            } else {
                // X 座標順（左→右）にソートして結合
                let sorted = group.sorted { $0.line.boundingBox.midX < $1.line.boundingBox.midX }
                let mergedText = sorted.map { $0.line.text.trimmingCharacters(in: .whitespaces) }.joined()
                // 結合後の bounding box は全断片を包含する矩形
                let minX = sorted.map { $0.line.boundingBox.minX }.min()!
                let minY = sorted.map { $0.line.boundingBox.minY }.min()!
                let maxX = sorted.map { $0.line.boundingBox.maxX }.max()!
                let maxY = sorted.map { $0.line.boundingBox.maxY }.max()!
                let mergedBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                let avgConfidence = sorted.map { $0.line.confidence }.reduce(0, +) / Float(sorted.count)

                AppLogger.ocr.debug("行統合: \(sorted.map { "'\($0.line.text)'" }.joined(separator: " + "), privacy: .private) → \(mergedText, privacy: .private)")
                result.append(RecognizedLine(
                    text: mergedText,
                    boundingBox: mergedBox,
                    confidence: avgConfidence,
                    textDirection: dominantDirection(sorted.map { $0.line })
                ))
            }
        }

        // 元の Y 座標順（上から下 = Vision Y 降順）で返す
        return result.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
    }

    private static func mergeVerticalFragments(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        guard lines.count > 1 else { return lines }

        var used = Set<Int>()
        var result: [RecognizedLine] = []
        // 日本語縦書きの読み順: 右列から左列。同一列内は上から下。
        let indexed = lines.enumerated().sorted {
            if abs($0.element.boundingBox.midX - $1.element.boundingBox.midX) > 0.01 {
                return $0.element.boundingBox.midX > $1.element.boundingBox.midX
            }
            return $0.element.boundingBox.midY > $1.element.boundingBox.midY
        }

        for (i, anchor) in indexed {
            if used.contains(i) { continue }
            used.insert(i)

            var group: [(index: Int, line: RecognizedLine)] = [(i, anchor)]
            let anchorW = anchor.boundingBox.width

            for (j, candidate) in indexed {
                if used.contains(j) { continue }
                let candW = candidate.boundingBox.width
                let maxW = max(anchorW, candW)

                let groupMinX = group.map { $0.line.boundingBox.minX }.min()!
                let groupMaxX = group.map { $0.line.boundingBox.maxX }.max()!
                let groupMinY = group.map { $0.line.boundingBox.minY }.min()!
                let groupMaxY = group.map { $0.line.boundingBox.maxY }.max()!

                let xOverlap = min(groupMaxX, candidate.boundingBox.maxX) - max(groupMinX, candidate.boundingBox.minX)
                let sameColumn = abs(candidate.boundingBox.midX - anchor.boundingBox.midX) < maxW * 0.8
                    || xOverlap > min(maxW, candidate.boundingBox.width) * 0.35
                guard sameColumn else { continue }

                let gap: CGFloat
                if candidate.boundingBox.minY > groupMaxY {
                    gap = candidate.boundingBox.minY - groupMaxY
                } else if candidate.boundingBox.maxY < groupMinY {
                    gap = groupMinY - candidate.boundingBox.maxY
                } else {
                    gap = 0
                }

                if gap < maxW * 2.4 {
                    let anchorChars = anchor.text.trimmingCharacters(in: .whitespaces).count
                    let candChars = candidate.text.trimmingCharacters(in: .whitespaces).count
                    if anchorChars <= 6 || candChars <= 6 {
                        used.insert(j)
                        group.append((j, candidate))
                    }
                }
            }

            if group.count == 1 {
                result.append(anchor)
            } else {
                let sorted = group.sorted { $0.line.boundingBox.midY > $1.line.boundingBox.midY }
                let mergedText = sorted.map { $0.line.text.trimmingCharacters(in: .whitespaces) }.joined()
                let mergedBox = unionBoundingBox(sorted.map { $0.line })
                let avgConfidence = sorted.map { $0.line.confidence }.reduce(0, +) / Float(sorted.count)

                AppLogger.ocr.debug("縦書き行統合: \(sorted.map { "'\($0.line.text)'" }.joined(separator: " + "), privacy: .private) → \(mergedText, privacy: .private)")
                result.append(RecognizedLine(
                    text: mergedText,
                    boundingBox: mergedBox,
                    confidence: avgConfidence,
                    textDirection: .topToBottom
                ))
            }
        }

        return sortForReadingOrder(result, preferVertical: true)
    }

    private static func isVerticalMergeCandidate(_ line: RecognizedLine, isVerticalCard: Bool) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard !isContactLike(text), !isMostlyASCII(text) else { return false }
        let hasJapanese = text.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }
        guard hasJapanese else { return false }
        if line.textDirection == .topToBottom { return true }
        guard isVerticalCard else { return false }
        return line.boundingBox.height > line.boundingBox.width * 1.4
    }

    private static func isContactLike(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("@") || lower.contains("http") || lower.contains("www.") { return true }
        let digits = text.unicodeScalars.filter { (0x30...0x39).contains($0.value) }.count
        if digits >= 7 { return true }
        if text.range(of: #"^\+?[0-9][0-9\-()\s]{5,}$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func isMostlyASCII(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty else { return false }
        let asciiCount = scalars.filter { $0.isASCII }.count
        return Double(asciiCount) / Double(scalars.count) >= 0.7
    }

    private static func unionBoundingBox(_ lines: [RecognizedLine]) -> CGRect {
        let minX = lines.map { $0.boundingBox.minX }.min() ?? 0
        let minY = lines.map { $0.boundingBox.minY }.min() ?? 0
        let maxX = lines.map { $0.boundingBox.maxX }.max() ?? 0
        let maxY = lines.map { $0.boundingBox.maxY }.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func dominantDirection(_ lines: [RecognizedLine]) -> RecognizedTextDirection {
        if lines.contains(where: { $0.textDirection == .topToBottom }) { return .topToBottom }
        if lines.contains(where: { $0.textDirection == .rightToLeft }) { return .rightToLeft }
        if lines.contains(where: { $0.textDirection == .leftToRight }) { return .leftToRight }
        return .unknown
    }

    private static func sortForReadingOrder(_ lines: [RecognizedLine], preferVertical: Bool) -> [RecognizedLine] {
        guard preferVertical else {
            return lines.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        }
        return lines.sorted {
            let maxW = max($0.boundingBox.width, $1.boundingBox.width)
            if abs($0.boundingBox.midX - $1.boundingBox.midX) > maxW * 0.6 {
                return $0.boundingBox.midX > $1.boundingBox.midX
            }
            return $0.boundingBox.midY > $1.boundingBox.midY
        }
    }

    enum OCRError: LocalizedError {
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "画像の変換に失敗しました"
            }
        }
    }
}
