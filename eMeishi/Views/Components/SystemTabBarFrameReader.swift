import SwiftUI
import UIKit

/// SwiftUIが公開していない標準Tab Bar項目の実表示座標を、
/// システムのアクセシビリティframeまたは表示階層のframeから取得する。
struct SystemTabBarFrameReader: UIViewRepresentable {
    @Binding var itemFrame: CGRect

    func makeCoordinator() -> Coordinator {
        Coordinator(itemFrame: $itemFrame)
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onFrameChange = { frame in
            context.coordinator.update(frame)
        }
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        context.coordinator.itemFrame = $itemFrame
        uiView.reportFrame()
    }

    @MainActor
    final class Coordinator {
        var itemFrame: Binding<CGRect>

        init(itemFrame: Binding<CGRect>) {
            self.itemFrame = itemFrame
        }

        func update(_ frame: CGRect) {
            guard !frame.isEmpty, frame != itemFrame.wrappedValue else { return }
            Task { @MainActor [weak self] in
                guard let self, frame != itemFrame.wrappedValue else { return }
                itemFrame.wrappedValue = frame
            }
        }
    }

    @MainActor
    final class ProbeView: UIView {
        var onFrameChange: ((CGRect) -> Void)?

        private let tabTitles: Set<String> = ["名刺", "インサイト"]

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportFrame()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportFrame()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            reportFrame()
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            reportFrame()
        }

        func reportFrame() {
            guard let window else { return }

            var frames: [CGRect] = []
            collectTabFrames(in: window, window: window, frames: &frames)
            if let firstFrame = frames.first {
                onFrameChange?(frames.dropFirst().reduce(firstFrame) { $0.union($1) })
                return
            }

            var capsuleFrames: [CGRect] = []
            collectBottomCapsuleFrames(in: window, window: window, frames: &capsuleFrames)
            guard let frame = capsuleFrames.max(by: { lhs, rhs in
                if lhs.midY == rhs.midY { return lhs.width < rhs.width }
                return lhs.midY < rhs.midY
            }) else {
                // 子画面でTab Barが隠れても最後の有効座標は保持する。
                // ルートへ戻った際に再探索を待たず、ルート画面と同時に追加ボタンを復元するため。
                return
            }
            onFrameChange?(frame)
        }

        private func collectTabFrames(
            in view: UIView,
            window: UIWindow,
            frames: inout [CGRect]
        ) {
            guard !view.isHidden, view.alpha > 0.01 else { return }

            if let label = view.accessibilityLabel,
               tabTitles.contains(label) {
                let frame = view.convert(view.bounds, to: window)
                if isBottomControl(frame, in: window) {
                    frames.append(frame)
                }
            }

            if let elements = view.accessibilityElements {
                for element in elements {
                    if let childView = element as? UIView {
                        collectTabFrames(in: childView, window: window, frames: &frames)
                    } else if let accessibilityElement = element as? UIAccessibilityElement,
                              let label = accessibilityElement.accessibilityLabel,
                              tabTitles.contains(label) {
                        let frame = accessibilityElement.accessibilityFrame
                        if isBottomControl(frame, in: window) {
                            frames.append(frame)
                        }
                    }
                }
            }

            for child in view.subviews {
                collectTabFrames(in: child, window: window, frames: &frames)
            }
        }

        private func isBottomControl(_ frame: CGRect, in window: UIWindow) -> Bool {
            !frame.isEmpty && frame.midY > window.bounds.height * 0.65
        }

        private func collectBottomCapsuleFrames(
            in view: UIView,
            window: UIWindow,
            frames: inout [CGRect]
        ) {
            guard !view.isHidden, view.alpha > 0.01 else { return }

            if view !== window {
                let frame = view.convert(view.bounds, to: window)
                let isBottom = frame.midY > window.bounds.height * 0.65
                let hasCapsuleSize = (44...90).contains(frame.height)
                    && frame.width > frame.height * 2
                    && frame.width < window.bounds.width * 0.8
                if isBottom, hasCapsuleSize {
                    frames.append(frame)
                }
            }

            for child in view.subviews {
                collectBottomCapsuleFrames(in: child, window: window, frames: &frames)
            }
        }
    }
}
