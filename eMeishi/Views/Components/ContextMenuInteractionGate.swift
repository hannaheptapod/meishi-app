import Combine
import Foundation
import SwiftUI
import UIKit

/// SwiftUI のコンテキストメニュー表示中から、UIKit のdismiss完了まで
/// 背面コンテンツへの入力と次のpresentationを遮断する。
///
/// preview の `onDisappear` はdismiss animationの開始時に呼ばれるため、そこで解除しない。
/// previewを所有するViewControllerのtransition完了を確認し、
/// `dismissalDidComplete(sessionID:)` を呼んだ時だけ遮断を解除する。
@MainActor
final class ContextMenuInteractionGate<DeferredAction: Sendable>: ObservableObject {
    @Published private(set) var blocksCardInteraction = false
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var dismissingSessionID: UUID?

    private var deferredAction: DeferredAction?

    @discardableResult
    func previewDidAppear() -> UUID {
        // 同じpreviewが再評価されてもセッションを作り直さない。
        if let activeSessionID {
            return activeSessionID
        }
        if let dismissingSessionID {
            return dismissingSessionID
        }

        let sessionID = UUID()
        activeSessionID = sessionID
        blocksCardInteraction = true
        return sessionID
    }

    func previewDidDisappear(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        self.activeSessionID = nil
        dismissingSessionID = sessionID
    }

    /// interactive transitionが取り消された場合は、同じpreviewセッションへ戻す。
    /// 古いtransitionのcancel通知で新しいセッションを復元しない。
    func dismissalWasCancelled(sessionID: UUID) {
        guard dismissingSessionID == sessionID else { return }
        dismissingSessionID = nil
        activeSessionID = sessionID
        blocksCardInteraction = true
    }

    /// メニュー項目からsheet/dialog等を開く操作を、メニューdismiss完了まで保留する。
    /// メニュー外から呼ばれた場合は、その場で実行できる値を返す。
    func deferUntilDismissal(_ action: DeferredAction) -> DeferredAction? {
        guard blocksCardInteraction else { return action }
        deferredAction = action
        return nil
    }

    /// UIKit presentationの実dismiss完了が現在のセッションと一致する場合だけ解除する。
    /// 古いセッションの遅延callbackでは、新しいメニューや保留操作を変更しない。
    func dismissalDidComplete(sessionID: UUID) -> DeferredAction? {
        guard dismissingSessionID == sessionID else { return nil }
        dismissingSessionID = nil
        blocksCardInteraction = false
        defer { deferredAction = nil }
        return deferredAction
    }

    /// 画面階層そのものが破棄された場合の最終退避です。
    /// 通常のdismissでは`dismissalDidComplete(sessionID:)`を使い、保留操作を実行します。
    /// このメソッドは、別タブへの切替などで操作対象が消えた場合だけ呼びます。
    func reset() {
        activeSessionID = nil
        dismissingSessionID = nil
        deferredAction = nil
        blocksCardInteraction = false
    }
}

/// SwiftUIのcontext menu previewを所有するUIViewControllerのtransition完了を通知する。
///
/// `.contextMenu`のメニューと操作はSwiftUIへ残し、dismiss境界だけをUIKitの
/// transition coordinatorへ結び付ける。root view controllerのpresentationチェーンを
/// 推測しないため、context menuが別window/overlayで表示されても誤って早期解除しない。
@MainActor
struct ContextMenuPreviewLifecycleObserver: UIViewControllerRepresentable {
    let onPreviewPresented: () -> UUID
    let onDismissalBegan: (UUID) -> Void
    let onDismissalCompleted: (UUID) -> Void
    let onDismissalCancelled: (UUID) -> Void

    static func dismantleUIViewController(
        _ uiViewController: ContextMenuPreviewLifecycleViewController,
        coordinator: ()
    ) {
        uiViewController.representableWasDismantled()
    }

    func makeUIViewController(context: Context) -> ContextMenuPreviewLifecycleViewController {
        let controller = ContextMenuPreviewLifecycleViewController()
        update(controller)
        return controller
    }

    func updateUIViewController(
        _ uiViewController: ContextMenuPreviewLifecycleViewController,
        context: Context
    ) {
        update(uiViewController)
    }

    private func update(_ controller: ContextMenuPreviewLifecycleViewController) {
        controller.onPreviewPresented = onPreviewPresented
        controller.onDismissalBegan = onDismissalBegan
        controller.onDismissalCompleted = onDismissalCompleted
        controller.onDismissalCancelled = onDismissalCancelled
    }
}

@MainActor
final class ContextMenuPreviewLifecycleViewController: UIViewController {
    var onPreviewPresented: (() -> UUID)?
    var onDismissalBegan: ((UUID) -> Void)?
    var onDismissalCompleted: ((UUID) -> Void)?
    var onDismissalCancelled: ((UUID) -> Void)?

    private var sessionID: UUID?
    private var hasScheduledTransitionCompletion = false
    private var hasCompletedDismissal = false

    override func loadView() {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        self.view = view
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasScheduledTransitionCompletion = false
        hasCompletedDismissal = false
        if sessionID == nil {
            sessionID = onPreviewPresented?()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard let sessionID, !hasCompletedDismissal else { return }
        onDismissalBegan?(sessionID)

        guard let transitionCoordinator else {
            hasScheduledTransitionCompletion = false
            return
        }

        let onDismissalCompleted = self.onDismissalCompleted
        let onDismissalCancelled = self.onDismissalCancelled
        hasScheduledTransitionCompletion = transitionCoordinator.animate(
            alongsideTransition: nil
        ) { context in
            if context.isCancelled {
                onDismissalCancelled?(sessionID)
            } else {
                onDismissalCompleted?(sessionID)
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !hasScheduledTransitionCompletion,
              !hasCompletedDismissal,
              let sessionID else { return }
        hasCompletedDismissal = true
        onDismissalCompleted?(sessionID)
    }

    /// SwiftUIがpreviewを階層から直接取り除いた場合も、入力遮断を残留させません。
    /// transition coordinatorへ完了通知を登録済みなら、その通知を優先します。
    func representableWasDismantled() {
        guard !hasScheduledTransitionCompletion,
              !hasCompletedDismissal,
              let sessionID else { return }
        hasCompletedDismissal = true
        onDismissalBegan?(sessionID)
        onDismissalCompleted?(sessionID)
    }
}
