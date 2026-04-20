import CloudKit
import Foundation

// Grandfather 判定結果を CloudKit Private Database の専用レコードで同期する。
// CoreData の CloudKit 同期（NSPersistentCloudKitContainer）は独自ゾーン
// "com.apple.coredata.cloudkit.zone" を使うが、本サービスは default zone の
// レコード "GrandfatherMark-v1" を直接 save/fetch する独立チャネル。
// UserDefaults は device-local、KVS は entitlement 未設定で local-only のため
// デバイス間で確実に Grandfather 状態を共有できる経路はこれのみ。
protocol GrandfatherCloudSyncing: Sendable {
    /// Grandfather マークが CloudKit に存在するか確認する。
    /// ネットワーク失敗・未ログイン等は false を返す（best-effort）。
    func fetchMark() async -> Bool
    /// Grandfather マークを CloudKit に書き込む。失敗は無視（best-effort）。
    func writeMark() async
}

struct LiveGrandfatherCloudSync: GrandfatherCloudSyncing {

    private static let containerIdentifier = "iCloud.com.jinks.emeishi"
    private static let recordType = "GrandfatherMark"
    private static let recordName = "GrandfatherMark-v1"

    private var privateDatabase: CKDatabase {
        CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase
    }

    private var recordID: CKRecord.ID {
        CKRecord.ID(recordName: Self.recordName)
    }

    func fetchMark() async -> Bool {
        do {
            _ = try await privateDatabase.record(for: recordID)
            return true
        } catch {
            return false
        }
    }

    func writeMark() async {
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["version"] = "0.0.0" as CKRecordValue
        do {
            _ = try await privateDatabase.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // 既に存在する。成功扱い。
        } catch {
            // best-effort: オフライン / 未ログインは無視
        }
    }
}
