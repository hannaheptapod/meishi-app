import Foundation
import Vision
import UIKit
import CoreImage

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
        let ciContext = CIContext()
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

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                // 各Observationから最上位候補のテキスト・信頼度・boundingBox を取得
                let lines: [RecognizedLine] = observations.compactMap { obs in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return RecognizedLine(
                        text: candidate.string,
                        boundingBox: obs.boundingBox,
                        confidence: candidate.confidence
                    )
                }
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
                continuation.resume(throwing: error)
            }
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
