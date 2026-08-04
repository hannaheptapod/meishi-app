import CoreData
import CloudKit
import os
import UIKit

// CoreData スタックの管理（iCloud 同期対応）
struct PersistenceController {

    @MainActor private static var readingMigrationTask: Task<Void, Never>?
    @MainActor private static var readingMigrationGeneration = UUID()

    // アプリ全体で共有するシングルトン
    static let shared = PersistenceController()

    /// 非同期ストア読み込みの進行・失敗を UI へ公開する。
    let storeLoadMonitor: PersistentStoreLoadMonitor

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
        cards[0].imageData = ScreenshotMockSupport.mockBusinessCardImage()
            .jpegData(compressionQuality: 0.88)

        // タグ付与
        cards[0].addToTags(tagImportant); cards[0].addToTags(tagIT) // 山田太郎: 重要+IT
        cards[2].addToTags(tagIT)                                    // 山田健一: IT
        cards[3].addToTags(tagClient)                                // 佐藤誠: 取引先
        cards[4].addToTags(tagClient)                                // 佐藤美咲: 取引先
        cards[6].addToTags(tagIT); cards[6].addToTags(tagClient)     // 田中由美: IT+取引先

        try? context.save()

        // App Store スクリーンショット撮影時だけ一覧・グラフが埋まる件数へ増強する。
        // 通常 UI テストは基本 9 件への assert を持つため START_SCREEN なしでは何もしない
        if ScreenshotMode.isCaptureRun {
            ScreenshotMockSupport.enrichPreviewForCapture(
                context: context,
                baseCards: cards,
                tags: [tagImportant, tagIT, tagClient]
            )
        }
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
        storeLoadMonitor = PersistentStoreLoadMonitor(
            expectedStoreCount: container.persistentStoreDescriptions.count
        )

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
        let loadMonitor = storeLoadMonitor
        let loadedContainer = container
        let shouldScheduleMigrations = !inMemory
        container.loadPersistentStores { _, error in
            let failure = error.map { PersistentStoreLoadFailure(error: $0) }
            if let error = error as NSError? {
                AppLogger.persistence.error(
                    "CoreData の読み込みに失敗しました: \(error), \(error.userInfo)"
                )
            }

            Task { @MainActor in
                let didFinishSuccessfully = loadMonitor.recordCompletion(failure: failure)
                guard didFinishSuccessfully, shouldScheduleMigrations else { return }

                // 読み移行はストア読み込み成功後にだけ開始する。失敗ストアへ fetch しない。
                Self.scheduleReadingMigrations(in: loadedContainer)
            }
        }
        // 別スレッドからの変更を自動マージ（本番ストアのみ）
        // in-memory テストストアでは無効化する。有効にすると Swift Testing の並列実行で
        // 複数の PersistenceController(inMemory: true) が同時に
        // viewContext.automaticallyMergesChangesFromParent = true を呼び出し、
        // 内部の performBlockAndWait がメインスレッドに集中して NSMutableSet の
        // ミューテーションエラー（EXC_CRASH SIGABRT）が発生するため。
        if !inMemory {
            container.viewContext.automaticallyMergesChangesFromParent = true
            // iCloud 同期時の競合解決ポリシー（最後の書き込みが勝つ）
            container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
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
            Task { @MainActor in
                AppLogger.persistence.info("iCloud アカウント状態が変化しました — 次回起動時に同期状態を再確認します")
                Self.verifyCloudKitContainer()
            }
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

    }

