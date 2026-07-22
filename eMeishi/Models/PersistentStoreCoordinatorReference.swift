import CoreData

/// `NSPersistentStoreCoordinator` は複数の管理オブジェクトコンテキストからの利用を
/// 前提とする一方、Swift の `Sendable` 注釈を持たない。MainActor から actor へ
/// coordinator を受け渡す境界だけを、この不変参照で明示する。
nonisolated struct PersistentStoreCoordinatorReference: @unchecked Sendable {
    let coordinator: NSPersistentStoreCoordinator
}
