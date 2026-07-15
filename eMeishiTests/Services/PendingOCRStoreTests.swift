import Foundation
import Testing
@testable import eMeishi

struct PendingOCRStoreTests {
    @Test
    func persistRestoreAndRemoveFirstPreserveOrder() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingOCRStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = PendingOCRStore(baseDirectory: base)
        let first = CardImageInput(data: Data([1, 2, 3]), source: .camera)
        let second = CardImageInput(data: Data([4, 5, 6]), source: .photoLibrary)

        try await store.persist([first, second])
        var restored = try await store.restore()
        #expect(restored.map(\.id) == [first.id, second.id])
        #expect(restored.map(\.data) == [first.data, second.data])

        #expect(try await store.removeFirst() == 1)
        restored = try await store.restore()
        #expect(restored.map(\.id) == [second.id])

        #expect(try await store.removeFirst() == 0)
        #expect(try await store.restore().isEmpty)
    }

    @Test
    func corruptedTargetRecoversLastCompleteBackup() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("PendingOCRRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let store = PendingOCRStore(baseDirectory: base)
        let input = CardImageInput(data: Data([9, 8, 7]), source: .photoLibrary)
        try await store.persist([input])

        let target = base.appendingPathComponent("PendingOCR", isDirectory: true)
        let backup = base.appendingPathComponent("PendingOCR.backup", isDirectory: true)
        try fm.moveItem(at: target, to: backup)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: target.appendingPathComponent("manifest.json"))

        let restored = try await store.restore()
        #expect(restored.count == 1)
        #expect(restored.first?.id == input.id)
        #expect(restored.first?.data == input.data)
    }
}
