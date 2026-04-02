import CoreData
import CloudKit
import os

// CoreData スタックの管理（iCloud 同期対応）
struct PersistenceController {

    // アプリ全体で共有するシングルトン
    static let shared = PersistenceController()

    // PreviewやテストでもアクセスできるようにPreview用インスタンスを用意
    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        // サンプルデータ定義
        // (lastName, lastNameReading, firstName, firstNameReading, company, companyReading, department, title, email, phone)
        // companyReading は法人格を含まない読み（例：「テックビジョン」のみ）
        typealias SampleRow = (String, String, String, String, String, String, String, String, String, String)
        let samples: [SampleRow] = [
            // 「やまだ」姓 × 3人
            ("山田", "やまだ", "太郎", "たろう",   "株式会社テックビジョン",     "てっくびじょん",       "営業部",          "営業部長",         "yamada.taro@techvision.co.jp",   "03-1234-5678"),
            ("山田", "やまだ", "花子", "はなこ",   "グローバル商事株式会社",     "ぐろーばるしょうじ",   "人事部",          "人事マネージャー", "yamada.h@global-shoji.co.jp",    "06-2345-6789"),
            ("山田", "やまだ", "健一", "けんいち",  "株式会社テックビジョン",     "てっくびじょん",       "開発部",          "シニアエンジニア", "yamada.k@techvision.co.jp",      "03-1234-9999"),
            // 「さとう」姓 × 2人
            ("佐藤", "さとう", "誠",  "まこと",   "グローバル商事株式会社",     "ぐろーばるしょうじ",   "営業部",          "営業課長",         "sato.m@global-shoji.co.jp",      "06-2345-0001"),
            ("佐藤", "さとう", "美咲", "みさき",   "有限会社クリエイティブラボ", "くりえいてぃぶらぼ",   "デザイン室",      "デザイナー",       "sato.misaki@creative-lab.jp",    "090-3456-7890"),
            // その他
            ("鈴木", "すずき", "一郎", "いちろう",  "有限会社クリエイティブラボ", "くりえいてぃぶらぼ",   "企画室",          "プロデューサー",   "suzuki@creative-lab.jp",         "090-9876-5432"),
            ("田中", "たなか", "由美", "ゆみ",     "株式会社テックビジョン",     "てっくびじょん",       "マーケティング部", "ディレクター",     "tanaka.y@techvision.co.jp",      "03-1234-1111"),
            ("中村", "なかむら", "剛", "つよし",   "グローバル商事株式会社",     "ぐろーばるしょうじ",   "経理部",          "取締役CFO",        "nakamura@global-shoji.co.jp",    "06-2345-9999"),
        ]

        for (i, s) in samples.enumerated() {
            let card = BusinessCard(context: context)
            card.id               = UUID()
            card.lastName         = s.0
            card.lastNameReading  = s.1
            card.firstName        = s.2
            card.firstNameReading = s.3
            card.company          = s.4
            card.companyReading   = s.5
            card.department       = s.6
            card.title            = s.7
            card.email            = s.8
            card.phone            = s.9
            card.createdAt        = Date(timeIntervalSinceNow: -Double(i) * 86400)
            card.updatedAt        = Date(timeIntervalSinceNow: -Double(i) * 86400)
        }

        try? context.save()
        return controller
    }()

    let container: NSPersistentContainer

    /// iCloud 同期が有効かどうか
    let iCloudSyncEnabled: Bool

    init(inMemory: Bool = false) {
        let userWantsSync = !inMemory && UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")

        // iCloud 同期が有効でも、過去に CloudKit エラーが発生していればローカル専用にフォールバック
        let cloudKitFailed = UserDefaults.standard.bool(forKey: "cloudKitContainerUnavailable")
        let syncEnabled = userWantsSync && !cloudKitFailed
        self.iCloudSyncEnabled = syncEnabled

        // iCloud 同期が有効なら NSPersistentCloudKitContainer を使用
        if syncEnabled {
            container = NSPersistentCloudKitContainer(name: "BusinessCard")
        } else {
            container = NSPersistentContainer(name: "BusinessCard")
        }

        if inMemory {
            // テスト・プレビュー用：ディスクに書き込まない
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        // 軽量マイグレーションを有効化（新しいオプショナル属性の追加などを自動処理）
        if let description = container.persistentStoreDescriptions.first {
            description.setOption(true as NSNumber,
                                  forKey: NSMigratePersistentStoresAutomaticallyOption)
            description.setOption(true as NSNumber,
                                  forKey: NSInferMappingModelAutomaticallyOption)
            // デバイスロック後もバックグラウンド同期を可能にするため
            // completeUntilFirstUserAuthentication を使用
            // （complete だとロック中にストアアクセス不可→CloudKit同期失敗）
            if !inMemory {
                description.setOption(FileProtectionType.completeUntilFirstUserAuthentication as NSObject,
                                      forKey: NSPersistentStoreFileProtectionKey)
            }

            // Persistent History Tracking を常に有効化
            // iCloud 同期ON時は NSPersistentCloudKitContainer が必要とし、
            // 同期OFF時も過去に同期ONで開いたストアの互換性を維持するため必須
            // （未設定だと Read Only モードに強制される）
            description.setOption(true as NSNumber,
                                  forKey: NSPersistentHistoryTrackingKey)

            // iCloud 同期の CloudKit コンテナ設定
            if syncEnabled {
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: "iCloud.com.jinks.emeishi"
                )
                // リモート変更通知を有効化
                description.setOption(true as NSNumber,
                                      forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            } else {
                // 明示的に CloudKit を無効化
                description.cloudKitContainerOptions = nil
            }
        }
        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("CoreData の読み込みに失敗しました: \(error), \(error.userInfo)")
            }
        }
        // 別スレッドからの変更を自動マージ
        container.viewContext.automaticallyMergesChangesFromParent = true
        // iCloud 同期時の競合解決ポリシー（最後の書き込みが勝つ）
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        // iCloud 同期有効時、CloudKit Container の可用性をバックグラウンドで確認
        if syncEnabled {
            Self.verifyCloudKitContainer()
        }

        // 既存データの companyReading から法人格を除去（一度だけ実行）
        if !inMemory {
            Self.migrateCompanyReadings(context: container.viewContext)
        }
    }

    /// CloudKit Container が利用可能か非同期で確認し、失敗時は次回起動からローカル専用にフォールバック
    private static func verifyCloudKitContainer() {
        let ckContainer = CKContainer(identifier: "iCloud.com.jinks.emeishi")
        ckContainer.accountStatus { status, error in
            if let error = error as? CKError, error.code == .badContainer {
                AppLogger.persistence.warning("CloudKit Container が未登録です — 次回起動からローカル専用で動作します")
                UserDefaults.standard.set(true, forKey: "cloudKitContainerUnavailable")
            } else if status == .available {
                // Container が利用可能になったらフラグをリセット
                UserDefaults.standard.set(false, forKey: "cloudKitContainerUnavailable")
            }
        }
    }

    /// 既存データの companyReading に法人格が含まれていれば除去する
    private static func migrateCompanyReadings(context: NSManagedObjectContext) {
        let key = "didMigrateCompanyReadingLegalEntity"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let request = BusinessCard.fetchRequest()
        guard let cards = try? context.fetch(request) else { return }

        var changed = false
        for card in cards {
            guard let reading = card.companyReading, !reading.isEmpty else { continue }
            let stripped = LegalEntityTerms.stripReading(from: reading)
            if stripped != reading {
                card.companyReading = stripped
                changed = true
            }
        }

        if changed {
            try? context.save()
        }
        UserDefaults.standard.set(true, forKey: key)
    }
}
