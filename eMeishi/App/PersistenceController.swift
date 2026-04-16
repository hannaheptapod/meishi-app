import CoreData
import CloudKit
import os

// CoreData スタックの管理（iCloud 同期対応）
struct PersistenceController {

    // アプリ全体で共有するシングルトン
    static let shared = PersistenceController()

    /// CoreData ストア読み込みエラー（nil なら正常）
    private(set) var loadError: NSError?

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
            // 重複検出デモ用：山田太郎の重複候補（同姓・同名・同社、表記ゆれ「テックビジョン」のみ）
            ("山田", "やまだ", "太郎", "たろう",   "テックビジョン",             "てっくびじょん",       "営業本部",        "部長",             "yamada@techvision.jp",           "03-1234-5670"),
        ]

        var cards: [BusinessCard] = []
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
            cards.append(card)
        }

        // タグ3種を作成（スクリーンショット用サンプル）
        let tagImportant = Tag(context: context)
        tagImportant.id = UUID(); tagImportant.name = "重要"
        tagImportant.colorHex = "#FF3B30"; tagImportant.sortOrder = 0; tagImportant.createdAt = Date()

        let tagIT = Tag(context: context)
        tagIT.id = UUID(); tagIT.name = "IT"
        tagIT.colorHex = "#007AFF"; tagIT.sortOrder = 1; tagIT.createdAt = Date()

        let tagClient = Tag(context: context)
        tagClient.id = UUID(); tagClient.name = "取引先"
        tagClient.colorHex = "#34C759"; tagClient.sortOrder = 2; tagClient.createdAt = Date()

        // お気に入り設定（山田太郎・山田健一・佐藤美咲）
        cards[0].isFavorite = true
        cards[2].isFavorite = true
        cards[4].isFavorite = true

        // タグ付与
        cards[0].addToTags(tagImportant); cards[0].addToTags(tagIT) // 山田太郎: 重要+IT
        cards[2].addToTags(tagIT)                                    // 山田健一: IT
        cards[3].addToTags(tagClient)                                // 佐藤誠: 取引先
        cards[4].addToTags(tagClient)                                // 佐藤美咲: 取引先
        cards[6].addToTags(tagIT); cards[6].addToTags(tagClient)     // 田中由美: IT+取引先

        try? context.save()
        return controller
    }()

    let container: NSPersistentContainer

    /// iCloud 同期が有効かどうか
    let iCloudSyncEnabled: Bool

    // NSManagedObjectModel を静的にキャッシュして並列初期化でのレース条件を防ぐ。
    // Swift Testing はテストを並列実行するため、複数の PersistenceController(inMemory:) が
    // 同時に生成されると NSPersistentCloudKitContainer(name:) 内部のモデルロードで
    // CFBasicHashAddValue のレースが発生しクラッシュする。static let で一度だけロードし共有する。
    private static let managedObjectModel: NSManagedObjectModel = {
        guard let url = Bundle.main.url(forResource: "BusinessCard", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: url) else {
            fatalError("NSManagedObjectModel 'BusinessCard.momd' が見つかりません")
        }
        return model
    }()

    init(inMemory: Bool = false) {
        let userWantsSync = !inMemory && UserDefaults.standard.bool(forKey: "iCloudSyncEnabled")

        // 過去に CloudKit エラーが発生していれば同期を無効化（コンテナクラスは変えない）
        let cloudKitFailed = UserDefaults.standard.bool(forKey: "cloudKitContainerUnavailable")
        let syncEnabled = userWantsSync && !cloudKitFailed
        self.iCloudSyncEnabled = syncEnabled

        // 常に NSPersistentCloudKitContainer を使用する。
        // NSPersistentContainer と NSPersistentCloudKitContainer をトグルで切り替えると、
        // ローカル専用で初期化されたストアに後から CloudKit メタデータ（PCS 暗号鍵）を
        // 追加しようとして _pcs_data の BAD_REQUEST が発生し同期が一切機能しなくなる。
        // 同期を無効化したい場合は cloudKitContainerOptions = nil で制御する。
        container = NSPersistentCloudKitContainer(name: "BusinessCard",
                                                  managedObjectModel: Self.managedObjectModel)

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

            // Persistent History Tracking: 本番ストアのみ有効化
            // iCloud 同期ON時は NSPersistentCloudKitContainer が必要とし、
            // 同期OFF時も過去に同期ONで開いたストアの互換性を維持するため必須
            // （未設定だと Read Only モードに強制される）
            // in-memory テストストアでは無効化する。有効にすると Swift Testing の
            // 並列実行で複数の PersistenceController(inMemory: true) が同時に
            // _PFPersistentHistoryModel のキャッシュを構築しようとして
            // CFBasicHashAddValue / EXC_BAD_ACCESS が発生するため。
            if !inMemory {
                description.setOption(true as NSNumber,
                                      forKey: NSPersistentHistoryTrackingKey)
            }

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
        var loadErr: NSError?
        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                AppLogger.persistence.error("CoreData の読み込みに失敗しました: \(error), \(error.userInfo)")
                loadErr = error
            }
        }
        self.loadError = loadErr
        // 別スレッドからの変更を自動マージ（本番ストアのみ）
        // in-memory テストストアでは無効化する。有効にすると Swift Testing の並列実行で
        // 複数の PersistenceController(inMemory: true) が同時に
        // viewContext.automaticallyMergesChangesFromParent = true を呼び出し、
        // 内部の performBlockAndWait がメインスレッドに集中して NSMutableSet の
        // ミューテーションエラー（EXC_CRASH SIGABRT）が発生するため。
        if !inMemory {
            container.viewContext.automaticallyMergesChangesFromParent = true
            // iCloud 同期時の競合解決ポリシー（最後の書き込みが勝つ）
            container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        }

        // iCloud 同期有効時、CloudKit Container の可用性をバックグラウンドで確認
        if syncEnabled {
            Self.verifyCloudKitContainer()
        }

        // iCloud アカウント変更（サインアウト・切り替え）を検知してログ記録
        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { @Sendable _ in
            AppLogger.persistence.info("iCloud アカウント状態が変化しました — 次回起動時に同期状態を再確認します")
            // accountStatus を再確認してフラグを更新
            Self.verifyCloudKitContainer()
        }

        // CloudKit 同期イベント（import / export / setup）のエラーをログに記録
        if syncEnabled {
            NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: container,
                queue: .main
            ) { @Sendable notification in
                guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event,
                      let error = event.error else { return }
                AppLogger.persistence.error("CloudKit 同期エラー: type=\(event.type.rawValue) error=\(error)")
            }
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

// MARK: - URI 文字列から BusinessCard を解決するヘルパー
// DuplicatePair の Sendable 化に伴い、View 側で URI 文字列から BusinessCard を
// 復元する必要が生じたため、PersistentStoreCoordinator 経由の解決を集約する。

extension NSManagedObjectContext {
    /// `NSManagedObjectID.uriRepresentation().absoluteString` から BusinessCard を解決する。
    /// 削除済み・URI 不正・別エンティティの場合は nil を返す。
    func businessCard(forURIString uri: String) -> BusinessCard? {
        guard let url = URL(string: uri),
              let id = persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url)
        else { return nil }
        return try? existingObject(with: id) as? BusinessCard
    }
}
