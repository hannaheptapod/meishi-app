import Foundation

/// 未完了OCRキューを、画像一式とmanifestが揃った単位で原子的に置換する。
/// すべての更新でqueueIDを照合し、古いTaskが新しいキューを変更しないようにする。
actor PendingOCRStore {
    static let shared = PendingOCRStore()

    struct Queue: Sendable {
        let id: UUID
        let inputs: [CardImageInput]
        let processedCount: Int
        let totalCount: Int
    }

    struct Manifest: Codable, Sendable {
        struct Entry: Codable, Sendable {
            let id: UUID
            let fileName: String
            let source: CardImageInput.Source
            /// schema v1との後方互換のためoptional。v2では必須として検証する。
            let byteCount: Int?
        }

        let schemaVersion: Int
        /// schema v1との後方互換のためoptional。restore時にv2へ移行する。
        let queueID: UUID?
        let processedCount: Int?
        let totalCount: Int?
        let entries: [Entry]

        init(
            schemaVersion: Int,
            queueID: UUID?,
            processedCount: Int?,
            totalCount: Int?,
            entries: [Entry]
        ) {
            self.schemaVersion = schemaVersion
            self.queueID = queueID
            self.processedCount = processedCount
            self.totalCount = totalCount
            self.entries = entries
        }
    }

    enum StoreError: LocalizedError {
        case invalidManifest
        case incompleteQueue
        case queueMismatch
        case headMismatch

        var errorDescription: String? {
            switch self {
            case .invalidManifest:
                return "未完了の読み取り情報が破損しています"
            case .incompleteQueue:
                return "未完了画像の保存が完了しませんでした"
            case .queueMismatch:
                return "別の読み取りキューへ更新されたため操作を中止しました"
            case .headMismatch:
                return "読み取りキューの順序が変わったため操作を中止しました"
            }
        }
    }

    private let explicitBaseDirectory: URL?
    private let fileManager: FileManager

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        explicitBaseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    func persist(_ images: [CardImageInput], queueID: UUID) async throws {
        if images.isEmpty {
            try discard(queueID: queueID)
            return
        }

        let base = try baseDirectory()
        let target = base.appendingPathComponent("PendingOCR", isDirectory: true)
        let backup = base.appendingPathComponent("PendingOCR.backup", isDirectory: true)
        let staging = base.appendingPathComponent(
            ".PendingOCR.staging.\(queueID.uuidString).\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        var entries: [Manifest.Entry] = []
        entries.reserveCapacity(images.count)
        for (index, input) in images.enumerated() {
            try Task.checkCancellation()
            let fileName = String(format: "%03d-%@.jpg", index, input.id.uuidString)
            try input.data.write(to: staging.appendingPathComponent(fileName), options: .atomic)
            entries.append(Manifest.Entry(
                id: input.id,
                fileName: fileName,
                source: input.source,
                byteCount: input.data.count
            ))
            // actorを再入可能にし、明示キャンセルが最大10枚の書込み途中でも届くようにする。
            await Task.yield()
        }
        try Task.checkCancellation()
        let manifest = Manifest(
            schemaVersion: 2,
            queueID: queueID,
            processedCount: 0,
            totalCount: images.count,
            entries: entries
        )
        try writeManifest(manifest, to: staging)
        guard manifestsMatch(try readManifest(at: staging), manifest) else {
            throw StoreError.incompleteQueue
        }
        try Task.checkCancellation()

        if fileManager.fileExists(atPath: target.path) {
            // targetが正常なら古いbackupは不要。新しい置換が成功するまではtargetを残す。
            if fileManager.fileExists(atPath: backup.path), (try? readManifest(at: target)) != nil {
                try? fileManager.removeItem(at: backup)
            }
            _ = try fileManager.replaceItemAt(
                target,
                withItemAt: staging,
                backupItemName: backup.lastPathComponent,
                options: []
            )
        } else {
            try fileManager.moveItem(at: staging, to: target)
        }

        // 原子的置換後はcommit済みとして検証する。呼出し側のcancelはqueueID指定discardで処理する。
        do {
            guard manifestsMatch(try readManifest(at: target), manifest) else {
                throw StoreError.incompleteQueue
            }
            try? fileManager.removeItem(at: backup)
        } catch {
            try restoreBackupIfNeeded(target: target, backup: backup)
            throw error
        }
    }

    func restore() async throws -> Queue? {
        let base = try baseDirectory()
        let target = base.appendingPathComponent("PendingOCR", isDirectory: true)
        let backup = base.appendingPathComponent("PendingOCR.backup", isDirectory: true)

        if !fileManager.fileExists(atPath: target.path) {
            try restoreBackupIfNeeded(target: target, backup: backup)
        }
        guard fileManager.fileExists(atPath: target.path) else { return nil }

        do {
            let manifest = try migrateLegacyManifestIfNeeded(at: target)
            return try await readQueue(at: target, manifest: manifest)
        } catch {
            try restoreBackupIfNeeded(target: target, backup: backup)
            guard fileManager.fileExists(atPath: target.path) else { throw error }
            let manifest = try migrateLegacyManifestIfNeeded(at: target)
            return try await readQueue(at: target, manifest: manifest)
        }
    }

    /// 画面上の先頭と永続キューの先頭が一致する場合だけ、1件進める。
    @discardableResult
    func advance(queueID: UUID, expectedInputID: UUID) throws -> Int {
        let base = try baseDirectory()
        let target = base.appendingPathComponent("PendingOCR", isDirectory: true)
        let backup = base.appendingPathComponent("PendingOCR.backup", isDirectory: true)

        guard fileManager.fileExists(atPath: target.path) else {
            throw StoreError.incompleteQueue
        }
        let currentManifest: Manifest
        if let manifest = try? migrateLegacyManifestIfNeeded(at: target) {
            currentManifest = manifest
        } else {
            try restoreBackupIfNeeded(target: target, backup: backup)
            guard fileManager.fileExists(atPath: target.path) else {
                throw StoreError.incompleteQueue
            }
            currentManifest = try migrateLegacyManifestIfNeeded(at: target)
        }

        guard currentManifest.queueID == queueID else { throw StoreError.queueMismatch }
        guard let removedEntry = currentManifest.entries.first else {
            throw StoreError.incompleteQueue
        }
        guard removedEntry.id == expectedInputID else { throw StoreError.headMismatch }

        let removedURL = try fileURL(for: removedEntry, in: target, schemaVersion: 2)
        let processedCount = (currentManifest.processedCount ?? 0) + 1
        let updatedManifest = Manifest(
            schemaVersion: 2,
            queueID: queueID,
            processedCount: processedCount,
            totalCount: currentManifest.totalCount,
            entries: Array(currentManifest.entries.dropFirst())
        )
        let manifestURL = target.appendingPathComponent("manifest.json")
        let previousManifestData = try Data(contentsOf: manifestURL)
        let updatedManifestData = try JSONEncoder().encode(updatedManifest)

        // manifestを先に原子的に確定し、その後に参照されなくなった画像だけを掃除する。
        try updatedManifestData.write(to: manifestURL, options: .atomic)
        do {
            let committedManifest = try readManifest(at: target)
            guard manifestsMatch(committedManifest, updatedManifest) else {
                throw StoreError.incompleteQueue
            }
        } catch {
            try previousManifestData.write(to: manifestURL, options: .atomic)
            throw error
        }

        try? fileManager.removeItem(at: removedURL)
        cleanupUnreferencedFiles(in: target, keeping: Set(updatedManifest.entries.map(\.fileName)))
        try? fileManager.removeItem(at: backup)
        return updatedManifest.entries.count
    }

    /// 指定した世代だけを破棄する。古いTaskからの呼出しでは新しいキューを残す。
    func discard(queueID: UUID) throws {
        let base = try baseDirectory()
        let target = base.appendingPathComponent("PendingOCR", isDirectory: true)
        let backup = base.appendingPathComponent("PendingOCR.backup", isDirectory: true)

        // backupを先に消す。target削除後にbackupだけが残り、restoreで復活する状態を作らない。
        try removeDirectoryIfMatchingQueue(at: backup, queueID: queueID)
        try removeDirectoryIfMatchingQueue(at: target, queueID: queueID)
    }

    private func removeDirectoryIfMatchingQueue(at directory: URL, queueID: UUID) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        guard let manifest = try? readManifest(at: directory), manifest.queueID == queueID else { return }
        try fileManager.removeItem(at: directory)
    }

    private func readQueue(at directory: URL, manifest: Manifest) async throws -> Queue {
        guard let queueID = manifest.queueID,
              let processedCount = manifest.processedCount,
              let totalCount = manifest.totalCount else {
            throw StoreError.invalidManifest
        }
        var inputs: [CardImageInput] = []
        inputs.reserveCapacity(manifest.entries.count)
        for entry in manifest.entries {
            try Task.checkCancellation()
            let data = try Data(contentsOf: fileURL(for: entry, in: directory, schemaVersion: 2))
            inputs.append(CardImageInput(id: entry.id, data: data, source: entry.source))
            await Task.yield()
        }
        try Task.checkCancellation()
        return Queue(
            id: queueID,
            inputs: inputs,
            processedCount: processedCount,
            totalCount: totalCount
        )
    }

    /// manifestと参照先の存在・サイズだけを検証する。画像Data自体は再読込みしない。
    private func readManifest(at directory: URL) throws -> Manifest {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.schemaVersion == 1 || manifest.schemaVersion == 2 else {
            throw StoreError.invalidManifest
        }

        let ids = Set(manifest.entries.map(\.id))
        let fileNames = Set(manifest.entries.map(\.fileName))
        guard ids.count == manifest.entries.count,
              fileNames.count == manifest.entries.count else {
            throw StoreError.invalidManifest
        }
        if manifest.schemaVersion == 2 {
            guard manifest.queueID != nil,
                  let processedCount = manifest.processedCount,
                  let totalCount = manifest.totalCount,
                  processedCount >= 0,
                  totalCount >= processedCount,
                  totalCount - processedCount == manifest.entries.count,
                  manifest.entries.allSatisfy({ ($0.byteCount ?? -1) >= 0 }) else {
                throw StoreError.invalidManifest
            }
        }
        for entry in manifest.entries {
            _ = try fileURL(for: entry, in: directory, schemaVersion: manifest.schemaVersion)
        }
        return manifest
    }

    private func migrateLegacyManifestIfNeeded(at directory: URL) throws -> Manifest {
        let manifest = try readManifest(at: directory)
        guard manifest.schemaVersion == 1 else { return manifest }
        let migratedEntries = try manifest.entries.map { entry in
            let url = try fileURL(for: entry, in: directory, schemaVersion: 1)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let byteCount = (attributes[.size] as? NSNumber)?.intValue
            return Manifest.Entry(
                id: entry.id,
                fileName: entry.fileName,
                source: entry.source,
                byteCount: byteCount
            )
        }
        let migrated = Manifest(
            schemaVersion: 2,
            queueID: UUID(),
            processedCount: 0,
            totalCount: migratedEntries.count,
            entries: migratedEntries
        )
        try writeManifest(migrated, to: directory)
        return try readManifest(at: directory)
    }

    private func writeManifest(_ manifest: Manifest, to directory: URL) throws {
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    private func fileURL(
        for entry: Manifest.Entry,
        in directory: URL,
        schemaVersion: Int
    ) throws -> URL {
        guard !entry.fileName.isEmpty,
              !entry.fileName.contains("/"),
              !entry.fileName.contains(".."),
              entry.fileName != "manifest.json" else {
            throw StoreError.invalidManifest
        }
        let url = directory.appendingPathComponent(entry.fileName, isDirectory: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw StoreError.incompleteQueue
        }
        if schemaVersion == 2, let expectedSize = entry.byteCount {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue == expectedSize else {
                throw StoreError.incompleteQueue
            }
        }
        return url
    }

    private func manifestsMatch(_ lhs: Manifest, _ rhs: Manifest) -> Bool {
        guard lhs.schemaVersion == rhs.schemaVersion,
              lhs.queueID == rhs.queueID,
              lhs.processedCount == rhs.processedCount,
              lhs.totalCount == rhs.totalCount,
              lhs.entries.count == rhs.entries.count else {
            return false
        }
        return zip(lhs.entries, rhs.entries).allSatisfy { left, right in
            left.id == right.id
                && left.fileName == right.fileName
                && left.source.rawValue == right.source.rawValue
                && left.byteCount == right.byteCount
        }
    }

    private func cleanupUnreferencedFiles(in directory: URL, keeping fileNames: Set<String>) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent != "manifest.json"
            && !fileNames.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func restoreBackupIfNeeded(target: URL, backup: URL) throws {
        guard fileManager.fileExists(atPath: backup.path), (try? readManifest(at: backup)) != nil else {
            return
        }
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: backup, to: target)
    }

    private func baseDirectory() throws -> URL {
        if let explicitBaseDirectory {
            try fileManager.createDirectory(at: explicitBaseDirectory, withIntermediateDirectories: true)
            return explicitBaseDirectory
        }
        return try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }
}
