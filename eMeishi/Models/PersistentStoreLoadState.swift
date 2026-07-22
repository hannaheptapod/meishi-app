import Combine
import Foundation

/// Core Data ストアの読み込み失敗を actor 境界越しに安全に渡すための値型。
nonisolated struct PersistentStoreLoadFailure: Equatable, Sendable {
    let domain: String
    let code: Int
    let description: String

    init(error: Error) {
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        description = nsError.localizedDescription
    }
}

nonisolated enum PersistentStoreLoadState: Equatable, Sendable {
    case loading
    case loaded
    case failed(PersistentStoreLoadFailure)
}

/// 非同期の `loadPersistentStores` と SwiftUI の起動状態を接続する。
/// 複数ストア構成でも、全 description の完了を待ってから終端状態へ遷移する。
@MainActor
final class PersistentStoreLoadMonitor: ObservableObject {
    @Published private(set) var state: PersistentStoreLoadState = .loading

    private var remainingStoreCount: Int
    private var firstFailure: PersistentStoreLoadFailure?
    private var waiters: [CheckedContinuation<PersistentStoreLoadState, Never>] = []

    init(expectedStoreCount: Int) {
        remainingStoreCount = max(expectedStoreCount, 1)
    }

    /// 1ストア分の完了を記録する。全ストア成功へ初めて遷移した場合だけ true を返す。
    @discardableResult
    func recordCompletion(failure: PersistentStoreLoadFailure?) -> Bool {
        guard state == .loading else { return false }

        if firstFailure == nil {
            firstFailure = failure
        }
        remainingStoreCount = max(remainingStoreCount - 1, 0)
        guard remainingStoreCount == 0 else { return false }

        if let firstFailure {
            finish(with: .failed(firstFailure))
            return false
        }

        finish(with: .loaded)
        return true
    }

    func waitUntilFinished() async -> PersistentStoreLoadState {
        guard state == .loading else { return state }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func finish(with finalState: PersistentStoreLoadState) {
        state = finalState
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume(returning: finalState) }
    }
}
