import SwiftUI
import CoreData

@main
struct EMeishiApp: App {

    // CoreData スタック（UIテスト時はインメモリ＋サンプルデータ）
    let persistenceController: PersistenceController

    @Environment(\.scenePhase) private var scenePhase
    @State private var isUnlocked: Bool
    @State private var backgroundedAt: Date?
    @State private var showPrivacyOverlay = false

    private let isUITest = ProcessInfo.processInfo.arguments.contains("-UITestMode")
    private let settings = SettingsStore.shared

    init() {
        let uiTest = ProcessInfo.processInfo.arguments.contains("-UITestMode")
        if uiTest {
            persistenceController = PersistenceController.preview
        } else {
            persistenceController = PersistenceController.shared
        }
        // UIテスト時はロック不要、ロック無効時も解除済みで起動
        _isUnlocked = State(initialValue: uiTest || !SettingsStore.shared.isAppLockEnabled)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)

                // App Switcher プライバシーオーバーレイ
                if showPrivacyOverlay {
                    PrivacyOverlayView()
                        .transition(.opacity)
                }

                // ロック画面（設定有効かつ未認証時）
                if !isUnlocked && settings.isAppLockEnabled && !isUITest {
                    LockScreenView(isUnlocked: $isUnlocked)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: isUnlocked)
            .animation(.easeOut(duration: 0.15), value: showPrivacyOverlay)
            .onChange(of: scenePhase) { oldPhase, newPhase in
                handleScenePhaseChange(from: oldPhase, to: newPhase)
            }
        }
    }

    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        guard !isUITest else { return }

        switch newPhase {
        case .inactive:
            // iOS は inactive でスナップショットを取得するため、ここでオーバーレイ表示
            if settings.isAppLockEnabled {
                showPrivacyOverlay = true
            }
        case .background:
            backgroundedAt = Date()
        case .active:
            showPrivacyOverlay = false
            if settings.isAppLockEnabled, let bgDate = backgroundedAt {
                let elapsed = Date().timeIntervalSince(bgDate)
                if elapsed >= Double(settings.lockGracePeriodSeconds) {
                    isUnlocked = false
                }
            }
            backgroundedAt = nil
        @unknown default:
            break
        }
    }
}
