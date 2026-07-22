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
            itemFrame.wrappedValue = frame
        }
    }

    @MainActor
    final class ProbeView: UIView {
        var onFrameChange: ((CGRect) -> Void)?
        private let tabTitles: Set<String> = ["名刺", "インサイト"]
        private let tabIdentifiers: Set<String> = ["cardsRootTab", "insightsRootTab"]
        private var deferredReportTask: Task<Void, Never>?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportFrame()
            scheduleDeferredReports()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportFrame()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            reportFrame()
            scheduleDeferredReports()
        }

        deinit {
            deferredReportTask?.cancel()
        }

        @discardableResult
        func reportFrame() -> Bool {
            guard let window else { return false }

            var frames: [CGRect] = []
            for candidateWindow in window.windowScene?.windows ?? [window] {
                collectTabFrames(in: candidateWindow, window: candidateWindow, frames: &frames)
            }
            if let firstFrame = frames.first {
                onFrameChange?(frames.dropFirst().reduce(firstFrame) { $0.union($1) })
                return true
            }
            return false
        }

        private func scheduleDeferredReports() {
            deferredReportTask?.cancel()
            deferredReportTask = Task { @MainActor [weak self] in
                for _ in 0..<8 {
                    guard !Task.isCancelled else { return }
                    await Task.yield()
                    guard let self else { return }
                    if reportFrame() { return }
                }
            }
        }

        private func collectTabFrames(
            in view: UIView,
            window: UIWindow,
            frames: inout [CGRect]
        ) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            let className = String(describing: type(of: view))
            let isTabBarButton = className.localizedCaseInsensitiveContains("TabBarButton")
            if isTabBarButton
                || view.accessibilityLabel.map(tabTitles.contains) == true
                || view.accessibilityIdentifier.map(tabIdentifiers.contains) == true {
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
                              accessibilityElement.accessibilityLabel.map(tabTitles.contains) == true
                                || accessibilityElement.accessibilityIdentifier.map(tabIdentifiers.contains) == true {
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

    }
}
