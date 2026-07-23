import SwiftUI
import UIKit

/// iPhoneの標準Tab Barと同じUIKit階層に、独立した標準Glass追加ボタンを配置する。
/// Tabの選択肢へ追加せず、Tab Barの透明な全幅hit領域に入力を奪われないようにする。
struct SystemTabBarAddButtonHost: UIViewRepresentable {
    let isVisible: Bool
    let action: @MainActor () -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.update(isVisible: isVisible, action: action)
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.update(isVisible: isVisible, action: action)
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: Void) {
        uiView.detach()
    }

    @MainActor
    final class ProbeView: UIView {
        private weak var installedTabBar: UITabBar?
        private var overlayContainer: TabBarOverlayContainer?
        private var deferredInstallationTask: Task<Void, Never>?
        private var isButtonVisible = false
        private var buttonAction: (@MainActor () -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleInstallation()
        }

        func update(isVisible: Bool, action: @escaping @MainActor () -> Void) {
            isButtonVisible = isVisible
            buttonAction = action
            overlayContainer?.button.isHidden = !isVisible
            overlayContainer?.setNeedsLayout()
            scheduleInstallation()
        }

        func detach() {
            deferredInstallationTask?.cancel()
            deferredInstallationTask = nil
            overlayContainer?.removeFromSuperview()
            overlayContainer = nil
            installedTabBar = nil
        }

        private func scheduleInstallation() {
            deferredInstallationTask?.cancel()
            deferredInstallationTask = Task { @MainActor [weak self] in
                for _ in 0..<12 {
                    guard !Task.isCancelled, let self else { return }
                    if installIfPossible() { return }
                    await Task.yield()
                }
            }
        }

        @discardableResult
        private func installIfPossible() -> Bool {
            guard let window,
                  let tabBar = findTabBar(in: window) else { return false }

            if installedTabBar !== tabBar || overlayContainer?.superview !== tabBar {
                overlayContainer?.removeFromSuperview()
                let container = TabBarOverlayContainer()
                container.frame = tabBar.bounds
                container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.layoutAction = { [weak self, weak tabBar] container in
                    guard let self, let tabBar else { return }
                    self.layoutButton(in: container, tabBar: tabBar)
                }
                container.button.addAction(UIAction { [weak self] _ in
                    self?.buttonAction?()
                }, for: .touchUpInside)
                tabBar.addSubview(container)
                installedTabBar = tabBar
                overlayContainer = container
            }

            guard let overlayContainer else { return false }
            overlayContainer.button.isHidden = !isButtonVisible
            tabBar.bringSubviewToFront(overlayContainer)
            overlayContainer.setNeedsLayout()
            overlayContainer.layoutIfNeeded()
            return true
        }

        private func layoutButton(in container: TabBarOverlayContainer, tabBar: UITabBar) {
            guard let referenceButton = findReferenceTabButton(in: tabBar) else { return }
            let itemFrame = referenceButton.convert(referenceButton.bounds, to: container)
            let visualFrame = visualTabContainerFrame(
                startingAt: referenceButton,
                tabBar: tabBar,
                container: container
            )
            let side = min(max(visualFrame.height, itemFrame.height, 44), 72)
            container.button.frame = CGRect(
                x: container.bounds.maxX - AppTheme.Spacing.large - side,
                y: visualFrame.maxY - side,
                width: side,
                height: side
            ).integral
            container.button.layer.cornerRadius = side / 2
        }

        private func visualTabContainerFrame(
            startingAt referenceButton: UIView,
            tabBar: UITabBar,
            container: UIView
        ) -> CGRect {
            var candidate = referenceButton.convert(referenceButton.bounds, to: container)
            var ancestor = referenceButton.superview
            while let current = ancestor, current !== tabBar {
                let frame = current.convert(current.bounds, to: container)
                if frame.height >= candidate.height,
                   frame.height <= 72,
                   frame.width < tabBar.bounds.width * 0.85 {
                    candidate = frame
                }
                ancestor = current.superview
            }
            return candidate
        }

        private func findTabBar(in view: UIView) -> UITabBar? {
            if let tabBar = view as? UITabBar { return tabBar }
            for child in view.subviews {
                if let tabBar = findTabBar(in: child) { return tabBar }
            }
            return nil
        }

        private func findReferenceTabButton(in view: UIView) -> UIView? {
            let identifiers: Set<String> = ["cardsRootTab", "insightsRootTab"]
            let labels: Set<String> = ["名刺", "インサイト"]
            if view.accessibilityIdentifier.map(identifiers.contains) == true
                || view.accessibilityLabel.map(labels.contains) == true {
                return view
            }
            for child in view.subviews where child !== overlayContainer {
                if let match = findReferenceTabButton(in: child) { return match }
            }
            return nil
        }
    }

    @MainActor
    final class TabBarOverlayContainer: UIView {
        let button: UIButton = {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.prominentGlass()
            configuration.image = UIImage(systemName: "plus")
            configuration.baseBackgroundColor = UIColor(named: "AccentColor")
            configuration.baseForegroundColor = .white
            configuration.cornerStyle = .capsule
            button.configuration = configuration
            button.accessibilityLabel = "名刺を追加"
            button.accessibilityIdentifier = "cardAddButton"
            return button
        }()

        var layoutAction: ((TabBarOverlayContainer) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            addSubview(button)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutAction?(self)
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard !button.isHidden else { return false }
            return button.frame.insetBy(dx: -4, dy: -4).contains(point)
        }
    }
}
