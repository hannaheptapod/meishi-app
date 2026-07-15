import Foundation

/// 未完了OCRキューを、画像一式とmanifestが揃った単位で原子的に置換する。
actor PendingOCRStore {
    static let shared = PendingOCRStore()

    struct Manifest: Codable, Sendable {
        struct Entry: Codable, Sendable {
            let id: UUID
            let fileName: String
            let source: CardImageInput.Source
        }

        let schemaVersion: Int
        let entries: [Entry]
    }

    enum StoreError: LocalizedError {
        case invalidManifest
        case incompleteQueue

        var errorDescription: String? {
            switch self {
            case .invalidManifest:
                return "未完了の読み取り情報が破損しています"
            case .incompleteQueue:
                return "未完了画像の保存が完了しませんでした"
            }
        }
    }

    private let explicitBaseDirectory: URL?
    private let fileManager: FileManager

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        explicitBaseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    func persist(_ images: [CardImageInput]) throws {
        if images.isEmpty {
            try discard()
            return
        }

        let base = try baseDirectory()
        let target = base.appendingPathComponent("PendingOCR", isDirectory: true)
        let backup = base.appendingPathComponent("PendingOCR.backup", isDirectory: true)
        let staging = base.appendingPathComponent(
            ".PendingOCR.staging.\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        var entries: [Manifest.Entry] = []
        for (index, input) in images.enumerated() {
            let fileName = String(format: "%03d-%@.jpg", index, input.id.uuidString)
            try input.data.write(to: staging.appendingPathComponent(fileName), options: .atomic)
            entries.append(Manifest.Entry(id: input.id, fileName: fileName, source: input.source))
        }
        let manifest = Manifest(schemaVersion: 1, entries: entries)
        try JSONEncoder().encode(manifest).write(
            to: staging.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        guard (try? readQueue(at: staging)).map({ $0.count == images.count }) == true else {
            throw StoreError.incompleteQueue
        }

        if fileManager.fileExists(atPath: target.path) {
            // targetが正常なら古いbackupは不要。新しい置換が成功するまではtargetを残す。
            if fileManager.fileExists(atPath: backup.path), (try? readQueue(at: target)) != nil {
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

        do {
            guard try readQueue(at: target).count == images.count else {
                throw StoreError.incompleteQueue
            }
            try? fileManager.removeItem(at: backup)
        } catch {
            try restoreBackupIfNeeded(target: target, backup: backup)
            throw error
        }
    }

    func restore() throws -> [CardImageInput] {
        let base = try baseDirectory()
        let target = base.appendingPathComponent("PendingOCR", isDirectory: true)
        let backup = base.appendingPathComponent("PendingOCR.backup", isDirectory: true)

        if let queue = try? readQueue(at: target) {
            return queue
        }
        try restoreBackupIfNeeded(target: target, backup: backup)
        guard fileManager.fileExists(atPath: target.path) else { return [] }
        return try readQueue(at: target)
    }

    /// 先頭削除後のキューが永続化されてから呼出し元へ戻る。
    @discardableResult
    func removeFirst() throws -> Int {
        var queue = try restore()
        guard !queue.isEmpty else { return 0 }
        queue.removeFirst()
        if queue.isEmpty {
            try discard()
        } else {
            try persist(queue)
        }
        return queue.count
    }

    func discard() throws {
        let base = try baseDirectory()
        for name in ["PendingOCR", "PendingOCR.backup"] {
            let url = base.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func readQueue(at directory: URL) throws -> [CardImageInput] {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.schemaVersion == 1 else { throw StoreError.invalidManifest }

        return try manifest.entries.map { entry in
            guard !entry.fileName.contains("/"), !entry.fileName.contains("..") else {
                throw StoreError.invalidManifest
            }
            let data = try Data(contentsOf: directory.appendingPathComponent(entry.fileName))
            return CardImageInput(id: entry.id, data: data, source: entry.source)
        }
    }

    private func restoreBackupIfNeeded(target: URL, backup: URL) throws {
        guard fileManager.fileExists(atPath: backup.path), (try? readQueue(at: backup)) != nil else {
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
