import SwiftUI
import UIKit

// MARK: - 名刺画像の全画面表示

struct FullScreenCardImageView: View {
    let image: UIImage
    let onDismiss: () -> Void
    @State private var zoomScale: CGFloat = 1
    @State private var dismissOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            ZoomableCardImageScrollView(
                image: image,
                onZoomScaleChange: { zoomScale = $0 }
            )
                .ignoresSafeArea()
                .offset(y: dismissOffset)
                .scaleEffect(dismissScale)
                .accessibilityLabel("名刺画像")
                .accessibilityHint("ピンチまたはダブルタップで拡大。等倍では下へスワイプして閉じられます")
                .accessibilityIdentifier("fullScreenCardImage")

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
            .offset(y: dismissOffset)
        }
        .simultaneousGesture(dismissGesture)
        .statusBarHidden()
    }

    private var dismissProgress: CGFloat {
        min(max(dismissOffset / 320, 0), 1)
    }

    private var backgroundOpacity: Double {
        1 - Double(dismissProgress) * 0.55
    }

    private var dismissScale: CGFloat {
        reduceMotion ? 1 : 1 - dismissProgress * 0.08
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard zoomScale <= 1.01,
                      value.translation.height > 0,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                dismissOffset = value.translation.height
            }
            .onEnded { value in
                guard zoomScale <= 1.01 else {
                    resetDismissOffset()
                    return
                }
                let shouldDismiss = dismissOffset > 120
                    || value.predictedEndTranslation.height > 220
                if shouldDismiss {
                    onDismiss()
                } else {
                    resetDismissOffset()
                }
            }
    }

    private func resetDismissOffset() {
        if reduceMotion {
            dismissOffset = 0
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                dismissOffset = 0
            }
        }
    }
}

/// UIScrollView標準のズームとパンを使い、ピンチ中心と慣性を自然に保つ。
struct ZoomableCardImageScrollView: UIViewRepresentable {
    let image: UIImage
    let onZoomScaleChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onZoomScaleChange: onZoomScaleChange)
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

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        context.coordinator.onZoomScaleChange = onZoomScaleChange
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var onZoomScaleChange: (CGFloat) -> Void

        init(onZoomScaleChange: @escaping (CGFloat) -> Void) {
            self.onZoomScaleChange = onZoomScaleChange
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            onZoomScaleChange(scrollView.zoomScale)
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
    }
}
