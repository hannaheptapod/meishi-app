import SwiftUI
import CoreData

@main
struct EMeishiApp: App {

    // CoreData スタック（UIテスト時はインメモリ＋サンプルデータ）
    let persistenceController: PersistenceController

    init() {
        if ProcessInfo.processInfo.arguments.contains("-UITestMode") {
            persistenceController = PersistenceController.preview
        } else {
            persistenceController = PersistenceController.shared
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
