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
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            configureNavigationItem()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            configureNavigationItem()
        }

        func configureNavigationItem() {
            guard let navigationController else {
                return
            }
            let items = navigationController.navigationBar.items ?? []
            for item in items where item.searchController != nil {
                Self.configureSearchItem(item)
            }
        }

        static func configureSearchItem(_ item: UINavigationItem) {
            item.searchBarPlacementAllowsToolbarIntegration = false
            item.preferredSearchBarPlacement = .stacked
            item.hidesSearchBarWhenScrolling = false

            // 標準検索欄のLiquid GlassはUIKitへ任せる。遷移中も検索欄の輪郭だけは
            // 欠落しないよう、素材を覆わない1px未満の境界を常時維持する。
            guard let searchController = item.searchController else { return }
            searchController.loadViewIfNeeded()
            searchController.searchBar.sizeToFit()
            searchController.searchBar.layoutIfNeeded()
            let searchTextField = searchController.searchBar.searchTextField
            searchTextField.layer.cornerRadius = searchTextField.bounds.height / 2
            searchTextField.layer.cornerCurve = .continuous
            searchTextField.layer.borderWidth = 1 / searchTextField.traitCollection.displayScale
            searchTextField.layer.borderColor = UIColor.separator.withAlphaComponent(0.28).cgColor
            searchTextField.layoutIfNeeded()
        }
    }
}
