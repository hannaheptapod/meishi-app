import Foundation
import ImageIO
import UIKit

/// OCR入力用の画像変換をMainActorから隔離する。
///
/// 元画像はImageIOで長辺を制限してから1枚だけ展開し、外周補正後のJPEG Dataを返す。
/// バッチ処理の呼出し側はUIImageを所有せず、CardImageInputだけを正本として保持する。
actor CardImageProcessingService {
    static let shared = CardImageProcessingService()

    enum ProcessingError: Error, Sendable {
        case unsupportedFormat
        case corruptImage
    }

    private let ocrService = OCRService()

    func prepareInput(
        from sourceData: Data,
        source: CardImageInput.Source,
        maximumPixelSize: Int = 3_000,
        compressionQuality: CGFloat = 0.82
    ) async throws -> CardImageInput {
        try Task.checkCancellation()
        let image = try decodeImage(
            from: sourceData,
            maximumPixelSize: maximumPixelSize
        )
        try Task.checkCancellation()

        let croppedImage = await ocrService.detectAndCropCard(from: image)
        try Task.checkCancellation()
        guard let normalizedData = croppedImage.jpegData(
            compressionQuality: compressionQuality
        ) else {
            throw ProcessingError.unsupportedFormat
        }
        return CardImageInput(data: normalizedData, source: source)
    }

    /// 既に向き補正・縮小・圧縮済みのDataを、現在処理する1枚だけUIImageへ展開する。
    /// 保存用Dataは呼出し側がそのまま保持するため、ここでは再JPEG圧縮しない。
    func decodeNormalizedImage(
        from data: Data,
        maximumPixelSize: Int = 3_000
    ) throws -> DecodedCardImage {
        try Task.checkCancellation()
        return DecodedCardImage(
            image: try decodeImage(
                from: data,
                maximumPixelSize: maximumPixelSize
            )
        )
    }

    private func decodeImage(
        from data: Data,
        maximumPixelSize: Int
    ) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw ProcessingError.unsupportedFormat
        }

        let status = CGImageSourceGetStatus(source)
        guard status == .statusComplete || status == .statusIncomplete else {
            throw ProcessingError.corruptImage
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw ProcessingError.corruptImage
        }
        return UIImage(cgImage: thumbnail, scale: 1, orientation: .up)
    }
}
