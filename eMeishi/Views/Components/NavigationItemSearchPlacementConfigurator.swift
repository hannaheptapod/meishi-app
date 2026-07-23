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
            item.searchController?.searchBar.searchTextField.backgroundColor = .secondarySystemGroupedBackground
        }
    }
}
