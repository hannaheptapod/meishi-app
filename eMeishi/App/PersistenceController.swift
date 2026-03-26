import CoreData

// CoreData スタックの管理
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

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "BusinessCard")
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
        }
        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("CoreData の読み込みに失敗しました: \(error), \(error.userInfo)")
            }
        }
        // 別スレッドからの変更を自動マージ
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}
