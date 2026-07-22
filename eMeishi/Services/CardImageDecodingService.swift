import CoreData
import ImageIO
import UIKit

/// UIKit画像をactor境界の外へ返すための不変ラッパー。
/// UIImageは値として生成後に変更せず、SwiftUI表示専用として扱う。
struct DecodedCardImage: @unchecked Sendable {
    let image: UIImage
}

/// CoreDataオブジェクトの更新世代から、Data全体を走査しない画像キャッシュキーを作る。
@MainActor
enum CardImageCacheKey {
    static func businessCard(_ card: BusinessCard, dataCount: Int) -> String {
        let objectID = card.objectID.uriRepresentation().absoluteString
        let revision = card.updatedAt?.timeIntervalSinceReferenceDate ?? 0
        return "\(objectID)|\(revision)|\(dataCount)"
    }
}

/// 一覧・詳細用画像を表示サイズに合わせて縮小デコードし、再描画時の全画像デコードを避ける。
actor CardImageDecodingService {
    static let shared = CardImageDecodingService()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()

    func image(
        from data: Data,
        maximumPixelSize: CGFloat,
        cacheIdentifier: String
    ) -> DecodedCardImage? {
        let pixelSize = max(1, Int(maximumPixelSize.rounded(.up)))
        let key = "\(cacheIdentifier)-\(pixelSize)" as NSString
        if let cached = cache.object(forKey: key) {
            return DecodedCardImage(image: cached)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let image = UIImage(cgImage: cgImage)
        cache.setObject(
            image,
            forKey: key,
            cost: cgImage.bytesPerRow * cgImage.height
        )
        return DecodedCardImage(image: image)
    }
}
