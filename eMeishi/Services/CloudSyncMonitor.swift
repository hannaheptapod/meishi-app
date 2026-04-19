import Combine
import CoreData

// iCloud 同期状態を監視し、最終同期日時と進行中フラグを提供するサービス
@MainActor
final class CloudSyncMonitor: ObservableObject {

    static let shared = CloudSyncMonitor()

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastSyncFailed = false

    private static let lastSyncKey = "lastCloudKitSyncDate"
    private var fallbackTask: Task<Void, Never>?

    private init() {
        let ti = UserDefaults.standard.double(forKey: Self.lastSyncKey)
        lastSyncDate = ti > 0 ? Date(timeIntervalSinceReferenceDate: ti) : nil

        guard PersistenceController.shared.iCloudSyncEnabled else { return }
        startObserving()
    }

    private func startObserving() {
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: PersistenceController.shared.container,
            queue: nil
        ) { @Sendable notification in
            // Notification は Sendable でないため、Sendable な値だけ抽出してから MainActor へ渡す
            let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event
            let endDate: Date? = event?.endDate
            let failed: Bool = event?.error != nil
            Task { @MainActor in
                CloudSyncMonitor.shared.handleEvent(endDate: endDate, failed: failed)
            }
        }
    }

    private func handleEvent(endDate: Date?, failed: Bool) {
        if endDate == nil {
            isSyncing = true
        } else {
            fallbackTask?.cancel()
            isSyncing = false
            if let end = endDate, !failed {
                lastSyncDate = end
                lastSyncFailed = false
                UserDefaults.standard.set(end.timeIntervalSinceReferenceDate, forKey: Self.lastSyncKey)
            } else if failed {
                lastSyncFailed = true
            }
        }
    }

    /// ローカル変更を即時 save して CloudKit エクスポートをトリガーする。
    /// 変更がない場合もスピナーを短時間表示して「確認した」感を与える。
    func triggerSync() {
        let context = PersistenceController.shared.container.viewContext
        if context.hasChanges {
            try? context.save()
        }
        isSyncing = true
        fallbackTask?.cancel()
        fallbackTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if isSyncing { isSyncing = false }
        }
    }
}
