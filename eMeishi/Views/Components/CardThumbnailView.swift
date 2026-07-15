import SwiftUI
import UIKit

/// 不可視の正方形領域へ、名刺画像を長辺基準・中央揃えで表示する。
struct CardThumbnailView: View {
    @ObservedObject var card: BusinessCard
    var size: CGFloat = 58

    var body: some View {
        Group {
            if let data = card.imageData, let image = UIImage(data: data) {
                let displaySize = CardThumbnailService.displaySize(
                    for: image.size,
                    containerSide: size
                )
                Image(uiImage: image)
                    .resizable()
                    .frame(width: displaySize.width, height: displaySize.height)
                    .accessibilityHidden(true)
            } else {
                CardAvatarView(card: card, size: size)
            }
        }
        .frame(width: size, height: size, alignment: .center)
    }
}
