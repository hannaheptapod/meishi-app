import Foundation
import Testing
@testable import eMeishi

@MainActor
struct CloudKitLaunchSafetyTests {
    private nonisolated struct DenyAllChecker: CloudKitEntitlementChecking {
        nonisolated func canCreateContainer(identifier: String) -> Bool { false }
    }

    @Test
    func uiTestProcessNeverCreatesCloudKitContainer() {
        let checker = SignedCloudKitEntitlementChecker(
            executableURL: Bundle.main.executableURL,
            arguments: ["eMeishi", "-UITestMode"],
            environment: [:]
        )
        #expect(!checker.canCreateContainer(identifier: GrandfatherCloudSyncFactory.containerIdentifier))
    }

    @Test
    func missingEntitlementUsesNoopSync() async {
        let sync = GrandfatherCloudSyncFactory.make(entitlementChecker: DenyAllChecker())
        #expect(sync is NoopGrandfatherCloudSync)
        #expect(await sync.fetchMark() == false)
        await sync.writeMark()
    }
}
