import BackgroundTasks
import Foundation
import os

/// BGContinuedProcessingTask の要求と終了状態をOCRジョブ単位で保持する。
@MainActor
final class OCRBackgroundSession {
    let jobID: OCRJobID
    let requestIdentifier: String
    let cancellationHandler: @MainActor () -> Void
    var activeTask: BGContinuedProcessingTask?
    private(set) var isFinished = false

    init(
        jobID: OCRJobID,
        requestIdentifier: String,
        cancellationHandler: @escaping @MainActor () -> Void
    ) {
        self.jobID = jobID
        self.requestIdentifier = requestIdentifier
        self.cancellationHandler = cancellationHandler
    }

    func markFinished() -> Bool {
        guard !isFinished else { return false }
        isFinished = true
        return true
    }
}

/// BGContinuedProcessingTask のシステムLive ActivityとOCR状態を同期する。
@MainActor
final class OCRBackgroundTaskManager {
    static let shared = OCRBackgroundTaskManager()
    nonisolated static let permittedIdentifier = "com.jinks.emeishi.ocr.*"

    nonisolated static func taskIdentifier(jobID: OCRJobID) -> String {
        "com.jinks.emeishi.ocr.\(jobID.rawValue.uuidString)"
    }

    private var sessions: [OCRJobID: OCRBackgroundSession] = [:]

    private init() {}

    /// Continued Processing Taskはジョブ固有IDと完全一致するhandlerが必要。
    private func register(identifier: String, jobID: OCRJobID) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { task in
            Task { @MainActor in
                OCRBackgroundTaskManager.shared.handle(task, jobID: jobID)
            }
        }
    }

    /// 受付不可の場合はfalse。OCR自体は呼出し側でフォアグラウンド継続する。
    func begin(
        jobID: OCRJobID,
        totalItems: Int,
        onCancellation: @escaping @MainActor () -> Void
    ) -> Bool {
        let identifier = Self.taskIdentifier(jobID: jobID)
        guard register(identifier: identifier, jobID: jobID) else {
            AppLogger.ocr.info("バックグラウンドOCR handlerを登録できないためアプリ内で継続")
            return false
        }

        let session = OCRBackgroundSession(
            jobID: jobID,
            requestIdentifier: identifier,
            cancellationHandler: onCancellation
        )
        sessions[jobID] = session

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "名刺を読み取り中",
            subtitle: "0 / \(max(1, totalItems))枚"
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            sessions[jobID] = nil
            AppLogger.ocr.info("バックグラウンドOCRは利用不可。アプリ内で継続: \(error)")
            return false
        }
    }

    func update(jobID: OCRJobID, state: OCRProcessingState) {
        guard let session = sessions[jobID], !session.isFinished,
              let task = session.activeTask else { return }
        task.progress.totalUnitCount = 1_000
        task.progress.completedUnitCount = Int64((state.progress * 1_000).rounded())
        let count = "\(state.completedItems) / \(max(1, state.totalItems))枚"
        let subtitle = [state.phase.title, state.remainingTimeText, count]
            .compactMap { $0 }
            .joined(separator: " ・ ")
        task.updateTitle("名刺を読み取り中", subtitle: subtitle)
    }

    /// どの終了経路から呼ばれても、対象ジョブのLive Activityを一度だけ終了する。
    func finish(jobID: OCRJobID, success: Bool) {
        guard let session = sessions[jobID], session.markFinished() else { return }
        if let task = session.activeTask {
            task.progress.completedUnitCount = success ? 1_000 : task.progress.completedUnitCount
            task.setTaskCompleted(success: success)
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: session.requestIdentifier)
        }
        sessions[jobID] = nil
    }

    private func handle(_ task: BGTask, jobID: OCRJobID) {
        guard let continuedTask = task as? BGContinuedProcessingTask,
              let session = sessions[jobID], !session.isFinished,
              continuedTask.identifier == session.requestIdentifier else {
            task.setTaskCompleted(success: false)
            return
        }

        session.activeTask = continuedTask
        continuedTask.progress.totalUnitCount = 1_000
        continuedTask.expirationHandler = {
            Task { @MainActor in
                guard let activeSession = OCRBackgroundTaskManager.shared.sessions[jobID],
                      activeSession.requestIdentifier == continuedTask.identifier else { return }
                OCRBackgroundTaskManager.shared.finish(jobID: jobID, success: false)
                activeSession.cancellationHandler()
                _ = await OCRProcessingCoordinator.shared.cancel(jobID: jobID)
            }
        }
        Task {
            if let state = await OCRProcessingCoordinator.shared.currentState(jobID: jobID) {
                update(jobID: jobID, state: state)
            }
        }
    }
}
