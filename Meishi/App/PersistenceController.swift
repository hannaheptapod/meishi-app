import CoreData

// CoreData スタックの管理
struct PersistenceController {

    // アプリ全体で共有するシングルトン
    static let shared = PersistenceController()

    // PreviewやテストでもアクセスできるようにPreview用インスタンスを用意
    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        // プレビュー用のサンプルデータを1件追加
        let sample = BusinessCard(context: context)
        sample.id = UUID()
        sample.name = "山田 太郎"
        sample.company = "株式会社サンプル"
        sample.title = "営業部長"
        sample.email = "yamada@example.com"
        sample.phone = "03-1234-5678"
        sample.createdAt = Date()
        sample.updatedAt = Date()
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
        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("CoreData の読み込みに失敗しました: \(error), \(error.userInfo)")
            }
        }
        // 別スレッドからの変更を自動マージ
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}
