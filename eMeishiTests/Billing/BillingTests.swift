import Testing
import Foundation
@testable import eMeishi

// MARK: - GrandfatherStore テスト（1.0.x ブートストラップ問題対応後）
//
// 1.0.x には firstLaunchMarketingVersion を記録するコードが入っていなかったため、
// 1.1.0 初回起動時は UserDefaults / iCloud KVS が空になる前提で
// AppTransaction + ローカル痕跡フォールバックを組み合わせた判定ロジックを検証する。

// UserDefaults は全プロセス共有のため、並列実行すると相互干渉する。
@MainActor
@Suite(.serialized)
struct GrandfatherStoreTests {

    private let udKey = "firstLaunchMarketingVersion"

    // MARK: - Mocks

    struct MockAppTransactionProvider: AppTransactionProviding {
        let version: String?
        func originalAppVersion() async -> String? { version }
    }

    struct MockExistingUserDetector: ExistingUserDetector {
        let hasSignals: Bool
        func hasExistingUserSignals() -> Bool { hasSignals }
    }

    // シミュレータの NSUbiquitousKeyValueStore は iCloud アカウント未リンクだと
    // 書き込みが効かないため、テストではインメモリのダブルで置き換える。
    final class InMemoryUbiquitousKVStore: UbiquitousKeyValueStoring, @unchecked Sendable {
        private var storage: [String: String] = [:]
        init(initial: [String: String] = [:]) { self.storage = initial }
        func getString(forKey key: String) -> String? { storage[key] }
        func setString(_ value: String, forKey key: String) { storage[key] = value }
    }

    // MARK: - Helpers

    private func cleanupUD() {
        UserDefaults.standard.removeObject(forKey: udKey)
    }

    private func makeStore(
        transaction: String?,
        hasSignals: Bool = false,
        iCloud: UbiquitousKeyValueStoring = InMemoryUbiquitousKVStore(),
        currentVersion: String = "1.1.0"
    ) -> GrandfatherStore {
        GrandfatherStore(
            transactionProvider: MockAppTransactionProvider(version: transaction),
            detector: MockExistingUserDetector(hasSignals: hasSignals),
            ubiquitousStore: iCloud,
            currentVersionProvider: { currentVersion }
        )
    }

    // MARK: - シナリオ 1: AppTransaction verified "1.0.2" → Grandfather

    @Test func grandfatheredFromVerifiedOldVersion_102() async {
        cleanupUD(); defer { cleanupUD() }
        let iCloud = InMemoryUbiquitousKVStore()
        let store = makeStore(transaction: "1.0.2", iCloud: iCloud)
        await store.evaluate()
        #expect(store.isGrandfathered == true)
        #expect(UserDefaults.standard.string(forKey: udKey) == "0.0.0")
        #expect(iCloud.getString(forKey: udKey) == "0.0.0")
    }

    // MARK: - シナリオ 2: AppTransaction verified "1.0.4" → Grandfather

    @Test func grandfatheredFromVerifiedOldVersion_104() async {
        cleanupUD(); defer { cleanupUD() }
        let store = makeStore(transaction: "1.0.4")
        await store.evaluate()
        #expect(store.isGrandfathered == true)
        #expect(UserDefaults.standard.string(forKey: udKey) == "0.0.0")
    }

    // MARK: - シナリオ 3: AppTransaction verified "1.1.0"（新規インストール） → NOT Grandfather

    @Test func notGrandfatheredOnFreshInstallAtProRelease() async {
        cleanupUD(); defer { cleanupUD() }
        let store = makeStore(transaction: "1.1.0", currentVersion: "1.1.0")
        await store.evaluate()
        #expect(store.isGrandfathered == false)
        // 実バージョン（AppTransaction の値）が pin される
        #expect(UserDefaults.standard.string(forKey: udKey) == "1.1.0")
    }

    // MARK: - シナリオ 4: TestFlight 初回 offline・AppTransaction 未取得 + 名刺あり → Grandfather

