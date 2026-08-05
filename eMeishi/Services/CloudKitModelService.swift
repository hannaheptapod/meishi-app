import Foundation
import CloudKit
import CryptoKit
import os

/// CloudKit Public Database からオンデバイスLLMモデルファイルをダウンロードするサービス。
/// Anemll 変換済み Qwen3-0.6B-ctx512（3モデル分割方式）に対応。
///
/// CloudKit レコード構成（MLModelPackage）:
///   - coremlDataAsset:         Embed モデルの coremldata.bin
///   - metadataAsset:           Embed モデルの metadata.json
///   - modelMilAsset:           Embed モデルの model.mil
///   - prefillCoremlDataAsset:  FFN モデルの coremldata.bin
///   - prefillMetadataAsset:    FFN モデルの metadata.json
///   - prefillModelMilAsset:    FFN モデルの model.mil
///   - decodeCoremlDataAsset:   LM Head モデルの coremldata.bin
///   - decodeMetadataAsset:     LM Head モデルの metadata.json
///   - decodeModelMilAsset:     LM Head モデルの model.mil
///   - weightChunk0〜4:         weight.bin チャンク（embed:0-1, ffn:2-3, lmhead:4）
///   - weightChunkCount:        チャンク総数（= 5）
///   - tokenizerAsset:          tokenizer.json
actor CloudKitModelService {

    static let shared = CloudKitModelService()

    private static let containerIdentifier = "iCloud.com.jinks.emeishi"
    private let entitlementChecker: any CloudKitEntitlementChecking
    private let recordType = "MLModelPackage"
    private let stableChannelRecordID = CKRecord.ID(recordName: "model-v2-channel-stable")

    struct VersionManifest: Decodable, Sendable {
        struct FileEntry: Decodable, Sendable {
            struct Chunk: Decodable, Sendable {
                let recordName: String
                let size: Int64
                let sha256: String
            }

            let relativePath: String
            let size: Int64
            let sha256: String
            let chunks: [Chunk]
        }

        let schemaVersion: Int
        let version: String
        let chunkBytes: Int64
        let files: [FileEntry]
    }

    // MARK: - モデルフィールド定義

    private struct ModelAssetConfig {
        let dirName: String
        let coremlDataField: String
        let metadataField: String
        let modelMilField: String
        /// このモデルの weight.bin を構成するチャンクのインデックス範囲
        let chunkRange: Range<Int>
        /// レコードに格納された weight.bin の SHA256 を読み出すフィールド（optional）
        let sha256Field: String
    }

    private let modelConfigs: [ModelAssetConfig] = [
        ModelAssetConfig(
            dirName:         "qwen_embeddings.mlmodelc",
            coremlDataField: "coremlDataAsset",
            metadataField:   "metadataAsset",
            modelMilField:   "modelMilAsset",
            chunkRange:      0..<2,
            sha256Field:     "embedWeightSHA256"
        ),
        ModelAssetConfig(
            dirName:         "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc",
            coremlDataField: "prefillCoremlDataAsset",
            metadataField:   "prefillMetadataAsset",
            modelMilField:   "prefillModelMilAsset",
            chunkRange:      2..<4,
            sha256Field:     "ffnWeightSHA256"
        ),
        ModelAssetConfig(
            dirName:         "qwen_lm_head_lut6.mlmodelc",
            coremlDataField: "decodeCoremlDataAsset",
            metadataField:   "decodeMetadataAsset",
            modelMilField:   "decodeModelMilAsset",
            chunkRange:      4..<5,
            sha256Field:     "lmheadWeightSHA256"
        ),
    ]

    private let tokenizerField        = "tokenizerAsset"
    private let weightChunkPrefix     = "weightChunk"
    private let weightChunkCountField = "weightChunkCount"

    // MARK: - エラー型

    enum CloudKitModelError: LocalizedError {
        case noRecordFound
        case cloudKitUnavailable
        case versionedDistributionUnavailable
        case invalidManifest(String)
        case unsafeRelativePath(String)
        case missingAsset(String)
        case missingChunkCount
        case chunkConcatenationFailed(String)
        case sha256Mismatch(model: String, expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .cloudKitUnavailable:
                return "この環境ではCloudKitモデル配布を利用できません"
            case .versionedDistributionUnavailable:
                return "バージョン付きモデル配布がまだ設定されていません"
            case .invalidManifest(let reason):
                return "モデルmanifestが不正です: \(reason)"
            case .unsafeRelativePath(let path):
                return "許可されていないモデルパスです: \(path)"
            case .noRecordFound:
                return "CloudKit にモデルレコードが見つかりません"
            case .missingAsset(let field):
                return "アセットが見つかりません: \(field)"
            case .missingChunkCount:
                return "weightChunkCount が設定されていません"
            case .chunkConcatenationFailed(let model):
                return "\(model) の weight チャンクの結合に失敗しました"
            case .sha256Mismatch(let model, let expected, let actual):
                return "\(model) の weight.bin が破損しています (expected=\(expected.prefix(8))... actual=\(actual.prefix(8))...)"
            }
        }
    }

    init(entitlementChecker: any CloudKitEntitlementChecking = SignedCloudKitEntitlementChecker()) {
        self.entitlementChecker = entitlementChecker
    }

    // MARK: - モデルダウンロード

    private let modelRecordID = CKRecord.ID(recordName: "65526C03-31FB-4EE0-A61D-7C2C91C1C424")

    /// CloudKit からモデルファイルをダウンロードし、指定ディレクトリに保存する。
    /// CKAsset.fileURL は operation 完了後に無効になるため、すべてのファイルコピーを
    /// perRecordResultBlock コールバック内（operation 生存中）で完結させる。
    func downloadModel(modelDir: URL,
                       progress: @escaping @Sendable @MainActor (Double) -> Void) async throws {
        let fm = FileManager.default
        let parent = modelDir.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".\(modelDir.lastPathComponent).download.\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // v2のchannelまたはmanifestが未配置の場合だけ、従来方式へフォールバックする。
        do {
            try await downloadVersionedModel(
                modelDir: staging,
                tokenizerDestination: staging.appendingPathComponent("tokenizer.json"),
                progress: progress
            )
        } catch CloudKitModelError.versionedDistributionUnavailable {
            AppLogger.cloudKit.info("バージョン付きモデルが未配置のため従来方式へフォールバック")
            try await downloadLegacyModel(
                modelDir: staging,
                tokenizerDestination: staging.appendingPathComponent("tokenizer.json"),
                progress: progress
            )
        }

        try Task.checkCancellation()
        try await ModelInstallService.shared.install(stagingDirectory: staging, at: modelDir)
        await progress(1)
    }

    private func downloadLegacyModel(modelDir: URL,
                                     tokenizerDestination: URL,
                                     progress: @escaping @Sendable @MainActor (Double) -> Void) async throws {
        // Step 1: 小ファイル + weightChunkCount + SHA256 を一括取得
        let smallKeys: [String] = modelConfigs.flatMap { config in
            [config.coremlDataField, config.metadataField, config.modelMilField, config.sha256Field]
        } + [tokenizerField, weightChunkCountField]

        let metaRecord = try await fetchRecord(desiredKeys: smallKeys, progress: { p in
            progress(p * 0.1)  // 全体の 0-10%
        })

        guard let chunkCount = metaRecord[weightChunkCountField] as? Int64, chunkCount > 0 else {
            throw CloudKitModelError.missingChunkCount
        }

        // 各モデルの期待 SHA256（フィールド未設定なら nil = 検証スキップ）
        var expectedSHA256: [String: String] = [:]
        for config in modelConfigs {
            if let sha = metaRecord[config.sha256Field] as? String, !sha.isEmpty {
                expectedSHA256[config.dirName] = sha
            }
        }

        // 小ファイルを書き出し
        let fm = FileManager.default
        try writeSmallFiles(record: metaRecord, modelDir: modelDir,
                            tokenizerDestination: tokenizerDestination, fm: fm)

        // Step 2: weight チャンクを1本ずつ個別取得し、各モデルの weight.bin に書き込む
        // chunkRange に従い embed:0-1, ffn:2-3, lmhead:4 を各モデルに分配する
        let totalChunks = Int(chunkCount)
        for i in 0..<totalChunks {
            let field = "\(weightChunkPrefix)\(i)"
            let chunkRecord = try await fetchRecord(desiredKeys: [field], progress: { p in
                let base = 0.1 + Double(i) / Double(totalChunks) * 0.9
                let step = 0.9 / Double(totalChunks)
                progress(base + p * step)
            })
            try writeChunk(record: chunkRecord, field: field, index: i,
                           modelDir: modelDir, fm: fm)

            // 各モデルの最終チャンクを書き終えたタイミングで SHA256 検証
            if let config = modelConfigs.first(where: { $0.chunkRange.last == i }) {
                try verifyWeightSHA256(modelDir: modelDir,
                                       config: config,
                                       expected: expectedSHA256[config.dirName])
            }
        }

        await progress(1.0)
    }

    // MARK: - バージョン付きモデル配布 v2

    private func downloadVersionedModel(
        modelDir: URL,
        tokenizerDestination: URL,
        progress: @escaping @Sendable @MainActor (Double) -> Void
    ) async throws {
        let database = try cloudDatabase()
        let channel = try await fetchVersionedRecord(stableChannelRecordID, database: database)
        guard let version = channel["embedWeightSHA256"] as? String, !version.isEmpty else {
            throw CloudKitModelError.versionedDistributionUnavailable
        }

        let manifestID = CKRecord.ID(recordName: Self.manifestRecordName(version: version))
        let manifestRecord = try await fetchVersionedRecord(manifestID, database: database)
        guard let asset = manifestRecord[tokenizerField] as? CKAsset,
              let assetURL = asset.fileURL else {
            throw CloudKitModelError.versionedDistributionUnavailable
        }
        let manifestData = try Data(contentsOf: assetURL)
        guard let expectedManifestSHA = manifestRecord["embedWeightSHA256"] as? String,
              Self.isSHA256(expectedManifestSHA),
              Self.sha256(manifestData) == expectedManifestSHA.lowercased() else {
            throw CloudKitModelError.invalidManifest("manifestのSHA-256が一致しません")
        }
        let manifest = try Self.validatedManifest(from: manifestData, expectedVersion: version)

        let fm = FileManager.default
        let totalChunks = max(1, manifest.files.reduce(0) { $0 + $1.chunks.count })
        var completedChunks = 0

        for file in manifest.files {
            try Task.checkCancellation()
            let destination = modelDir.appendingPathComponent(file.relativePath)
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard fm.createFile(atPath: destination.path, contents: nil) else {
                throw CloudKitModelError.invalidManifest("ファイルを作成できません: \(file.relativePath)")
            }
            let handle = try FileHandle(forWritingTo: destination)
            do {
                for chunk in file.chunks {
                    try Task.checkCancellation()
                    let record = try await database.record(
                        for: CKRecord.ID(recordName: chunk.recordName)
                    )
                    guard let chunkAsset = record[weightChunkPrefix + "0"] as? CKAsset,
                          let chunkURL = chunkAsset.fileURL else {
                        throw CloudKitModelError.missingAsset(weightChunkPrefix + "0")
                    }
                    let data = try Data(contentsOf: chunkURL, options: .mappedIfSafe)
                    let actualChunkSHA = Self.sha256(data)
                    guard Int64(data.count) == chunk.size,
                          actualChunkSHA == chunk.sha256.lowercased() else {
                        throw CloudKitModelError.sha256Mismatch(
                            model: chunk.recordName,
                            expected: chunk.sha256,
                            actual: actualChunkSHA
                        )
                    }
                    try handle.write(contentsOf: data)
                    completedChunks += 1
                    await progress(Double(completedChunks) / Double(totalChunks) * 0.95)
                }
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            let fileSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard Int64(fileSize ?? -1) == file.size else {
                throw CloudKitModelError.invalidManifest("ファイルサイズが一致しません: \(file.relativePath)")
            }
            let actual = try computeSHA256(of: destination)
            guard actual == file.sha256.lowercased() else {
                throw CloudKitModelError.sha256Mismatch(
                    model: file.relativePath,
                    expected: file.sha256,
                    actual: actual
                )
            }
        }

        // tokenizerDestinationは従来方式との共通引数。v2 manifestでも配置を確認する。
        guard fm.fileExists(atPath: tokenizerDestination.path) else {
            throw CloudKitModelError.invalidManifest("tokenizer.jsonがありません")
        }
    }

    nonisolated private static func manifestRecordName(version: String) -> String {
        "model-v2-\(version.replacingOccurrences(of: ".", with: "-"))-manifest"
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func validatedManifest(
        from data: Data,
        expectedVersion: String
    ) throws -> VersionManifest {
        let manifest: VersionManifest
        do {
            manifest = try JSONDecoder().decode(VersionManifest.self, from: data)
        } catch {
            throw CloudKitModelError.invalidManifest("JSONを解析できません")
        }
        guard manifest.schemaVersion == 2,
              manifest.version == expectedVersion,
              !manifest.version.isEmpty,
              manifest.chunkBytes > 0,
              manifest.chunkBytes <= 10 * 1024 * 1024,
              !manifest.files.isEmpty else {
            throw CloudKitModelError.invalidManifest("schema、versionまたはchunkBytesが不正です")
        }

        let allowedRoots: Set<String> = [
            "qwen_embeddings.mlmodelc",
            "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc",
            "qwen_lm_head_lut6.mlmodelc",
        ]
        var paths = Set<String>()
        var recordNames = Set<String>()
        for file in manifest.files {
            let components = file.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.relativePath.hasPrefix("/"),
                  !file.relativePath.contains("\\"),
                  !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  components.map(String.init).joined(separator: "/") == file.relativePath else {
                throw CloudKitModelError.unsafeRelativePath(file.relativePath)
            }
            let isTokenizer = file.relativePath == "tokenizer.json"
            guard isTokenizer || (components.count > 1 && allowedRoots.contains(String(components[0]))) else {
                throw CloudKitModelError.unsafeRelativePath(file.relativePath)
            }
            guard paths.insert(file.relativePath).inserted,
                  file.size >= 0,
                  Self.isSHA256(file.sha256),
                  !file.chunks.isEmpty,
                  file.chunks.reduce(Int64(0), { $0 + $1.size }) == file.size else {
                throw CloudKitModelError.invalidManifest("ファイル定義が不正です: \(file.relativePath)")
            }
            for chunk in file.chunks {
                guard !chunk.recordName.isEmpty,
                      recordNames.insert(chunk.recordName).inserted,
                      chunk.size > 0,
                      chunk.size <= manifest.chunkBytes,
                      Self.isSHA256(chunk.sha256) else {
                    throw CloudKitModelError.invalidManifest("チャンク定義が不正です: \(chunk.recordName)")
                }
            }
        }

        let requiredPaths: Set<String> = Set(
            allowedRoots.flatMap { root in
                [
                    "\(root)/coremldata.bin",
                    "\(root)/metadata.json",
                    "\(root)/model.mil",
                    "\(root)/weights/weight.bin",
                ]
            } + ["tokenizer.json"]
        )
        guard requiredPaths.isSubset(of: paths) else {
            throw CloudKitModelError.invalidManifest("必須モデルファイルが不足しています")
        }
        return manifest
    }

    nonisolated private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains(Int($0.value)) || (97...102).contains(Int($0.value))
        }
    }

    private func fetchVersionedRecord(_ id: CKRecord.ID, database: CKDatabase) async throws -> CKRecord {
        do {
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            throw CloudKitModelError.versionedDistributionUnavailable
        }
    }

    // MARK: - SHA256 検証

    /// 指定モデルの weight.bin を SHA256 で検証する。
    /// `expected` が nil の場合（古いアップロード済みレコードに SHA256 フィールドが無い場合）は検証をスキップする。
    private func verifyWeightSHA256(modelDir: URL,
                                    config: ModelAssetConfig,
                                    expected: String?) throws {
        guard let expected = expected else { return }
        let weightPath = modelDir.appendingPathComponent(config.dirName)
            .appendingPathComponent("weights")
            .appendingPathComponent("weight.bin")
        let actual = try computeSHA256(of: weightPath)
        if actual != expected {
            throw CloudKitModelError.sha256Mismatch(model: config.dirName,
                                                    expected: expected,
                                                    actual: actual)
        }
    }

    private func computeSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let bufferSize = 1024 * 1024
        while true {
            guard let data = try handle.read(upToCount: bufferSize), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - レコード1件取得（desiredKeys で絞り込み）

    private func fetchRecord(desiredKeys: [String],
                             progress: @escaping @Sendable @MainActor (Double) -> Void) async throws -> CKRecord {
        let database = try cloudDatabase()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord, Error>) in
            let operation = CKFetchRecordsOperation(recordIDs: [modelRecordID])
            operation.qualityOfService = .userInitiated
            operation.desiredKeys = desiredKeys
            operation.perRecordProgressBlock = { _, p in Task { await progress(p) } }
            operation.perRecordResultBlock = { _, result in
                switch result {
                case .success(let record): continuation.resume(returning: record)
                case .failure(let error):
                    if let ckError = error as? CKError, ckError.code == .unknownItem {
                        continuation.resume(throwing: CloudKitModelError.noRecordFound)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
            database.add(operation)
        }
    }

    private func cloudDatabase() throws -> CKDatabase {
        guard entitlementChecker.canCreateContainer(identifier: Self.containerIdentifier) else {
            throw CloudKitModelError.cloudKitUnavailable
        }
        return CKContainer(identifier: Self.containerIdentifier).publicCloudDatabase
    }

    // MARK: - 小ファイル書き出し

    private func writeSmallFiles(record: CKRecord,
                                 modelDir: URL,
                                 tokenizerDestination: URL,
                                 fm: FileManager) throws {
        for config in modelConfigs {
            let modelSubDir = modelDir.appendingPathComponent(config.dirName, isDirectory: true)
            try fm.createDirectory(at: modelSubDir, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: modelSubDir.path)

            let smallFiles: [(String, String)] = [
                (config.coremlDataField, "coremldata.bin"),
                (config.metadataField,   "metadata.json"),
                (config.modelMilField,   "model.mil"),
            ]
            for (field, relativePath) in smallFiles {
                guard let asset = record[field] as? CKAsset, let sourceURL = asset.fileURL else {
                    throw CloudKitModelError.missingAsset(field)
                }
                let destURL = modelSubDir.appendingPathComponent(relativePath)
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destURL)
                try fm.copyItem(at: sourceURL, to: destURL)
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destURL.path)
            }
        }
        guard let tokenizerAsset = record[tokenizerField] as? CKAsset,
              let tokenizerSourceURL = tokenizerAsset.fileURL else {
            throw CloudKitModelError.missingAsset(tokenizerField)
        }
        try fm.createDirectory(at: tokenizerDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: tokenizerDestination)
        try fm.copyItem(at: tokenizerSourceURL, to: tokenizerDestination)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tokenizerDestination.path)
    }

    // MARK: - weight チャンク書き出し

    private func writeChunk(record: CKRecord,
                            field: String,
                            index: Int,
                            modelDir: URL,
                            fm: FileManager) throws {
        // chunk index → どのモデルの weights/ に書き込むかを特定
        guard let config = modelConfigs.first(where: { $0.chunkRange.contains(index) }) else {
            throw CloudKitModelError.missingAsset(field)
        }
        let modelSubDir = modelDir.appendingPathComponent(config.dirName, isDirectory: true)
        let weightsDir  = modelSubDir.appendingPathComponent("weights", isDirectory: true)
        try fm.createDirectory(at: weightsDir, withIntermediateDirectories: true)

        guard let chunkAsset = record[field] as? CKAsset, let chunkURL = chunkAsset.fileURL else {
            throw CloudKitModelError.missingAsset(field)
        }

        // weight.bin に追記 or 新規作成
        let weightDest = weightsDir.appendingPathComponent("weight.bin")
        let isFirst = index == config.chunkRange.lowerBound
        if isFirst { try? fm.removeItem(at: weightDest) }

        if !fm.fileExists(atPath: weightDest.path) {
            fm.createFile(atPath: weightDest.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: weightDest) else {
            throw CloudKitModelError.chunkConcatenationFailed(config.dirName)
        }
        handle.seekToEndOfFile()
        let data = try Data(contentsOf: chunkURL)
        handle.write(data)
        try handle.close()
        // CloudKit キャッシュからのコピーは読み取り専用になる場合があるため明示的に書き込み権限を付与
        if index == config.chunkRange.upperBound - 1 {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: weightDest.path)
        }
    }

}
