import SwiftUI
import CoreData
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

@main
struct EMeishiApp: App {

    // CoreData スタック（UIテスト時はインメモリ＋サンプルデータ）
    let persistenceController: PersistenceController
    @StateObject private var storeLoadMonitor: PersistentStoreLoadMonitor

    @Environment(\.scenePhase) private var scenePhase
    @State private var isUnlocked: Bool
    @State private var backgroundedAt: Date?
    @State private var showPrivacyOverlay = false
    @State private var protectionRenderGeneration = UUID()
    @State private var renderedProtectionGeneration: UUID?
    @State private var didStartServices = false

    private let isUITest = ProcessInfo.processInfo.arguments.contains("-UITestMode")
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var rootPresentationRequests = AppRootPresentationRequests()

    init() {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let uiTest = ProcessInfo.processInfo.arguments.contains("-UITestMode")
        let controller = uiTest ? PersistenceController.preview : PersistenceController.shared
        persistenceController = controller
        _storeLoadMonitor = StateObject(wrappedValue: controller.storeLoadMonitor)
        // UIテスト時はロック不要、ロック無効時も解除済みで起動
        _isUnlocked = State(initialValue: uiTest || !SettingsStore.shared.isAppLockEnabled)

        let elapsedMilliseconds = Int(
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        )
        AppLogger.performance.info(
            "ルートUI生成前のアプリ初期化が完了しました: \(elapsedMilliseconds)ms"
        )
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                rootView
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
                    .environmentObject(EntitlementStore.shared)
                    .environmentObject(rootPresentationRequests)

                AppProtectionOverlay(
                    isUnlocked: $isUnlocked,
                    showPrivacyOverlay: showPrivacyOverlay,
                    isLockEnabled: settings.isAppLockEnabled,
                    isUITest: isUITest,
                    renderGeneration: protectionRenderGeneration,
                    onRendered: markProtectionOverlayRendered
                )
            }
            // SwiftUI階層のoverlayではsystem sheet / alertを覆えないため、
            // inactive中のスナップショット保護はscene専用の高windowLevelへ委譲する。
            .privacyShieldWindow(
                isEnabled: settings.isAppLockEnabled && !isUITest,
                isContentReadyToReveal: scenePhase == .active
                    && !showPrivacyOverlay
                    && renderedProtectionGeneration == protectionRenderGeneration
            )
            .onChange(of: scenePhase) { oldPhase, newPhase in
                handleScenePhaseChange(from: oldPhase, to: newPhase)
            }
            .task(id: storeLoadMonitor.state) {
                guard storeLoadMonitor.state == .loaded,
                      !isUITest,
                      !didStartServices else { return }
                didStartServices = true
                // 起動時に初期化して、設定画面を開く前から同期イベントを記録する
                if PersistenceController.shared.iCloudSyncEnabled {
                    _ = CloudSyncMonitor.shared
                }
                await startBillingServices()
                checkAndPromptQwenDownload()
                checkAndShowGrandfatheredAnnouncement()
            }
        }
    }

    /// スクリーンショット撮影モード：重複確認だけは一覧の実データ状態に依存するため、
    /// ScreenshotHostView経由で単独表示する。タブ画面はContentViewが直接選択する。
    @ViewBuilder
    private var rootView: some View {
        switch storeLoadMonitor.state {
        case .loading:
            PersistentStoreLoadingView()
        case .failed:
            PersistentStoreFailureView()
        case .loaded:
            if isUITest,
               let screen = ScreenshotMode.startScreen,
               screen == "Duplicate" {
                ScreenshotHostView(screen: screen)
            } else {
                ContentView()
            }
        }
    }

    private func startBillingServices() async {
        await GrandfatherStore.shared.evaluate()
        // CloudKit 上の GrandfatherMark で 2 台目デバイスでも確実に Grandfather を引き継ぐ
        await GrandfatherStore.shared.syncWithCloudKit()
        EntitlementStore.shared.setup(isGrandfathered: GrandfatherStore.shared.isGrandfathered)
        observeCloudKitSyncForGrandfatherRecheck()
        StoreService.shared.startTransactionListener()
        await EntitlementStore.shared.refresh()
        await StoreService.shared.prefetch()
    }

    /// 2 台目デバイス初回起動で CoreData の iCloud 同期が evaluate() より遅れた場合の救済。
    /// 既に Grandfather 判定済みなら登録不要。
    private func observeCloudKitSyncForGrandfatherRecheck() {
        guard !GrandfatherStore.shared.isGrandfathered,
              PersistenceController.shared.iCloudSyncEnabled else { return }

        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: PersistenceController.shared.container,
            queue: nil
        ) { @Sendable notification in
            let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event
            // 完了イベントかつエラーなしのみ対象
            guard let event,
                  event.endDate != nil,
                  event.error == nil else { return }
            Task { @MainActor in
                if GrandfatherStore.shared.reevaluateAfterSync() {
                    EntitlementStore.shared.setup(isGrandfathered: true)
                }
            }
        }
    }

    /// Grandfather ユーザーへの Pro リリース初回告知
    private func checkAndShowGrandfatheredAnnouncement() {
        guard GrandfatherStore.shared.isGrandfathered,
              !settings.didShowProAnnouncement else { return }
        settings.didShowProAnnouncement = true
        rootPresentationRequests.enqueue(.grandfatheredAnnouncement)
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
        rootPresentationRequests.enqueue(.qwenDownloadPrompt)
    }

    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        guard !isUITest else { return }

        switch newPhase {
        case .inactive:
            // iOS は inactive でスナップショットを取得するため、ここでオーバーレイ表示
            if settings.isAppLockEnabled {
                showPrivacyOverlay = true
            }
            renderedProtectionGeneration = nil
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
            renderedProtectionGeneration = nil
            protectionRenderGeneration = UUID()
        @unknown default:
            break
        }
    }

    private func markProtectionOverlayRendered(generation: UUID) {
        guard generation == protectionRenderGeneration else { return }
        renderedProtectionGeneration = generation
    }
}

private struct PersistentStoreLoadingView: View {
    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            ProgressView("データを読み込んでいます")
        }
    }
}

private struct PersistentStoreFailureView: View {
    var body: some View {
        ContentUnavailableView(
            "データを開けません",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text("アプリを再起動してください。問題が続く場合は端末の空き容量を確認してください。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background.ignoresSafeArea())
    }
}

/// 保護UIは機密内容の露出を避けるため即時に切り替える。
/// scene専用遮蔽ウィンドウは、このViewの更新後にだけ非表示になる。
private struct AppProtectionOverlay: View {
    @Binding var isUnlocked: Bool
    let showPrivacyOverlay: Bool
    let isLockEnabled: Bool
    let isUITest: Bool
    let renderGeneration: UUID
    let onRendered: (UUID) -> Void

    var body: some View {
        ZStack {
            if showPrivacyOverlay {
                PrivacyOverlayView()
            }

            if !isUnlocked && isLockEnabled && !isUITest {
                LockScreenView(isUnlocked: $isUnlocked)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .allowsHitTesting(showPrivacyOverlay || (!isUnlocked && isLockEnabled && !isUITest))
        .background {
            PrivacyRevealReadinessProbe(
                generation: renderGeneration,
                onRendered: onRendered
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
