import SwiftUI
import CoreData

@main
struct eMeishiApp: App {

    // CoreData スタック
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
