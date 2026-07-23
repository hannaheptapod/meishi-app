import Testing
import UIKit
@testable import eMeishi

@MainActor
struct NavigationItemSearchPlacementConfiguratorTests {
    @Test func disablesToolbarIntegrationOnRootNavigationItem() {
        let rootViewController = UIViewController()
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
    }
}
