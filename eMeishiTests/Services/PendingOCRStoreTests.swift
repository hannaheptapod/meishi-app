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
        let queueID = UUID()

        try await store.persist([first, second], queueID: queueID)
        var restored = try #require(try await store.restore())
        #expect(restored.id == queueID)
        #expect(restored.inputs.map(\.id) == [first.id, second.id])
        #expect(restored.inputs.map(\.data) == [first.data, second.data])
        #expect(restored.processedCount == 0)
        #expect(restored.totalCount == 2)

        #expect(try await store.advance(queueID: queueID, expectedInputID: first.id) == 1)
        restored = try #require(try await store.restore())
        #expect(restored.inputs.map(\.id) == [second.id])
        #expect(restored.processedCount == 1)
        #expect(restored.totalCount == 2)

        #expect(try await store.advance(queueID: queueID, expectedInputID: second.id) == 0)
        restored = try #require(try await store.restore())
        #expect(restored.inputs.isEmpty)
        #expect(restored.processedCount == 2)
    }

    @Test
    func removeFirstUpdatesManifestWithoutRewritingRemainingImages() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("PendingOCRManifestTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        let store = PendingOCRStore(baseDirectory: base)
        let inputs = [
            CardImageInput(data: Data(repeating: 0x11, count: 32), source: .camera),
            CardImageInput(data: Data(repeating: 0x22, count: 48), source: .photoLibrary),
            CardImageInput(data: Data(repeating: 0x33, count: 64), source: .camera)
        ]

        let queueID = UUID()
        try await store.persist(inputs, queueID: queueID)
        let target = base.appendingPathComponent("PendingOCR", isDirectory: true)
        let manifestURL = target.appendingPathComponent("manifest.json")
        let before = try JSONDecoder().decode(
            PendingOCRStore.Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let remainingBefore = try before.entries.dropFirst().map { entry in
            let url = target.appendingPathComponent(entry.fileName)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return (
                entry: entry,
                data: try Data(contentsOf: url),
                fileNumber: attributes[.systemFileNumber] as? NSNumber
            )
        }

        #expect(try await store.advance(queueID: queueID, expectedInputID: inputs[0].id) == 2)

        let after = try JSONDecoder().decode(
            PendingOCRStore.Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        #expect(after.entries.map(\.id) == Array(before.entries.dropFirst()).map(\.id))
        #expect(after.entries.map(\.fileName) == Array(before.entries.dropFirst()).map(\.fileName))

        let removedURL = target.appendingPathComponent(before.entries[0].fileName)
        #expect(!fileManager.fileExists(atPath: removedURL.path))
        for state in remainingBefore {
            let url = target.appendingPathComponent(state.entry.fileName)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            #expect(try Data(contentsOf: url) == state.data)
            #expect(attributes[.systemFileNumber] as? NSNumber == state.fileNumber)
        }

        let restored = try #require(try await store.restore())
        #expect(restored.inputs.map(\.id) == Array(inputs.dropFirst()).map(\.id))
        #expect(restored.inputs.map(\.data) == Array(inputs.dropFirst()).map(\.data))
    }

    @Test
    func removingLastEntryCommitsEmptyManifestWithoutReplayingBackup() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("PendingOCREmptyManifestTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: base) }
        let store = PendingOCRStore(baseDirectory: base)
        let input = CardImageInput(data: Data(repeating: 0x44, count: 24), source: .photoLibrary)

        let queueID = UUID()
        try await store.persist([input], queueID: queueID)
        #expect(try await store.advance(queueID: queueID, expectedInputID: input.id) == 0)

        let target = base.appendingPathComponent("PendingOCR", isDirectory: true)
        let manifest = try JSONDecoder().decode(
            PendingOCRStore.Manifest.self,
            from: Data(contentsOf: target.appendingPathComponent("manifest.json"))
        )
        #expect(manifest.entries.isEmpty)
        let restored = try #require(try await store.restore())
        #expect(restored.inputs.isEmpty)
        #expect(!fileManager.fileExists(
            atPath: base.appendingPathComponent("PendingOCR.backup", isDirectory: true).path
        ))
    }

    @Test
    func corruptedTargetRecoversLastCompleteBackup() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("PendingOCRRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let store = PendingOCRStore(baseDirectory: base)
        let input = CardImageInput(data: Data([9, 8, 7]), source: .photoLibrary)
        let queueID = UUID()
        try await store.persist([input], queueID: queueID)

        let target = base.appendingPathComponent("PendingOCR", isDirectory: true)
        let backup = base.appendingPathComponent("PendingOCR.backup", isDirectory: true)
        try fm.moveItem(at: target, to: backup)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: target.appendingPathComponent("manifest.json"))

        let restored = try #require(try await store.restore())
        #expect(restored.inputs.count == 1)
        #expect(restored.inputs.first?.id == input.id)
        #expect(restored.inputs.first?.data == input.data)
    }

    @Test
    func staleQueueOperationsCannotMutateReplacementQueue() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingOCRGenerationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = PendingOCRStore(baseDirectory: base)
        let firstQueueID = UUID()
        let secondQueueID = UUID()
        let first = CardImageInput(data: Data([0x11]), source: .camera)
        let second = CardImageInput(data: Data([0x22]), source: .photoLibrary)

        try await store.persist([first], queueID: firstQueueID)
        try await store.persist([second], queueID: secondQueueID)

        try await store.discard(queueID: firstQueueID)
        var restored = try #require(try await store.restore())
        #expect(restored.id == secondQueueID)
        #expect(restored.inputs.map(\.id) == [second.id])

        await #expect(throws: PendingOCRStore.StoreError.self) {
            try await store.advance(queueID: firstQueueID, expectedInputID: first.id)
        }
        await #expect(throws: PendingOCRStore.StoreError.self) {
            try await store.advance(queueID: secondQueueID, expectedInputID: first.id)
        }

        restored = try #require(try await store.restore())
        #expect(restored.id == secondQueueID)
        #expect(restored.inputs.map(\.id) == [second.id])
    }

    @Test
    func matchingDiscardRemovesQueue() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingOCRDiscardTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = PendingOCRStore(baseDirectory: base)
        let queueID = UUID()
        let input = CardImageInput(data: Data([0x31, 0x32]), source: .camera)

        try await store.persist([input], queueID: queueID)
        try await store.discard(queueID: queueID)

        let restored = try await store.restore()
        #expect(restored?.id == nil)
    }
}
