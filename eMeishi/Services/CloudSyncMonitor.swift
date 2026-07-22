import Combine
import CoreData

/// CloudKit は setup / import / export を並行して通知するため、単一 Bool ではなく
/// event ID ごとの開始・終了を集約する。1件の終了で別イベントの同期表示を消さない。
nonisolated struct CloudSyncActivityState: Equatable, Sendable {
    private(set) var activeEventIDs: Set<UUID> = []
    private(set) var lastSuccessDate: Date?
    private(set) var lastEventFailed = false

    init(lastSuccessDate: Date? = nil) {
        self.lastSuccessDate = lastSuccessDate
    }

    var isSyncing: Bool { !activeEventIDs.isEmpty }

    mutating func apply(identifier: UUID, endDate: Date?, failed: Bool) {
        guard let endDate else {
            activeEventIDs.insert(identifier)
            return
        }

        activeEventIDs.remove(identifier)
        lastEventFailed = failed
        if !failed {
            lastSuccessDate = endDate
        }
    }
}

// iCloud 同期状態を監視し、最終同期日時と進行中フラグを提供するサービス
@MainActor
final class CloudSyncMonitor: ObservableObject {

    static let shared = CloudSyncMonitor()

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastSyncFailed = false

    private static let lastSyncKey = "lastCloudKitSyncDate"
    private var activityState: CloudSyncActivityState

    private init() {
        let ti = UserDefaults.standard.double(forKey: Self.lastSyncKey)
        let persistedDate = ti > 0 ? Date(timeIntervalSinceReferenceDate: ti) : nil
        lastSyncDate = persistedDate
        activityState = CloudSyncActivityState(lastSuccessDate: persistedDate)

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
            let identifier: UUID? = event?.identifier
            let endDate: Date? = event?.endDate
            let failed: Bool = event?.error != nil
            guard let identifier else { return }
            Task { @MainActor in
                CloudSyncMonitor.shared.handleEvent(
                    identifier: identifier,
                    endDate: endDate,
                    failed: failed
                )
            }
        }
    }

    private func handleEvent(identifier: UUID, endDate: Date?, failed: Bool) {
        activityState.apply(identifier: identifier, endDate: endDate, failed: failed)
        isSyncing = activityState.isSyncing
        lastSyncFailed = activityState.lastEventFailed

        if let successDate = activityState.lastSuccessDate,
           successDate != lastSyncDate {
            lastSyncDate = successDate
            UserDefaults.standard.set(
                successDate.timeIntervalSinceReferenceDate,
                forKey: Self.lastSyncKey
            )
        }
    }

}
