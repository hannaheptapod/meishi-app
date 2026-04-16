import Foundation
import CloudKit
import CryptoKit

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

    private let database = CKContainer(identifier: "iCloud.com.jinks.emeishi").publicCloudDatabase
    private let recordType = "MLModelPackage"

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
        case missingAsset(String)
        case missingChunkCount
        case chunkConcatenationFailed(String)
        case sha256Mismatch(model: String, expected: String, actual: String)

        var errorDescription: String? {
            switch self {
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

    private init() {}

    // MARK: - モデルダウンロード

    private let modelRecordID = CKRecord.ID(recordName: "65526C03-31FB-4EE0-A61D-7C2C91C1C424")

    /// CloudKit からモデルファイルをダウンロードし、指定ディレクトリに保存する。
    /// CKAsset.fileURL は operation 完了後に無効になるため、すべてのファイルコピーを
    /// perRecordResultBlock コールバック内（operation 生存中）で完結させる。
    func downloadModel(modelDir: URL,
                       tokenizerDestination: URL,
                       progress: @escaping (Double) -> Void) async throws {
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

        progress(1.0)
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
                             progress: @escaping (Double) -> Void) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord, Error>) in
            let operation = CKFetchRecordsOperation(recordIDs: [modelRecordID])
            operation.qualityOfService = .userInitiated
            operation.desiredKeys = desiredKeys
            operation.perRecordProgressBlock = { _, p in progress(p) }
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
            self.database.add(operation)
        }
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
        if index == config.chunkRange.last! {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: weightDest.path)
        }
    }

}
