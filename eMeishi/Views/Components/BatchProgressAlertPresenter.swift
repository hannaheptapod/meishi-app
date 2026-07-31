import SwiftUI
import UIKit

/// 写真読み込み・撮影内容準備の進行表示を、システム標準のUIAlertControllerで提示する。
///
/// SwiftUIの`.alert(item:)`はitemをnilへ戻すprogrammatic dismissを
/// 取りこぼすことがある（presentation直後に要求が競合するとアラートが残留する）ため、
/// 進行アラートだけはUIKitのpresent/dismissを直接呼んで確実に取り下げる。
/// 実dismiss完了の検出は従来どおりPresentationDismissalObserverが担う。
struct BatchProgressAlertPresenter: UIViewControllerRepresentable {
    /// 表示するタイトル。nilで取り下げ。表示中のタイトル変更にも追随する
    let title: String?
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> ProbeViewController {
        ProbeViewController()
    }

    func updateUIViewController(_ controller: ProbeViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onCancel = onCancel

        if let title {
            if let alert = coordinator.presentedAlert {
                if alert.title != title {
                    alert.title = title
                }
            } else {
                coordinator.present(title: title, from: controller)
            }
        } else {
            coordinator.dismissIfNeeded()
        }
    }

    static func dismantleUIViewController(
        _ controller: ProbeViewController,
        coordinator: Coordinator
    ) {
        coordinator.dismissIfNeeded()
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
    final class Coordinator {
        private(set) weak var presentedAlert: UIAlertController?
        var onCancel: () -> Void = {}

        func present(title: String, from controller: UIViewController) {
            guard controller.viewIfLoaded?.window != nil else { return }
            let alert = UIAlertController(
                title: title,
                message: "しばらくお待ちください。",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { [weak self] _ in
                // アクション実行時点でUIKitがアラートを取り下げ済み
                self?.presentedAlert = nil
                self?.onCancel()
            })
            presentedAlert = alert
            controller.present(alert, animated: true)
        }

        func dismissIfNeeded() {
            guard let alert = presentedAlert else { return }
            presentedAlert = nil
            alert.presentingViewController?.dismiss(animated: true)
        }
    }
}