    @MainActor
    private static func scheduleReadingMigrations(in container: NSPersistentContainer) {
        let defaults = UserDefaults.standard
        let legalEntityKey = "didMigrateCompanyReadingLegalEntity"
        let latinInitialismKey = "didMigrateCompanyReadingLatinInitialisms"
        let migrateLegalEntity = !defaults.bool(forKey: legalEntityKey)
        let migrateLatinInitialism = !defaults.bool(forKey: latinInitialismKey)
        guard migrateLegalEntity || migrateLatinInitialism else { return }

        readingMigrationTask?.cancel()
        let generation = UUID()
        readingMigrationGeneration = generation
        let coordinatorReference = PersistentStoreCoordinatorReference(
            coordinator: container.persistentStoreCoordinator
        )

        readingMigrationTask = Task { @MainActor in
            let startedAt = ProcessInfo.processInfo.systemUptime
            defer {
                if readingMigrationGeneration == generation {
                    readingMigrationTask = nil
                }
            }

            let result = await CompanyReadingMigrationWorker.shared.migrate(
                coordinatorReference: coordinatorReference,
                migrateLegalEntity: migrateLegalEntity,
                migrateLatinInitialism: migrateLatinInitialism
            )
            guard !Task.isCancelled, readingMigrationGeneration == generation else { return }

            if let failureMessage = result.failureMessage {
                AppLogger.persistence.error("会社名読みの移行保存に失敗しました: \(failureMessage)")
                return
            }
            // 完了フラグはbackground contextの保存成功後にだけ記録する。
            if result.completedLegalEntity {
                defaults.set(true, forKey: legalEntityKey)
            }
            if result.completedLatinInitialism {
                defaults.set(true, forKey: latinInitialismKey)
            }

            let elapsedMilliseconds = Int(
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            )
            AppLogger.performance.info(
                "会社名読み移行が完了しました: changed=\(result.changedCount) \(elapsedMilliseconds)ms"
            )
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

}

nonisolated struct CompanyReadingMigrationResult: Sendable {
    let completedLegalEntity: Bool
    let completedLatinInitialism: Bool
    let changedCount: Int
    let failureMessage: String?
}

/// 起動後の全件移行をUIのMainActorから分離する。
/// NSManagedObjectはactor境界を越えず、private context内でKVC値だけを処理する。
actor CompanyReadingMigrationWorker {
    static let shared = CompanyReadingMigrationWorker()

    func migrate(
        coordinatorReference: PersistentStoreCoordinatorReference,
        migrateLegalEntity: Bool,
        migrateLatinInitialism: Bool
    ) async -> CompanyReadingMigrationResult {
        guard !Task.isCancelled else {
            return cancelledResult()
        }

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinatorReference.coordinator
        context.undoManager = nil
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump

        do {
            return try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: "BusinessCard")
                request.fetchBatchSize = 100
                let cards = try context.fetch(request)
                var changedCount = 0

                for card in cards {
                    if Task.isCancelled {
                        context.rollback()
                        return self.cancelledResult()
                    }

                    let originalReading = card.value(forKey: "companyReading") as? String ?? ""
                    guard !originalReading.isEmpty else { continue }
                    var reading = originalReading

                    if migrateLegalEntity {
                        reading = LegalEntityTerms.stripReading(from: reading)
                    }

                    if migrateLatinInitialism,
                       let company = card.value(forKey: "company") as? String,
                       company.contains(where: { $0.isASCII && $0.isLetter }) {
                        let legacyReading = LegalEntityTerms.stripReading(
                            from: NameReadingGenerator.generateReading(from: company)
                        )
                        let revisedReading = LegalEntityTerms.stripReading(
                            from: NameReadingGenerator.generateCompanyReading(from: company)
                        )
                        if !revisedReading.isEmpty,
                           reading == legacyReading,
                           reading != revisedReading {
                            reading = revisedReading
                        }
                    }

                    guard reading != originalReading else { continue }
                    card.setValue(reading, forKey: "companyReading")
                    changedCount += 1
                }

                if context.hasChanges {
                    try context.save()
                }
                return CompanyReadingMigrationResult(
                    completedLegalEntity: migrateLegalEntity,
                    completedLatinInitialism: migrateLatinInitialism,
                    changedCount: changedCount,
                    failureMessage: nil
                )
            }
        } catch {
            await context.perform {
                context.rollback()
            }
            return CompanyReadingMigrationResult(
                completedLegalEntity: false,
                completedLatinInitialism: false,
                changedCount: 0,
                failureMessage: String(describing: error)
            )
        }
    }

    private nonisolated func cancelledResult() -> CompanyReadingMigrationResult {
        CompanyReadingMigrationResult(
            completedLegalEntity: false,
            completedLatinInitialism: false,
            changedCount: 0,
            failureMessage: nil
        )
    }
}

// MARK: - Grandfather 判定用ヘルパー

extension PersistenceController {
    /// BusinessCard の件数を軽量に取得する（Grandfather フォールバック判定で利用）。
    /// 失敗時は 0 を返し、判定側は「既存ユーザー痕跡なし」として振る舞う。
    @MainActor
    func businessCardCount() -> Int {
        let request = BusinessCard.fetchRequest()
        return (try? container.viewContext.count(for: request)) ?? 0
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
