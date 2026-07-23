import SwiftUI
import UIKit

/// SwiftUIが生成する一覧のNavigation Itemへ、常時表示の標準検索配置を適用する。
struct NavigationItemSearchPlacementConfigurator: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.configureNavigationItem()
    }

    @MainActor
    final class Controller: UIViewController {
        private weak var configuredSearchTextField: UISearchTextField?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            configureNavigationItem()
        }

        func configureNavigationItem() {
            guard let navigationController else {
                return
            }
            let items = navigationController.navigationBar.items ?? []
            for item in items where item.searchController != nil {
                configureSearchItem(item)
            }
        }

        private func configureSearchItem(_ item: UINavigationItem) {
            // `.searchable(.navigationBarDrawer(displayMode: .always))`が配置と寸法を
            // 所有する。ここではiOS 26で検索欄がToolbarへ移されることだけを防ぐ。
            // 同じ値を遷移ごとに再代入してNavigation Barを再レイアウトしない。
            if item.searchBarPlacementAllowsToolbarIntegration {
                item.searchBarPlacementAllowsToolbarIntegration = false
            }

            guard let searchController = item.searchController else { return }
            searchController.loadViewIfNeeded()
            let searchTextField = searchController.searchBar.searchTextField

            // iOS 26ではToolbar統合中にsearchTextFieldの実体が入れ替わる既知問題が
            // ある。統合を無効化した後の同一インスタンスへ一度だけ輪郭を設定し、
            // popアニメーション中の暫定寸法では再計算しない。
            guard configuredSearchTextField !== searchTextField,
                  searchTextField.bounds.height > 0 else { return }
            searchTextField.layer.cornerRadius = searchTextField.bounds.height / 2
            searchTextField.layer.cornerCurve = .continuous
            searchTextField.layer.borderWidth = 1 / searchTextField.traitCollection.displayScale
            searchTextField.layer.borderColor = UIColor.separator.withAlphaComponent(0.28).cgColor
            configuredSearchTextField = searchTextField
        }
    }
}
