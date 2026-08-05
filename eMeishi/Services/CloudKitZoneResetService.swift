import CloudKit
import Combine
import Foundation

// PRIVATE DB の CoreData 用 zone を強制削除して iCloud 同期を復旧させるサービス。
//
// NSPersistentCloudKitContainer は PCS（Protected Cloud Storage）暗号鍵を
// `_pcs_data` レコードとして zone 内に保持する。過去のコンテナ切替履歴や
// Keychain 状態の齟齬で `_pcs_data` が汚染されると、RecordSave が
// BAD_REQUEST で失敗し続け双方向同期が完全に停止する（アプリ再インストール
// では zone は消えない）。
//
// 本サービスは `CKDatabase.modifyRecordZones(deleting:)` で
// `com.apple.coredata.cloudkit.zone` を PRIVATE DB から削除する。
// ローカル CoreData は温存され、次回 iCloud 同期を有効化した時点で
// NSPersistentCloudKitContainer が fresh な PCS 鍵で zone を再生成する。
//
// 影響範囲はユーザー本人の PRIVATE DB のみ。PUBLIC DB（LocalLLM 配布）と
// 他ユーザーのデータには触れない。
@MainActor
final class CloudKitZoneResetService: ObservableObject {

    static let shared = CloudKitZoneResetService()

    private static let containerIdentifier = "iCloud.com.jinks.emeishi"
    private static let coreDataZoneName = "com.apple.coredata.cloudkit.zone"
    private let entitlementChecker: any CloudKitEntitlementChecking

    @Published private(set) var isResetting = false
    @Published private(set) var lastError: String?

    init(entitlementChecker: any CloudKitEntitlementChecking = SignedCloudKitEntitlementChecker()) {
        self.entitlementChecker = entitlementChecker
    }

    /// CoreData の CloudKit zone を削除する。
    /// 削除後は `iCloudSyncEnabled` / `cloudKitContainerUnavailable` を false に倒し、
    /// 再起動後のユーザー操作（同期を再有効化）を起点に zone を再構築させる。
    /// - Returns: 削除に成功したか（zoneNotFound は成功扱い）
    func resetCoreDataZone() async -> Bool {
        isResetting = true
        lastError = nil
        defer { isResetting = false }

        guard entitlementChecker.canCreateContainer(identifier: Self.containerIdentifier) else {
            lastError = "この環境ではiCloud同期の修復を実行できません"
            return false
        }

        let container = CKContainer(identifier: Self.containerIdentifier)
        let db = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(
            zoneName: Self.coreDataZoneName,
            ownerName: CKCurrentUserDefaultName
        )

        do {
            _ = try await db.modifyRecordZones(saving: [], deleting: [zoneID])
            clearSyncFlags()
            return true
        } catch let error as CKError where error.code == .zoneNotFound {
            // zone が既に存在しない場合は成功扱い（PCS 状態もクリーン）
            clearSyncFlags()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func clearSyncFlags() {
        let ud = UserDefaults.standard
        ud.set(false, forKey: "iCloudSyncEnabled")
        ud.set(false, forKey: "cloudKitContainerUnavailable")
    }
}
