import Foundation

/// Viewが開始した非同期操作のうち、現在の1件だけにUI更新を許可する。
///
/// Task参照だけでは、キャンセルを無視するAPIの遅延完了や、画面再表示後の
/// 新しいTaskとの取り違えを防げないため、操作IDも併せて照合する。
nonisolated struct SecondaryViewTaskGate: Equatable, Sendable {
    private(set) var currentID: UUID?

    mutating func begin() -> UUID? {
        guard currentID == nil else { return nil }
        let id = UUID()
        currentID = id
        return id
    }

    func accepts(_ id: UUID) -> Bool {
        currentID == id
    }

    @discardableResult
    mutating func finish(_ id: UUID) -> Bool {
        guard accepts(id) else { return false }
        currentID = nil
        return true
    }

    mutating func cancel() {
        currentID = nil
    }
}
