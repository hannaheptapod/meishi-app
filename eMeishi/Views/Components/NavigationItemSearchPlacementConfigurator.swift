import SwiftUI
import UIKit

/// SwiftUIが生成するNavigation Itemへ、iOS 26の標準検索配置設定を適用する。
///
/// iOS 26では検索欄をiPhoneのToolbarへ統合する既定挙動により、Navigationの
/// 復帰時に検索欄が遅れて組み直される場合がある。Appleの回避策（156174227）に
/// 従い、一覧のNavigation ItemだけToolbar統合を無効にする。
struct NavigationItemSearchPlacementConfigurator: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.configureNavigationItem()
    }

    @MainActor
    final class Controller: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            configureNavigationItem()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            configureNavigationItem()
        }

        func configureNavigationItem() {
            guard let navigationController,
                  let rootViewController = navigationController.viewControllers.first else {
                return
            }
            guard rootViewController.navigationItem.searchBarPlacementAllowsToolbarIntegration else {
                return
            }
            rootViewController.navigationItem.searchBarPlacementAllowsToolbarIntegration = false
        }
    }
}
