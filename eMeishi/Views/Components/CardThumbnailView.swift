import SwiftUI

/// 不可視の正方形領域へ、名刺画像を長辺基準・中央揃えで表示する。
struct CardThumbnailView: View {
    @ObservedObject var card: BusinessCard
    var size: CGFloat = 64
    @State private var decodedImage: UIImage?
    @State private var decodedImageIdentifier: String?

    var body: some View {
        Group {
            if card.imageData != nil,
               decodedImageIdentifier == imageRequestIdentifier,
               let image = decodedImage {
                let displaySize = CardThumbnailService.displaySize(
                    for: image.size,
                    containerSide: size
                )
                Image(uiImage: image)
                    .resizable()
                    .frame(width: displaySize.width, height: displaySize.height)
                    .accessibilityHidden(true)
            } else if card.imageData != nil {
                ZStack {
                    RoundedRectangle(cornerRadius: AppTheme.imageCornerRadius, style: .continuous)
                        .fill(AppTheme.auxiliarySurface)
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.secondary)
                }
                .frame(width: size, height: size)
                .accessibilityHidden(true)
            } else {
                CardAvatarView(card: card, size: size)
            }
        }
        .frame(width: size, height: size, alignment: .center)
        .task(id: imageRequestIdentifier) {
            guard let data = card.imageData,
                  let cacheIdentifier = imageRequestIdentifier else { return }
            // 詳細から戻って同じtaskが再開しても、表示中のキャッシュ画像を消さない。
            if decodedImage != nil, decodedImageIdentifier == cacheIdentifier { return }
            let decoded = await CardImageDecodingService.shared.image(
                from: data,
                maximumPixelSize: size * 3,
                cacheIdentifier: cacheIdentifier
            )
            guard !Task.isCancelled else { return }
            decodedImage = decoded?.image
            decodedImageIdentifier = decoded == nil ? nil : cacheIdentifier
        }
    }

    private var imageRequestIdentifier: String? {
        guard let data = card.imageData else { return nil }
        return CardImageCacheKey.businessCard(card, dataCount: data.count)
    }
}
