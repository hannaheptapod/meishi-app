import SwiftUI
import UIKit

/// presentation階層のうち、監視開始時点から新しく積まれた層だけを識別する。
///
/// 親sheetなど、監視開始前から存在するpresentationはbaselineとして保持する。
/// これによりsheet内のAlertを監視するときに、親sheetのdismissを待つ誤動作を防ぐ。
nonisolated struct PresentationPathTracker<LayerID: Hashable & Sendable>: Sendable {
    private(set) var baseline: [LayerID] = []
    private(set) var trackedLayer: LayerID?
    private(set) var hasBaseline = false

    mutating func begin(scopePrefix: [LayerID], currentPath: [LayerID]) {
        baseline = scopePrefix
        trackedLayer = nil
        hasBaseline = true
        _ = observe(currentPath)
    }

    @discardableResult
    mutating func observe(_ path: [LayerID]) -> LayerID? {
        guard hasBaseline else { return nil }
        guard trackedLayer == nil else { return trackedLayer }
        guard path.starts(with: baseline), path.count > baseline.count else { return nil }

        let newLayer = path[baseline.count]
        trackedLayer = newLayer
        return newLayer
    }

    func isDismissalComplete(in path: [LayerID]) -> Bool {
        guard hasBaseline else { return false }
        if let trackedLayer {
            return !path.contains(trackedLayer)
        }
        return path == baseline
    }

    mutating func reset() {
        baseline = []
        trackedLayer = nil
        hasBaseline = false
    }
}

/// SwiftUIが`onDismiss`を提供しないAlert/confirmationDialogについて、
/// UIKitの提示ViewControllerが実際に画面階層から外れた時点を通知する。
///
/// 固定秒数やMainActorの1ターンをdismiss animation完了の代用にせず、
/// 次のpresentationを開始できる実ライフサイクル境界を作る。
struct PresentationDismissalObserver<ID: Hashable>: UIViewControllerRepresentable {
    let activeID: ID?
    let dismissingID: ID?
    let onDismissalCompleted: (ID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismissalCompleted: onDismissalCompleted)
    }

    func makeUIViewController(context: Context) -> ProbeViewController {
        let controller = ProbeViewController()
        context.coordinator.host = controller
        return controller
    }

    func updateUIViewController(_ controller: ProbeViewController, context: Context) {
        context.coordinator.host = controller
        context.coordinator.onDismissalCompleted = onDismissalCompleted
        context.coordinator.update(activeID: activeID, dismissingID: dismissingID)
    }

    static func dismantleUIViewController(
        _ controller: ProbeViewController,
        coordinator: Coordinator
    ) {
        coordinator.stopObserving()
    }

    final class ProbeViewController: UIViewController {
        override func loadView() {
            let view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            self.view = view
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var host: UIViewController?
        weak var trackedPresentation: UIViewController?
        var onDismissalCompleted: (ID) -> Void

        private var activeID: ID?
        private var dismissingID: ID?
        private var displayLink: CADisplayLink?
        private var pathTracker = PresentationPathTracker<ObjectIdentifier>()

        private struct ScopedPresentationSnapshot {
            let controllers: [UIViewController]
            let path: [ObjectIdentifier]
            let scopePrefix: [ObjectIdentifier]
        }

        init(onDismissalCompleted: @escaping (ID) -> Void) {
            self.onDismissalCompleted = onDismissalCompleted
        }

        func update(activeID: ID?, dismissingID: ID?) {
            if self.activeID != activeID {
                self.activeID = activeID
                if activeID != nil {
                    trackedPresentation = nil
                    pathTracker.reset()
                    establishScopeAndTrackIfPossible()
                } else if dismissingID == nil {
                    resetTracking()
                }
            }
            self.dismissingID = dismissingID

            if activeID != nil || dismissingID != nil {
                startObserving()
            } else {
                stopObserving()
            }
        }

        func stopObserving() {
            displayLink?.invalidate()
            displayLink = nil
        }

        private func resetTracking() {
            trackedPresentation = nil
            pathTracker.reset()
        }

        private func startObserving() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(observePresentationFrame))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func observePresentationFrame() {
            guard let snapshot = scopedPresentationSnapshot() else { return }
            let currentPath = snapshot.path

            if !pathTracker.hasBaseline {
                pathTracker.begin(
                    scopePrefix: snapshot.scopePrefix,
                    currentPath: currentPath
                )
            }

            if trackedPresentation == nil,
               let trackedLayer = pathTracker.observe(currentPath) {
                trackedPresentation = snapshot.controllers.first {
                    ObjectIdentifier($0) == trackedLayer
                }
            }

            if dismissingID == nil {
                if trackedPresentation != nil {
                    stopObserving()
                }
                return
            }

            guard let completedID = dismissingID else { return }

            if let trackedPresentation {
                let trackedID = ObjectIdentifier(trackedPresentation)
                let isDetached = !currentPath.contains(trackedID)
                    && trackedPresentation.viewIfLoaded?.window == nil
                    && !trackedPresentation.isBeingPresented
                guard isDetached else { return }
            } else {
                // 対象の提示を捕捉する前にdismissへ遷移した場合も、baselineより上だけを見る。
                // 親sheetが残っていても、baselineへ戻っていれば対象presentationは完了している。
                guard pathTracker.isDismissalComplete(in: currentPath) else { return }
            }

            self.dismissingID = nil
            self.activeID = nil
            resetTracking()
            stopObserving()
            onDismissalCompleted(completedID)
        }

        private func establishScopeAndTrackIfPossible() {
            guard let snapshot = scopedPresentationSnapshot() else { return }
            pathTracker.begin(
                scopePrefix: snapshot.scopePrefix,
                currentPath: snapshot.path
            )
            guard let trackedLayer = pathTracker.trackedLayer else { return }
            trackedPresentation = snapshot.controllers.first {
                ObjectIdentifier($0) == trackedLayer
            }
        }

        /// 時刻依存の「現在の最上位」をbaselineにせず、probeを内包する
        /// ViewControllerまでを構造上のscopeとして確定する。Alertやcontext menuが
        /// 既に表示済みでも、それらはscopeより上の追跡対象になる。
        private func scopedPresentationSnapshot() -> ScopedPresentationSnapshot? {
            guard let host,
                  var current = host.viewIfLoaded?.window?.rootViewController else { return nil }
            var controllers = [current]
            while let presented = current.presentedViewController {
                current = presented
                controllers.append(current)
            }

            guard let scopeIndex = controllers.lastIndex(where: {
                controller($0, contains: host)
            }) else { return nil }

            let path = controllers.map(ObjectIdentifier.init)
            let scopePrefix = Array(path.prefix(scopeIndex + 1))
            return ScopedPresentationSnapshot(
                controllers: controllers,
                path: path,
                scopePrefix: scopePrefix
            )
        }

        private func controller(
            _ candidate: UIViewController,
            contains descendant: UIViewController
        ) -> Bool {
            var current: UIViewController? = descendant
            while let controller = current {
                if controller === candidate { return true }
                current = controller.parent
            }

            guard let descendantView = descendant.viewIfLoaded,
                  let candidateView = candidate.viewIfLoaded else { return false }
            return descendantView === candidateView
                || descendantView.isDescendant(of: candidateView)
        }
    }
}