    @Test func grandfatheredWhenTransactionUnavailableButSignalsPresent() async {
        cleanupUD(); defer { cleanupUD() }
        let store = makeStore(transaction: nil, hasSignals: true)
        await store.evaluate()
        #expect(store.isGrandfathered == true)
        #expect(UserDefaults.standard.string(forKey: udKey) == "0.0.0")
    }

    // MARK: - シナリオ 5: TestFlight 初回 offline・AppTransaction 未取得 + UserDefaults 痕跡 → Grandfather

    @Test func grandfatheredViaSettingsWriteSignals() async {
        cleanupUD(); defer { cleanupUD() }
        // hasSignals=true は detector 経由での検出を再現。
        // LiveExistingUserDetector は persistentDomain を参照して同等の動作をする
        let store = makeStore(transaction: nil, hasSignals: true)
        await store.evaluate()
        #expect(store.isGrandfathered == true)
    }

    // MARK: - シナリオ 6: TestFlight 初回 offline・AppTransaction 未取得・痕跡なし → 新規扱い

    @Test func notGrandfatheredWhenNoSignalsAtAll() async {
        cleanupUD(); defer { cleanupUD() }
        let store = makeStore(transaction: nil, hasSignals: false, currentVersion: "1.1.0")
        await store.evaluate()
        #expect(store.isGrandfathered == false)
        #expect(UserDefaults.standard.string(forKey: udKey) == "1.1.0")
    }

    // MARK: - シナリオ 7: 2 回目以降の evaluate（UserDefaults に sentinel pin 済み）→ 冪等に Grandfather

    @Test func idempotentSecondEvaluateAfterPin() async {
        cleanupUD(); defer { cleanupUD() }
        UserDefaults.standard.set("0.0.0", forKey: udKey)
        // AppTransaction / detector が逆のことを言っても UserDefaults が優先
        let store = makeStore(transaction: "1.1.0", hasSignals: false)
        await store.evaluate()
        #expect(store.isGrandfathered == true)
    }

    // MARK: - シナリオ 8: 機種変後の復元（UserDefaults 空・iCloud KVS に sentinel）→ Grandfather

    @Test func grandfatheredRestoredFromICloudKVS() async {
        cleanupUD(); defer { cleanupUD() }
        let iCloud = InMemoryUbiquitousKVStore(initial: [udKey: "0.0.0"])
        let store = makeStore(transaction: nil, iCloud: iCloud)
        await store.evaluate()
        #expect(store.isGrandfathered == true)
        // iCloud の値が UserDefaults に昇格
        #expect(UserDefaults.standard.string(forKey: udKey) == "0.0.0")
    }

    // MARK: - シナリオ 9: isBefore 境界（UserDefaults 経路で検証）

    @Test func boundary_1_0_99_isBeforeProRelease() async {
        cleanupUD(); defer { cleanupUD() }
        UserDefaults.standard.set("1.0.99", forKey: udKey)
        let store = makeStore(transaction: nil)
        await store.evaluate()
        #expect(store.isGrandfathered == true)
    }

    @Test func boundary_1_1_0_isNotBeforeProRelease() async {
        cleanupUD(); defer { cleanupUD() }
        UserDefaults.standard.set("1.1.0", forKey: udKey)
        let store = makeStore(transaction: nil)
        await store.evaluate()
        #expect(store.isGrandfathered == false)
    }

    @Test func boundary_1_1_1_isNotBeforeProRelease() async {
        cleanupUD(); defer { cleanupUD() }
        UserDefaults.standard.set("1.1.1", forKey: udKey)
        let store = makeStore(transaction: nil)
        await store.evaluate()
        #expect(store.isGrandfathered == false)
    }

    // 念のため 1.0.x 全体も UserDefaults 経路で検証
    @Test func legacyStoredVersionPaths() async {
        for v in ["0.9.9", "1.0.0", "1.0.1", "1.0.4", "1.0.9"] {
            cleanupUD()
            UserDefaults.standard.set(v, forKey: udKey)
            let store = makeStore(transaction: nil)
            await store.evaluate()
            #expect(store.isGrandfathered == true, "\(v) should be Grandfather")
        }
        cleanupUD()
    }

