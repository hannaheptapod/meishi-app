import Testing
import UIKit
@testable import eMeishi

@MainActor
struct NavigationItemSearchPlacementConfiguratorTests {
    @Test func keepsSearchFieldSurfaceStableOnRootNavigationItem() throws {
        let rootViewController = UIViewController()
        rootViewController.navigationItem.searchController = UISearchController()
        let navigationController = UINavigationController(
            rootViewController: rootViewController
        )
        let configurator = NavigationItemSearchPlacementConfigurator.Controller()

        rootViewController.addChild(configurator)
        rootViewController.view.addSubview(configurator.view)
        configurator.didMove(toParent: rootViewController)
        configurator.configureNavigationItem()

        #expect(
            navigationController.viewControllers.first?.navigationItem
                .searchBarPlacementAllowsToolbarIntegration == false
        )
        #expect(rootViewController.navigationItem.preferredSearchBarPlacement == .stacked)
        #expect(rootViewController.navigationItem.hidesSearchBarWhenScrolling == false)
        #expect(
            rootViewController.navigationItem.searchController?.searchBar
                .searchTextField.backgroundColor != .secondarySystemGroupedBackground
        )
        let searchTextField = try #require(
            rootViewController.navigationItem.searchController?.searchBar.searchTextField
        )
        #expect(searchTextField.layer.borderWidth > 0)
        #expect(searchTextField.layer.borderColor != nil)
    }
}
