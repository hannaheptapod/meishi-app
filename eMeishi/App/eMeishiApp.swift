import SwiftUI
import CoreData
#if canImport(FoundationModels)
import FoundationModels
#endif

@main
struct EMeishiApp: App {

    // CoreData スタック（UIテスト時はインメモリ＋サンプルデータ）
    let persistenceController: PersistenceController

    @Environment(\.scenePhase) private var scenePhase
    @State private var isUnlocked: Bool
    @State private var backgroundedAt: Date?
    @State private var showPrivacyOverlay = false
    @State private var showQwenDownloadPrompt = false
    @State private var showCoreDataError = false
    @State private var showGrandfatheredAnnouncement = false

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
                rootView
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
                    .environmentObject(EntitlementStore.shared)

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
            .task {
                guard !isUITest else { return }
                // 起動時に初期化して、設定画面を開く前から同期イベントを記録する
                if PersistenceController.shared.iCloudSyncEnabled {
                    _ = CloudSyncMonitor.shared
                }
                await startBillingServices()
                checkAndPromptQwenDownload()
                checkAndShowGrandfatheredAnnouncement()
            }
            .alert("データベースエラー", isPresented: $showCoreDataError) {
                Button("OK") {}
            } message: {
                Text("データの読み込みに失敗しました。アプリを再起動してください。問題が続く場合は、端末のストレージ空き容量を確認してください。")
            }
            .onAppear {
                if persistenceController.loadError != nil {
                    showCoreDataError = true
                }
            }
            .alert("eMeishi Pro が登場しました", isPresented: $showGrandfatheredAnnouncement) {
                Button("OK") {}
            } message: {
                Text("既存ユーザーには、AI 自然言語検索を引き続き無料でご利用いただけます。新しい Pro 機能は設定画面からご確認ください。")
            }
            .alert("AIモデルをダウンロードしますか？", isPresented: $showQwenDownloadPrompt) {
                Button("ダウンロード（約570MB）") {
                    Task { try? await LocalLLMService.shared.downloadModel() }
                }
                Button("あとで", role: .cancel) {}
            } message: {
                Text("この端末はApple Intelligenceに対応していないため、名刺の読み取り精度を向上させるAIモデルをダウンロードできます。Wi-Fi環境でのダウンロードを推奨します。")
            }
        }
    }

    /// スクリーンショット撮影モード：Insights / Duplicate は通常 NavigationLink で push される画面のため、
    /// ScreenshotHostView 経由で単独ルートとして表示する。それ以外は通常 ContentView。
    @ViewBuilder
    private var rootView: some View {
        if isUITest,
           let screen = ScreenshotMode.startScreen,
           screen == "Insights" || screen == "Duplicate" {
            ScreenshotHostView(screen: screen)
        } else {
            ContentView()
        }
    }

    private func startBillingServices() async {
        await GrandfatherStore.shared.evaluate()
        EntitlementStore.shared.setup(isGrandfathered: GrandfatherStore.shared.isGrandfathered)
        StoreService.shared.startTransactionListener()
        await EntitlementStore.shared.refresh()
        await StoreService.shared.prefetch()
    }

    /// Grandfather ユーザーへの Pro リリース初回告知
    private func checkAndShowGrandfatheredAnnouncement() {
        guard GrandfatherStore.shared.isGrandfathered,
              !settings.didShowProAnnouncement else { return }
        settings.didShowProAnnouncement = true
        showGrandfatheredAnnouncement = true
    }

    /// Foundation Models 非対応端末で初回起動時に Qwen ダウンロードを促す
    private func checkAndPromptQwenDownload() {
        // 既にプロンプト表示済み、またはモデルDL済みならスキップ
        guard !settings.hasPromptedInitialQwenDownload,
              !LocalLLMService.shared.isModelAvailable else { return }

        // Foundation Models が利用可能な端末はスキップ
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return
            }
        }
        #endif

        // 初回のみプロンプトを表示
        settings.hasPromptedInitialQwenDownload = true
        showQwenDownloadPrompt = true
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
