import Testing
import UIKit
@testable import eMeishi

@MainActor
struct NavigationItemSearchPlacementConfiguratorTests {
    @Test func keepsSearchFieldSurfaceStableOnRootNavigationItem() throws {
        let rootViewController = UIViewController()
        let searchController = UISearchController()
        searchController.searchBar.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        searchController.searchBar.layoutIfNeeded()
        rootViewController.navigationItem.searchController = searchController
        let navigationController = UINavigationController(
            rootViewController: rootViewController
        )
        let configurator = NavigationItemSearchPlacementConfigurator.Controller()

        rootViewController.addChild(configurator)
        rootViewController.view.addSubview(configurator.view)
        configurator.didMove(toParent: rootViewController)
        let searchTextField = try #require(
            rootViewController.navigationItem.searchController?.searchBar.searchTextField
        )
        let originalSearchBarFrame = searchController.searchBar.frame
        let originalTextFieldFrame = searchTextField.frame

        configurator.configureNavigationItem()

        #expect(
            navigationController.viewControllers.first?.navigationItem
                .searchBarPlacementAllowsToolbarIntegration == false
        )
        #expect(searchController.searchBar.frame == originalSearchBarFrame)
        #expect(searchTextField.frame == originalTextFieldFrame)
        #expect(searchTextField.layer.borderWidth > 0)
        #expect(searchTextField.layer.borderColor != nil)

        let configuredCornerRadius = searchTextField.layer.cornerRadius
        let configuredBorderWidth = searchTextField.layer.borderWidth
        configurator.configureNavigationItem()

        #expect(searchController.searchBar.frame == originalSearchBarFrame)
        #expect(searchTextField.frame == originalTextFieldFrame)
        #expect(searchTextField.layer.cornerRadius == configuredCornerRadius)
        #expect(searchTextField.layer.borderWidth == configuredBorderWidth)
    }
}
