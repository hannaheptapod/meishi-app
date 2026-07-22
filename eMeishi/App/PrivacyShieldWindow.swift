import SwiftUI
import UIKit

/// App Switcher用の遮蔽ウィンドウを表示するかを決める、UIKit非依存の状態。
///
/// アプリが操作可能なforeground activeへ戻った場合だけ遮蔽を外す。
/// inactiveからbackgroundへ遷移する間は表示を維持し、システムが取得する
/// スナップショットへアプリ内容が写る中間状態を作らない。
nonisolated struct PrivacyShieldVisibilityState: Equatable, Sendable {
    enum Activity: Equatable, Sendable {
        case active
        case inactive
        case background
        case unattached
    }

    private(set) var isEnabled: Bool
    private(set) var activity: Activity
    private(set) var isContentReadyToReveal: Bool

    init(
        isEnabled: Bool = false,
        activity: Activity = .unattached,
        isContentReadyToReveal: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.activity = activity
        self.isContentReadyToReveal = isContentReadyToReveal
    }

    var isVisible: Bool {
        isEnabled && (activity != .active || !isContentReadyToReveal)
    }

    mutating func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    mutating func transition(to activity: Activity) {
        self.activity = activity
        if activity != .active {
            isContentReadyToReveal = false
        }
    }

    mutating func setContentReadyToReveal(_ isReady: Bool) {
        isContentReadyToReveal = activity == .active && isReady
    }
}

/// アプリのsystem sheet / fullScreenCover / alertより上で内容を隠すscene専用ウィンドウ。
///
/// key windowにはならず、タッチも受け取らない。既存のAppProtectionOverlayは
/// active復帰後のアプリロック操作を担当し、このウィンドウはinactive中の
/// スナップショット保護だけを担当する。
@MainActor
final class PrivacyShieldWindowController {
    private weak var windowScene: UIWindowScene?
    private var shieldWindow: PrivacyShieldWindow?
    private var observers: [NSObjectProtocol] = []
    private var visibilityState = PrivacyShieldVisibilityState()

    func connect(
        to scene: UIWindowScene,
        isEnabled: Bool,
        isContentReadyToReveal: Bool
    ) {
        if windowScene !== scene {
            disconnect()
            windowScene = scene
            shieldWindow = makeShieldWindow(for: scene)
            observeLifecycle(of: scene)
        }

        visibilityState.setEnabled(isEnabled)
        visibilityState.transition(to: activity(for: scene.activationState))
        visibilityState.setContentReadyToReveal(isContentReadyToReveal)
        applyVisibility()
    }

    func setEnabled(_ isEnabled: Bool) {
        visibilityState.setEnabled(isEnabled)
        applyVisibility()
    }

    func setContentReadyToReveal(_ isReady: Bool) {
        visibilityState.setContentReadyToReveal(isReady)
        applyVisibility()
    }

    func disconnect() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        shieldWindow?.isHidden = true
        shieldWindow?.rootViewController = nil
        shieldWindow = nil
        windowScene = nil
        visibilityState = PrivacyShieldVisibilityState()
    }

    private func makeShieldWindow(for scene: UIWindowScene) -> PrivacyShieldWindow {
        let window = PrivacyShieldWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.isUserInteractionEnabled = false
        window.accessibilityViewIsModal = false
        window.backgroundColor = .systemBackground
        window.rootViewController = UIHostingController(
            rootView: PrivacyOverlayView()
                .accessibilityHidden(true)
        )
        window.isHidden = true
        return window
    }

    private func observeLifecycle(of scene: UIWindowScene) {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: UIScene.willDeactivateNotification,
            object: scene,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.transition(to: .inactive)
            }
        })

        observers.append(center.addObserver(
            forName: UIScene.didEnterBackgroundNotification,
            object: scene,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.transition(to: .background)
            }
        })

        observers.append(center.addObserver(
            forName: UIScene.didActivateNotification,
            object: scene,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.transition(to: .active)
            }
        })
    }

    private func transition(to activity: PrivacyShieldVisibilityState.Activity) {
        visibilityState.transition(to: activity)
        applyVisibility()
    }

    private func applyVisibility() {
        guard let shieldWindow else { return }
        shieldWindow.isHidden = !visibilityState.isVisible
    }

    private func activity(for state: UIScene.ActivationState) -> PrivacyShieldVisibilityState.Activity {
        switch state {
        case .foregroundActive:
            .active
        case .foregroundInactive:
            .inactive
        case .background:
            .background
        case .unattached:
            .unattached
        @unknown default:
            .unattached
        }
    }
}