    // MARK: - シナリオ 10: iPad 初回起動（全判定失敗）→ "1.1.0" pin → CloudKit 同期で痕跡出現 → 昇格

    @Test func reevaluateAfterSync_upgradesNewPinToSentinelWhenSignalsAppear() async {
        cleanupUD(); defer { cleanupUD() }

        // 初回評価: 全信号なし → "1.1.0" pin・新規扱い
        let detector = MutableDetector(initial: false)
        let store = GrandfatherStore(
            transactionProvider: MockAppTransactionProvider(version: nil),
            detector: detector,
            ubiquitousStore: InMemoryUbiquitousKVStore(),
            currentVersionProvider: { "1.1.0" }
        )
        await store.evaluate()
        #expect(store.isGrandfathered == false)
        #expect(UserDefaults.standard.string(forKey: udKey) == "1.1.0")

        // CloudKit 同期で CoreData にカードが入ってくる
        detector.hasSignals = true
        let changed = store.reevaluateAfterSync()

        #expect(changed == true)
        #expect(store.isGrandfathered == true)
        #expect(UserDefaults.standard.string(forKey: udKey) == "0.0.0")
    }

    // MARK: - シナリオ 11: 既に Grandfather 判定済みなら reevaluateAfterSync は no-op（降格しない）

    @Test func reevaluateAfterSync_isNoOpWhenAlreadyGrandfathered() async {
        cleanupUD(); defer { cleanupUD() }
        let detector = MutableDetector(initial: true)
        let store = GrandfatherStore(
            transactionProvider: MockAppTransactionProvider(version: "1.0.2"),
            detector: detector,
            ubiquitousStore: InMemoryUbiquitousKVStore(),
            currentVersionProvider: { "1.1.0" }
        )
        await store.evaluate()
        #expect(store.isGrandfathered == true)

        // 痕跡が消えたように見せても降格しない
        detector.hasSignals = false
        let changed = store.reevaluateAfterSync()
        #expect(changed == false)
        #expect(store.isGrandfathered == true)
    }

    // MARK: - シナリオ 12: sentinel pin 済みで痕跡なしでも再評価は no-op

    @Test func reevaluateAfterSync_isNoOpWhenPinnedAsSentinel() async {
        cleanupUD(); defer { cleanupUD() }
        UserDefaults.standard.set("0.0.0", forKey: udKey)
        let detector = MutableDetector(initial: false)
        let store = GrandfatherStore(
            transactionProvider: MockAppTransactionProvider(version: nil),
            detector: detector,
            ubiquitousStore: InMemoryUbiquitousKVStore(),
            currentVersionProvider: { "1.1.0" }
        )
        await store.evaluate()
        #expect(store.isGrandfathered == true)

        let changed = store.reevaluateAfterSync()
        #expect(changed == false)
    }

    // MARK: - シナリオ 13: pin が "1.1.0" でも痕跡がなければ昇格しない

    @Test func reevaluateAfterSync_doesNotUpgradeWithoutSignals() async {
        cleanupUD(); defer { cleanupUD() }
        UserDefaults.standard.set("1.1.0", forKey: udKey)
        let detector = MutableDetector(initial: false)
        let store = GrandfatherStore(
            transactionProvider: MockAppTransactionProvider(version: nil),
            detector: detector,
            ubiquitousStore: InMemoryUbiquitousKVStore(),
            currentVersionProvider: { "1.1.0" }
        )
        await store.evaluate()

        let changed = store.reevaluateAfterSync()
        #expect(changed == false)
        #expect(store.isGrandfathered == false)
    }

    /// テスト中に hasSignals を切り替えたいので可変な detector ダブル
    final class MutableDetector: ExistingUserDetector, @unchecked Sendable {
        var hasSignals: Bool
        init(initial: Bool) { self.hasSignals = initial }
        func hasExistingUserSignals() -> Bool { hasSignals }
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
