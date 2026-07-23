import SwiftUI
import UIKit

/// iPhoneの標準Tab Barの右側へ、Tabではない独立した標準Glass Buttonを配置する。
/// ボタン本体をUITabBarの子にすると実機のマスク・クリップ対象になるため、
/// UITabBarController.viewの兄弟として所有する。
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
        private weak var installedRootView: UIView?
        private var layoutProbe: TabBarLayoutProbe?
        private var buttonContainer: RootAddButtonOverlayContainer?
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
            buttonContainer?.button.isHidden = !isVisible
            scheduleInstallation()
        }

        func detach() {
            deferredInstallationTask?.cancel()
            deferredInstallationTask = nil
            layoutProbe?.removeFromSuperview()
            layoutProbe = nil
            buttonContainer?.removeFromSuperview()
            buttonContainer = nil
            installedTabBar = nil
            installedRootView = nil
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
                  let tabBar = findTabBar(in: window),
                  let rootView = owningTabBarController(for: tabBar)?.view else {
                return false
            }

            if installedTabBar !== tabBar
                || installedRootView !== rootView
                || layoutProbe?.superview !== tabBar
                || buttonContainer?.superview !== rootView {
                layoutProbe?.removeFromSuperview()
                buttonContainer?.removeFromSuperview()

                let container = RootAddButtonOverlayContainer()
                container.frame = rootView.bounds
                container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                // UITabBarControllerが選択中コンテンツを再配置しても、その兄弟である
                // 追加操作が背面へ回らないよう同一controller内の描画順を固定する。
                // UIWindowへは載せないため、sheet/fullScreenCoverより前面には出ない。
                container.layer.zPosition = tabBar.layer.zPosition + 1
                container.button.addAction(UIAction { [weak self] _ in
                    self?.buttonAction?()
                }, for: .touchUpInside)
                rootView.addSubview(container)

                let probe = TabBarLayoutProbe()
                probe.frame = tabBar.bounds
                probe.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                probe.layoutAction = { [weak self, weak container, weak tabBar] in
                    guard let self, let container, let tabBar else { return }
                    container.superview?.bringSubviewToFront(container)
                    self.layoutButton(in: container, tabBar: tabBar)
                }
                tabBar.addSubview(probe)

                installedTabBar = tabBar
                installedRootView = rootView
                layoutProbe = probe
                buttonContainer = container
            }

            guard let buttonContainer else { return false }
            buttonContainer.button.isHidden = !isButtonVisible
            rootView.bringSubviewToFront(buttonContainer)
            layoutButton(in: buttonContainer, tabBar: tabBar)
            return true
        }

        private func layoutButton(
            in container: RootAddButtonOverlayContainer,
            tabBar: UITabBar
        ) {
            guard let referenceButton = findReferenceTabButton(in: tabBar) else {
                container.button.isHidden = true
                return
            }

            let itemFrame = referenceButton.convert(referenceButton.bounds, to: container)
            let visualFrame = visualTabContainerFrame(
                startingAt: referenceButton,
                tabBar: tabBar,
                container: container
            )
            guard visualFrame.width > 0, visualFrame.height > 0 else {
                container.button.isHidden = true
                return
            }

            let side = min(max(visualFrame.height, itemFrame.height, 44), 72)
            container.button.frame = CGRect(
                x: container.bounds.maxX
                    - container.safeAreaInsets.right
                    - AppTheme.Spacing.large
                    - side,
                y: visualFrame.midY - side / 2,
                width: side,
                height: side
            ).integral
            container.button.layer.cornerRadius = side / 2
            container.button.isHidden = !isButtonVisible
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

        private func owningTabBarController(for view: UIView) -> UITabBarController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UITabBarController {
                    return controller
                }
                responder = current.next
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
            for child in view.subviews where child !== layoutProbe {
                if let match = findReferenceTabButton(in: child) { return match }
            }

            // 通常起動ではTab itemのAccessibility情報がUIテストより遅く
            // materializeされる場合がある。識別子の生成を配置条件にせず、
            // 公開UIControlの実レイアウトから左端のTab itemを選ぶ。
            guard view === installedTabBar else { return nil }
            return descendantControls(in: view)
                .filter { control in
                    let frame = control.convert(control.bounds, to: view)
                    return !control.isHidden
                        && control.alpha > 0.01
                        && frame.width >= 44
                        && frame.height >= 44
                        && frame.intersects(view.bounds)
                }
                .min { lhs, rhs in
                    lhs.convert(lhs.bounds, to: view).minX
                        < rhs.convert(rhs.bounds, to: view).minX
                }
        }

        private func descendantControls(in view: UIView) -> [UIControl] {
            view.subviews.flatMap { child -> [UIControl] in
                guard child !== layoutProbe else { return [] }
                return (child as? UIControl).map { [$0] } ?? descendantControls(in: child)
            }
        }
    }

    /// Tab Barのレイアウト変更だけを通知する。描画・操作・Accessibilityには参加しない。
    @MainActor
    final class TabBarLayoutProbe: UIView {
        var layoutAction: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutAction?()
        }
    }

    @MainActor
    final class RootAddButtonOverlayContainer: UIView {
        let button: UIButton = {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.prominentGlass()
            configuration.image = UIImage(systemName: "plus")
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                pointSize: 24,
                weight: .semibold
            )
            configuration.baseBackgroundColor = UIColor(named: "AccentColor")
            configuration.baseForegroundColor = .white
            configuration.cornerStyle = .capsule
            button.configuration = configuration
            button.accessibilityLabel = "名刺を追加"
            button.accessibilityIdentifier = "cardAddButton"
            return button
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            addSubview(button)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard !button.isHidden else { return false }
            return button.frame.insetBy(dx: -4, dy: -4).contains(point)
        }
    }
}