private final class PrivacyShieldWindow: UIWindow {
    /// 遮蔽表示によってアプリ本体やsystem presentationからkey windowを奪わない。
    override var canBecomeKey: Bool { false }
}

private struct PrivacyShieldWindowInstaller: UIViewRepresentable {
    let isEnabled: Bool
    let isContentReadyToReveal: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WindowSceneProbeView {
        let view = WindowSceneProbeView()
        view.isUserInteractionEnabled = false
        view.onWindowSceneChange = { [weak coordinator = context.coordinator] scene in
            coordinator?.connect(to: scene)
        }
        context.coordinator.isEnabled = isEnabled
        context.coordinator.isContentReadyToReveal = isContentReadyToReveal
        return view
    }

    func updateUIView(_ view: WindowSceneProbeView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.isContentReadyToReveal = isContentReadyToReveal
        context.coordinator.connect(to: view.window?.windowScene)
    }

    static func dismantleUIView(_ view: WindowSceneProbeView, coordinator: Coordinator) {
        view.onWindowSceneChange = nil
        coordinator.disconnect()
    }

    @MainActor
    final class Coordinator {
        let windowController = PrivacyShieldWindowController()
        var isEnabled = false {
            didSet {
                windowController.setEnabled(isEnabled)
            }
        }
        var isContentReadyToReveal = false {
            didSet {
                windowController.setContentReadyToReveal(isContentReadyToReveal)
            }
        }

        func connect(to scene: UIWindowScene?) {
            guard let scene else { return }
            windowController.connect(
                to: scene,
                isEnabled: isEnabled,
                isContentReadyToReveal: isContentReadyToReveal
            )
        }

        func disconnect() {
            windowController.disconnect()
        }
    }
}

private final class WindowSceneProbeView: UIView {
    var onWindowSceneChange: ((UIWindowScene) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let windowScene = window?.windowScene else { return }
        onWindowSceneChange?(windowScene)
    }
}

/// SwiftUIの保護レイヤーが実際にwindow内でlayoutされた世代だけを通知する。
/// scenePhaseのactive通知だけでshieldを外すと、LockScreen差込み前の1フレームが露出し得る。
struct PrivacyRevealReadinessProbe: UIViewRepresentable {
    let generation: UUID
    let onRendered: (UUID) -> Void

    func makeUIView(context: Context) -> ReadinessView {
        let view = ReadinessView()
        update(view)
        return view
    }

    func updateUIView(_ view: ReadinessView, context: Context) {
        update(view)
    }

    private func update(_ view: ReadinessView) {
        view.update(generation: generation, onRendered: onRendered)
    }

    final class ReadinessView: UIView {
        private var generation: UUID?
        private var didReport = false
        private var onRendered: ((UUID) -> Void)?

        func update(generation: UUID, onRendered: @escaping (UUID) -> Void) {
            if self.generation != generation {
                self.generation = generation
                didReport = false
            }
            self.onRendered = onRendered
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard !didReport, window != nil, let generation, let onRendered else { return }
            didReport = true
            Task { @MainActor in
                await Task.yield()
                onRendered(generation)
            }
        }
    }
}

extension View {
    /// scene単位の非操作ウィンドウで、system presentationを含む画面全体を遮蔽する。
    func privacyShieldWindow(
        isEnabled: Bool,
        isContentReadyToReveal: Bool
    ) -> some View {
        background {
            PrivacyShieldWindowInstaller(
                isEnabled: isEnabled,
                isContentReadyToReveal: isContentReadyToReveal
            )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
