import Foundation
import Vision
import UIKit
import CoreImage
import os

// OCR で認識した1行分のデータ（テキスト・位置・信頼度）
struct RecognizedLine {
    let text: String
    /// Vision 座標系（正規化済み。原点は画像左下、x/y は 0.0〜1.0）
    let boundingBox: CGRect
    /// Vision の認識信頼度（0.0〜1.0）
    let confidence: Float
}

// Vision Framework を使って名刺画像からテキストを抽出するサービス
class OCRService {

    private static let ciContext = CIContext()

    // MARK: - 矩形検出 + パースペクティブ補正

    // 名刺の矩形を検出してトリミング・補正した画像を返す。
    // 矩形が見つからない場合は元画像をそのまま返す。
    func detectAndCropCard(from image: UIImage) async -> UIImage {
        // EXIF向き情報を適用した正規化済み画像を使う
        let normalized = Self.normalizeOrientation(image)
        guard let cgImage = normalized.cgImage else { return image }

        return await withCheckedContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNRectangleObservation],
                      let rect = results.first else {
                    // 矩形未検出 → 元画像を返す
                    continuation.resume(returning: normalized)
                    return
                }
                let cropped = Self.perspectiveCorrected(cgImage: cgImage, observation: rect)
                continuation.resume(returning: cropped ?? normalized)
            }

            // 名刺に近いアスペクト比（横長・縦長どちらも許容）
            request.minimumAspectRatio = 0.4
            request.maximumAspectRatio = 2.5
            request.minimumConfidence  = 0.7
            request.maximumObservations = 1

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: normalized)
            }
        }
    }

    // MARK: - パースペクティブ補正（CIPerspectiveCorrection）

    private static func perspectiveCorrected(
        cgImage: CGImage,
        observation: VNRectangleObservation
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
        filter.setValue(toCI(observation.topLeft),       forKey: "inputTopLeft")
        filter.setValue(toCI(observation.topRight),      forKey: "inputTopRight")
        filter.setValue(toCI(observation.bottomLeft),    forKey: "inputBottomLeft")
        filter.setValue(toCI(observation.bottomRight),   forKey: "inputBottomRight")

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

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    AppLogger.ocr.error("OCR失敗: \(error)")
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                // 各Observationから最上位候補のテキスト・信頼度・boundingBox を取得
                let rawLines: [RecognizedLine] = observations.compactMap { obs in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return RecognizedLine(
                        text: candidate.string,
                        boundingBox: obs.boundingBox,
                        confidence: candidate.confidence
                    )
                }
                // 近接する短い断片行を統合（OCR が名前等を文字単位で分割する問題への対策）
                let lines = Self.mergeAdjacentFragments(rawLines)
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                AppLogger.ocr.info("OCR完了: \(lines.count, privacy: .public)行認識 \(String(format: "%.1f", elapsed), privacy: .public)秒")
                continuation.resume(returning: lines)
            }

            // 精度最大・言語補正あり・日本語＋英語対応
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ja-JP", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                AppLogger.ocr.error("OCR失敗: \(error)")
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - 行統合

    /// Vision が等間隔文字や空白区切りで分断した行を統合する。
    ///
    /// 名刺では名前を均等配置する慣習があり、OCR が「岸本」「仁」のように
    /// 1つの名前を複数の observation に分割することがある。
    /// 同一行（Y座標近接）かつ X 方向に近い短い断片を結合し、
    /// 下流の分類ロジックに安定した行を渡す。
    static func mergeAdjacentFragments(_ lines: [RecognizedLine]) -> [RecognizedLine] {
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
                result.append(RecognizedLine(text: mergedText, boundingBox: mergedBox, confidence: avgConfidence))
            }
        }

        // 元の Y 座標順（上から下 = Vision Y 降順）で返す
        return result.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
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
