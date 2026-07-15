import CoreGraphics

/// 名刺画像をクロップせず、長辺だけを表示領域へ合わせる寸法計算。
enum CardThumbnailService {
    nonisolated static func displaySize(
        for imageSize: CGSize,
        containerSide: CGFloat = 58
    ) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: containerSide, height: containerSide)
        }
        let scale = containerSide / max(imageSize.width, imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}
