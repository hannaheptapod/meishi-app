import SwiftUI
import UIKit

// MARK: - 名刺画像の全画面表示

struct FullScreenCardImageView: View {
    let request: StoredCardImageRequest
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            StoredCardImageLoader(
                request: request,
                maximumPixelSize: 4_096,
                fallbackMaximumPixelSizes: [1_260]
            ) { state in
                switch state {
                case .image(let image):
                    ZoomableCardImageScrollView(
                        image: image,
                        onDismiss: onDismiss
                    )
                    .ignoresSafeArea()
                    .accessibilityLabel("名刺画像")
                    .accessibilityHint("ピンチまたはダブルタップで拡大できます")
                    .accessibilityIdentifier("fullScreenCardImage")
                case .missing:
                    ContentUnavailableView(
                        "名刺画像がありません",
                        systemImage: "photo"
                    )
                    .foregroundStyle(.white)
                case .invalid:
                    ContentUnavailableView(
                        "名刺画像を表示できません",
                        systemImage: "photo.badge.exclamationmark"
                    )
                    .foregroundStyle(.white)
                case .loading:
                    ProgressView()
                        .tint(.white)
                        .accessibilityLabel("名刺画像を読み込み中")
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("閉じる")
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Spacer()
            }
        }
        .statusBarHidden()
    }
}

/// UIScrollView標準のズームとパンを使い、ピンチ中心と慣性を自然に保つ。
struct ZoomableCardImageScrollView: UIViewRepresentable {
    let image: UIImage
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "名刺画像"
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        // 等倍表示中だけ下スワイプで閉じる。拡大中はUIScrollViewの
        // 標準パンを優先し、画像内の移動とdismissを競合させない。
        let swipeDown = UISwipeGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSwipeDown(_:))
        )
        swipeDown.direction = .down
        swipeDown.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(swipeDown)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        context.coordinator.onDismiss = onDismiss
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView,
                  let imageView else { return }

            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let targetScale = min(2.5, scrollView.maximumZoomScale)
            let point = recognizer.location(in: imageView)
            let targetSize = CGSize(
                width: scrollView.bounds.width / targetScale,
                height: scrollView.bounds.height / targetScale
            )
            let targetRect = CGRect(
                x: point.x - targetSize.width / 2,
                y: point.y - targetSize.height / 2,
                width: targetSize.width,
                height: targetSize.height
            )
            scrollView.zoom(to: targetRect, animated: true)
        }

        @objc func handleSwipeDown(_ recognizer: UISwipeGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView,
                  scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else {
                return
            }
            onDismiss()
        }
    }
}
