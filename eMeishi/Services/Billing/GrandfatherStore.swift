import Foundation
import StoreKit

// 1.1.0 より前のバージョンで初回起動したユーザーは AI 自然言語検索を Pro なしで利用できる。
//
// ⚠️ 1.0.x には firstLaunchMarketingVersion を記録するコードが入っていなかった。
// そのため 1.1.0 初回起動時点では UserDefaults は空になる。
// この前提の上で「1.1.0 より前から使っていたか」を複数の信号から推定する：
//
//   1. UserDefaults に過去の判定結果が pin されていれば採用（冪等性）
//   2. AppTransaction.originalAppVersion が取れれば真実の値として採用
//   3. AppTransaction が未検証／取得失敗なら、ローカル痕跡（名刺・設定書き込み）で判定
//   4. どれも該当しなければ現バージョンを pin（= 新規扱い）
//
// sentinel "0.0.0" は「既存ユーザー（Grandfather 付与対象）」を示す pin 値。
// iCloud KVS は entitlement 未設定のため使わず、UserDefaults のみを pin 先として使う。
// 機種変後の復元は CloudKit Private DB の GrandfatherMark レコード（syncWithCloudKit）で担う。
@MainActor
final class GrandfatherStore {

    static let shared = GrandfatherStore(
        transactionProvider: LiveAppTransactionProvider(),
        detector: LiveExistingUserDetector(persistenceController: .shared),
        cloudSync: LiveGrandfatherCloudSync(),
        currentVersionProvider: {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        }
    )

    private let proReleaseVersion = "1.1.0"
    private let udKey = "firstLaunchMarketingVersion"
    private let grandfatherSentinel = "0.0.0"

    private let transactionProvider: AppTransactionProviding
    private let detector: ExistingUserDetector
    private let cloudSync: GrandfatherCloudSyncing
    private let currentVersionProvider: () -> String

    private(set) var isGrandfathered = false

    init(
        transactionProvider: AppTransactionProviding,
        detector: ExistingUserDetector,
        cloudSync: GrandfatherCloudSyncing,
        currentVersionProvider: @escaping () -> String
    ) {
        self.transactionProvider = transactionProvider
        self.detector = detector
        self.cloudSync = cloudSync
        self.currentVersionProvider = currentVersionProvider
    }

    func evaluate() async {
        let resolved = await resolvedFirstLaunchVersion()
        isGrandfathered = isBefore(resolved, proReleaseVersion)
    }

    /// CloudKit Private DB の GrandfatherMark とローカル状態を同期する。
    ///
    /// CoreData の CloudKit 同期（遅延あり・unreliable）に頼らず、専用 CKRecord で
    /// デバイス間 Grandfather 状態を共有する。
    ///
    /// - 既に Grandfather 判定済みなら CloudKit にマークを push（冪等）
    /// - 新規扱い pin（proReleaseVersion 以上）のまま未判定なら CloudKit を fetch し、
    ///   マークが存在すれば sentinel に昇格する
    @discardableResult
    func syncWithCloudKit() async -> Bool {
        if isGrandfathered {
            await cloudSync.writeMark()
            return false
        }

        let ud = UserDefaults.standard
        guard let pinned = ud.string(forKey: udKey),
              pinned != grandfatherSentinel,
              !isBefore(pinned, proReleaseVersion) else {
            return false
        }

        guard await cloudSync.fetchMark() else { return false }

        pin(grandfatherSentinel, ud: ud)
        isGrandfathered = true
        return true
    }

    /// CloudKit 初回 import 完了後などに呼ぶ「昇格専用」再評価。
    ///
    /// iPad 機種変や 2 台目 TestFlight 初回起動では、evaluate() 実行時点で
    /// CoreData の CloudKit 同期が未完了・AppTransaction も nil のため、
    /// ステップ 4 で現バージョンが pin されて「新規扱い」に固定されてしまう。
    /// このメソッドは pin が proReleaseVersion 以上のときだけ、ローカル痕跡の再出現を
    /// 契機に pin を sentinel に昇格する。既に Grandfather なら no-op（降格はしない）。
    /// 戻り値: 昇格した場合 true。
    @discardableResult
    func reevaluateAfterSync() -> Bool {
        if isGrandfathered { return false }

        let ud = UserDefaults.standard
        guard let pinned = ud.string(forKey: udKey),
              pinned != grandfatherSentinel,
              !isBefore(pinned, proReleaseVersion) else {
            return false
        }

        guard detector.hasExistingUserSignals() else { return false }

        pin(grandfatherSentinel, ud: ud)
        isGrandfathered = true
        return true
    }

    // MARK: - Private

    private func resolvedFirstLaunchVersion() async -> String {
        let ud = UserDefaults.standard

        // 1. UserDefaults に pin 済み → そのまま採用
        if let local = ud.string(forKey: udKey) {
            return local
        }

        // 2. AppTransaction.originalAppVersion で真実を取得
        if let original = await transactionProvider.originalAppVersion() {
            if isBefore(original, proReleaseVersion) {
                pin(grandfatherSentinel, ud: ud)
                return grandfatherSentinel
            } else {
                pin(original, ud: ud)
                return original
            }
        }

        // 3. フォールバック: ローカルに既存ユーザー痕跡があれば Grandfather 扱い
        if detector.hasExistingUserSignals() {
            pin(grandfatherSentinel, ud: ud)
            return grandfatherSentinel
        }

        // 4. どの信号もなければ新規ユーザー。現バージョンを pin
        let current = currentVersionProvider()
        pin(current, ud: ud)
        return current
    }

    private func pin(_ version: String, ud: UserDefaults) {
        ud.set(version, forKey: udKey)
    }

    private func isBefore(_ version: String, _ threshold: String) -> Bool {
        let a = version.split(separator: ".").compactMap { Int($0) }
        let b = threshold.split(separator: ".").compactMap { Int($0) }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let ai = i < a.count ? a[i] : 0
            let bi = i < b.count ? b[i] : 0
            if ai < bi { return true }
            if ai > bi { return false }
        }
        return false
    }
}
