import Testing
import Foundation
@testable import eMeishi

// MARK: - GrandfatherStore テスト

@MainActor
struct GrandfatherStoreTests {

    private let udKey = "firstLaunchMarketingVersion"

    private func setVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: udKey)
    }

    private func cleanup() {
        UserDefaults.standard.removeObject(forKey: udKey)
    }

    @Test func grandfatheredOnV1_0_1() {
        setVersion("1.0.1"); defer { cleanup() }
        GrandfatherStore.shared.evaluate()
        #expect(GrandfatherStore.shared.isGrandfathered == true)
    }

    @Test func grandfatheredOnV1_0_4() {
        setVersion("1.0.4"); defer { cleanup() }
        GrandfatherStore.shared.evaluate()
        #expect(GrandfatherStore.shared.isGrandfathered == true)
    }

    @Test func grandfatheredOnV1_0_9() {
        setVersion("1.0.9"); defer { cleanup() }
        GrandfatherStore.shared.evaluate()
        #expect(GrandfatherStore.shared.isGrandfathered == true)
    }

    @Test func grandfatheredOnMajorOlderVersion() {
        setVersion("0.9.9"); defer { cleanup() }
        GrandfatherStore.shared.evaluate()
        #expect(GrandfatherStore.shared.isGrandfathered == true)
    }

    @Test func notGrandfatheredOnProReleaseVersion() {
        setVersion("1.1.0"); defer { cleanup() }
        GrandfatherStore.shared.evaluate()
        #expect(GrandfatherStore.shared.isGrandfathered == false)
    }

    @Test func notGrandfatheredOnNewerPatchVersion() {
        setVersion("1.1.1"); defer { cleanup() }
        GrandfatherStore.shared.evaluate()
        #expect(GrandfatherStore.shared.isGrandfathered == false)
    }

    @Test func notGrandfatheredOnFutureMinorVersion() {
        setVersion("1.2.0"); defer { cleanup() }
        GrandfatherStore.shared.evaluate()
        #expect(GrandfatherStore.shared.isGrandfathered == false)
    }

    @Test func notGrandfatheredOnFutureMajorVersion() {
        setVersion("2.0.0"); defer { cleanup() }
        GrandfatherStore.shared.evaluate()
        #expect(GrandfatherStore.shared.isGrandfathered == false)
    }

    // 初回起動（UserDefaults なし）は現在のアプリバージョンで判定
    // テスト環境では CFBundleShortVersionString が存在するため、isGrandfathered の値は
    // 実際のビルドバージョンに依存する。クラッシュしないことを確認する。
    @Test func evaluateWithoutStoredVersionDoesNotCrash() {
        cleanup()
        GrandfatherStore.shared.evaluate()
        // isGrandfathered の値はビルドバージョン次第のため bool 値は検証しない
        _ = GrandfatherStore.shared.isGrandfathered
    }
}

// MARK: - EntitlementStore テスト

@MainActor
struct EntitlementStoreTests {

    @Test func hasAccessWhenGrandfathered() {
        EntitlementStore.shared.setup(isGrandfathered: true)
        defer { EntitlementStore.shared.setup(isGrandfathered: false) }
        #expect(EntitlementStore.shared.isGrandfathered == true)
        #expect(EntitlementStore.shared.hasAccess == true)
    }

    @Test func noAccessWhenNeitherProNorGrandfathered() {
        EntitlementStore.shared.setup(isGrandfathered: false)
        // テスト環境では Transaction.currentEntitlements が空 → hasPro = false
        #expect(EntitlementStore.shared.hasPro == false)
        #expect(EntitlementStore.shared.isGrandfathered == false)
        #expect(EntitlementStore.shared.hasAccess == false)
    }
}

// MARK: - ProductIdentifier テスト

struct ProductIdentifierTests {

    @Test func monthlyProductID() {
        #expect(ProductIdentifier.proMonthly.rawValue == "com.emeishi.pro.monthly")
    }

    @Test func yearlyProductID() {
        #expect(ProductIdentifier.proYearly.rawValue == "com.emeishi.pro.yearly")
    }

    @Test func allCasesCount() {
        #expect(ProductIdentifier.allCases.count == 2)
    }
}

// MARK: - PaywallContext テスト

@MainActor
struct PaywallContextTests {

    @Test func aiSearchContext() {
        let ctx = PaywallContext.aiSearch
        #expect(ctx.featureTitle == "AI 自然言語検索")
        #expect(!ctx.featureDescription.isEmpty)
    }

    @Test func bulkRetagContext() {
        let ctx = PaywallContext.bulkRetag
        #expect(ctx.featureTitle == "AI 一括リタグ")
        #expect(!ctx.featureDescription.isEmpty)
    }

    @Test func insightsNarrativeContext() {
        let ctx = PaywallContext.insightsNarrative
        #expect(ctx.featureTitle == "Insights AI 解釈")
        #expect(!ctx.featureDescription.isEmpty)
    }
}
