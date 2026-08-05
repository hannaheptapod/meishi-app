import CoreData
import SwiftUI

/// 不可視の正方形領域へ、名刺画像を長辺基準・中央揃えで表示する。
struct CardThumbnailView: View {
    let item: CardListItemSnapshot
    var size: CGFloat = 64
    @Environment(\.managedObjectContext) private var viewContext
    @State private var decodedImage: UIImage?
    @State private var decodedImageIdentifier: String?
    @State private var failedImageIdentifier: String?
    @State private var missingImageIdentifier: String?

    var body: some View {
        // bodyでは画像BLOBを読まず、object URIと画像revisionだけを確定する。
        let imageRequest = makeImageRequest()

        Group {
            if imageRequest != nil,
               let image = displayImage(for: imageRequest?.identifier) {
                let displaySize = CardThumbnailService.displaySize(
                    for: image.size,
                    containerSide: size
                )
                Image(uiImage: image)
                    .resizable()
                    .frame(width: displaySize.width, height: displaySize.height)
                    .accessibilityHidden(true)
            } else if let imageRequest,
                      failedImageIdentifier == imageRequest.identifier {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            } else if let imageRequest,
                      missingImageIdentifier == imageRequest.identifier {
                CardAvatarView(
                    initials: item.detail.initials,
                    company: item.row.company,
                    size: size
                )
            } else if imageRequest != nil {
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
                CardAvatarView(
                    initials: item.detail.initials,
                    company: item.row.company,
                    size: size
                )
            }
        }
        .frame(width: size, height: size, alignment: .center)
        .task(id: imageRequest?.identifier) {
            guard let imageRequest else { return }
            let cacheIdentifier = imageRequest.identifier
            // 詳細から戻って同じtaskが再開しても、表示中のキャッシュ画像を消さない。
            if decodedImage != nil, decodedImageIdentifier == cacheIdentifier { return }
            failedImageIdentifier = nil
            missingImageIdentifier = nil
            let result = await CardImageDecodingService.shared.storedImage(
                objectURI: imageRequest.objectURI,
                coordinatorReference: imageRequest.coordinatorReference,
                maximumPixelSize: size * 3,
                cacheIdentifier: cacheIdentifier
            )
            guard !Task.isCancelled else { return }
            switch result {
            case .image(let decoded):
                decodedImage = decoded.image
                decodedImageIdentifier = cacheIdentifier
            case .missing:
                decodedImage = nil
                decodedImageIdentifier = nil
                missingImageIdentifier = cacheIdentifier
            case .invalid:
                failedImageIdentifier = cacheIdentifier
            }
        }
    }

    private func makeImageRequest() -> CardThumbnailImageRequest? {
        guard let coordinator = viewContext.persistentStoreCoordinator else { return nil }
        return CardThumbnailImageRequest(
            objectURI: item.id,
            coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator),
            identifier: item.imageIdentifier
        )
    }

    private func displayImage(for cacheIdentifier: String?) -> UIImage? {
        guard let cacheIdentifier else { return nil }
        if decodedImageIdentifier == cacheIdentifier, let decodedImage {
            return decodedImage
        }
        if let cached = CardImageDecodingService.shared.cachedImage(
            maximumPixelSize: size * 3,
            cacheIdentifier: cacheIdentifier
        )?.image {
            return cached
        }
        // refresh中は直前の画像を維持し、カードだけが一瞬placeholderへ戻るのを防ぐ。
        return decodedImage
    }
}

/// 1回のView評価で確定した画像入力。Dataと識別子の組をtask完了まで一致させる。
private struct CardThumbnailImageRequest {
    let objectURI: URL
    let coordinatorReference: PersistentStoreCoordinatorReference
    let identifier: String
}
