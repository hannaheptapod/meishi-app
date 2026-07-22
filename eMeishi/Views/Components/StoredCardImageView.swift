import CoreData
import SwiftUI
import UIKit

/// Core Dataの画像BLOBをView評価中に読み込まず、背景contextから取得するための入力。
struct StoredCardImageRequest {
    let objectURI: URL
    let coordinatorReference: PersistentStoreCoordinatorReference
    let identifier: String

    static func businessCard(
        objectURI: URL,
        imageIdentifier: String,
        coordinator: NSPersistentStoreCoordinator?
    ) -> StoredCardImageRequest? {
        guard let coordinator else { return nil }
        return StoredCardImageRequest(
            objectURI: objectURI,
            coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator),
            identifier: imageIdentifier
        )
    }
}

enum StoredCardImageViewState {
    case loading
    case image(UIImage)
    case missing
    case invalid
}

/// 詳細・ピーク・全画面で共用する保存済み画像ローダー。
/// キャッシュヒットは同期的に返し、画像BLOBのfaultとデコードだけをactorへ移す。
struct StoredCardImageLoader<Content: View>: View {
    let request: StoredCardImageRequest?
    let maximumPixelSize: CGFloat
    var fallbackMaximumPixelSizes: [CGFloat] = []
    @ViewBuilder let content: (StoredCardImageViewState) -> Content

    @State private var loadedImage: UIImage?
    @State private var loadedIdentifier: String?
    @State private var missingIdentifier: String?
    @State private var invalidIdentifier: String?

    var body: some View {
        content(displayState)
            .task(id: request?.identifier) {
                guard let request else { return }
                if loadedIdentifier == request.identifier, loadedImage != nil { return }

                missingIdentifier = nil
                invalidIdentifier = nil
                let result = await CardImageDecodingService.shared.storedImage(
                    objectURI: request.objectURI,
                    coordinatorReference: request.coordinatorReference,
                    maximumPixelSize: maximumPixelSize,
                    cacheIdentifier: request.identifier
                )
                guard !Task.isCancelled else { return }

                switch result {
                case .image(let decoded):
                    loadedImage = decoded.image
                    loadedIdentifier = request.identifier
                case .missing:
                    loadedImage = nil
                    loadedIdentifier = nil
                    missingIdentifier = request.identifier
                case .invalid:
                    loadedImage = nil
                    loadedIdentifier = nil
                    invalidIdentifier = request.identifier
                }
            }
    }

    private var displayState: StoredCardImageViewState {
        guard let request else { return .missing }
        if loadedIdentifier == request.identifier, let loadedImage {
            return .image(loadedImage)
        }
        if let cached = cachedImage(for: request) {
            return .image(cached)
        }
        if missingIdentifier == request.identifier {
            return .missing
        }
        if invalidIdentifier == request.identifier {
            return .invalid
        }
        return .loading
    }

    private func cachedImage(for request: StoredCardImageRequest) -> UIImage? {
        let sizes = [maximumPixelSize] + fallbackMaximumPixelSizes
        for pixelSize in sizes {
            if let image = CardImageDecodingService.shared.cachedImage(
                maximumPixelSize: pixelSize,
                cacheIdentifier: request.identifier
            )?.image {
                return image
            }
        }
        return nil
    }
}

/// 保存済み名刺画像を表示する共通ヒーロー。画像がある場合だけタップ操作を有効にする。
struct StoredCardImageHero: View {
    let request: StoredCardImageRequest?
    let initials: String
    var maximumHeight: CGFloat = 320
    var showsExpansionIndicator = false
    var onTap: (() -> Void)?

    var body: some View {
        StoredCardImageLoader(
            request: request,
            maximumPixelSize: maximumHeight * 3
        ) { state in
            switch state {
            case .image(let image):
                interactiveImage(image)
            case .missing:
                initialsPlaceholder
            case .invalid:
                invalidPlaceholder
            case .loading:
                loadingPlaceholder
            }
        }
    }

    @ViewBuilder
    private func interactiveImage(_ image: UIImage) -> some View {
        if let onTap {
            Button(action: onTap) {
                imageContent(image)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("名刺画像を全画面表示")
        } else {
            imageContent(image)
        }
    }

    private func imageContent(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: maximumHeight)
            .clipShape(.rect(cornerRadius: AppTheme.imageCornerRadius, style: .continuous))
            .contentShape(Rectangle())
            .overlay(alignment: .bottomTrailing) {
                if showsExpansionIndicator, onTap != nil {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.semibold))
                        .padding(9)
                        .glassEffect(.regular, in: .circle)
                        .padding(8)
                        .accessibilityHidden(true)
                }
            }
    }

    private var initialsPlaceholder: some View {
        Text(initials.isEmpty ? "名刺" : initials)
            .font(.largeTitle.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 180)
            .background(AppTheme.auxiliarySurface)
            .clipShape(.rect(cornerRadius: AppTheme.imageCornerRadius, style: .continuous))
            .accessibilityLabel("名刺画像なし")
    }

    private var invalidPlaceholder: some View {
        ContentUnavailableView(
            "画像を表示できません",
            systemImage: "photo.badge.exclamationmark"
        )
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(AppTheme.auxiliarySurface)
        .clipShape(.rect(cornerRadius: AppTheme.imageCornerRadius, style: .continuous))
    }

    private var loadingPlaceholder: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: AppTheme.imageCornerRadius,
                style: .continuous
            )
            .fill(AppTheme.auxiliarySurface)
            ProgressView()
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .accessibilityLabel("名刺画像を読み込み中")
    }
}
