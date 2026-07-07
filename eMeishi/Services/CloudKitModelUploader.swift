#if DEBUG
import Foundation
import CloudKit
import CryptoKit

/// CloudKit の MLModelPackage レコードを正しいモデルファイルで上書きする（開発用）。
///
/// 使い方:
///   1. Simulator の Documents/LocalLLM/ に新しいモデルファイルを配置
///      （Simulator > File > Open Simulator Device Directories > AppUUID/Documents）
///   2. DEBUG ビルドでアプリを起動し Settings > 開発者向け > "CloudKit モデルを正しいバージョンに更新"
///   3. ログ (`CloudKitUpload:`) で SHA256・チャンク数・検証結果を確認
///
/// アップロード後に埋め込む検証フィールド:
///   - embedWeightSHA256 / ffnWeightSHA256 / lmheadWeightSHA256
///     ダウンロード側 (CloudKitModelService) が weight.bin の整合性を検証するために使う
///   - weightChunkCount は従来通り Int64 で格納
@MainActor
enum CloudKitModelUploader {

    private static let database   = CKContainer(identifier: "iCloud.com.jinks.emeishi").publicCloudDatabase
    private static let recordID   = CKRecord.ID(recordName: "65526C03-31FB-4EE0-A61D-7C2C91C1C424")
    private static let chunkBytes = 200 * 1024 * 1024  // 200 MB

    private struct WeightSource {
        let label: String            // "embed" / "ffn" / "lmhead"
        let relativePath: String     // Documents/LocalLLM からの相対パス
        let sha256Field: String      // レコードに書き込むフィールド名
        let firstChunkIndex: Int     // weightChunk<N> の開始 index
    }

    private static let weightSources: [WeightSource] = [
        WeightSource(label: "embed",
                     relativePath: "qwen_embeddings.mlmodelc/weights/weight.bin",
                     sha256Field: "embedWeightSHA256",
                     firstChunkIndex: 0),
        WeightSource(label: "ffn",
                     relativePath: "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc/weights/weight.bin",
                     sha256Field: "ffnWeightSHA256",
                     firstChunkIndex: 2),
        WeightSource(label: "lmhead",
                     relativePath: "qwen_lm_head_lut6.mlmodelc/weights/weight.bin",
                     sha256Field: "lmheadWeightSHA256",
                     firstChunkIndex: 4),
    ]

    static func uploadCorrectModels(status: @escaping @Sendable @MainActor (String) -> Void) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = docs.appendingPathComponent("LocalLLM")

        guard FileManager.default.fileExists(atPath: base.path) else {
            status("エラー: Documents/LocalLLM が見つかりません")
            return
        }

        do {
            // Preflight: 全 weight.bin の SHA256・サイズをアップロード前に計算してログ出力
            status("weight.bin をハッシュ計算中...")
            var preflight: [String: (sha256: String, size: Int64)] = [:]
            for src in weightSources {
                let url = base.appendingPathComponent(src.relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    status("エラー: \(src.relativePath) が見つかりません")
                    return
                }
                let (sha, size) = try sha256AndSize(of: url)
                preflight[src.label] = (sha, size)
                let mb = String(format: "%.1f", Double(size) / 1024 / 1024)
                print("CloudKitUpload: \(src.label) size=\(mb)MB sha256=\(sha)")
            }

            status("レコード取得中...")
            let record = try await database.record(for: recordID)

            // 小ファイル
            let smallFiles: [(String, String)] = [
                ("coremlDataAsset",        "qwen_embeddings.mlmodelc/coremldata.bin"),
                ("metadataAsset",          "qwen_embeddings.mlmodelc/metadata.json"),
                ("modelMilAsset",          "qwen_embeddings.mlmodelc/model.mil"),
                ("prefillCoremlDataAsset", "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc/coremldata.bin"),
                ("prefillMetadataAsset",   "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc/metadata.json"),
                ("prefillModelMilAsset",   "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc/model.mil"),
                ("decodeCoremlDataAsset",  "qwen_lm_head_lut6.mlmodelc/coremldata.bin"),
                ("decodeMetadataAsset",    "qwen_lm_head_lut6.mlmodelc/metadata.json"),
                ("decodeModelMilAsset",    "qwen_lm_head_lut6.mlmodelc/model.mil"),
                ("tokenizerAsset",         "tokenizer.json"),
            ]
            for (field, path) in smallFiles {
                let url = base.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    status("エラー: \(path) が見つかりません")
                    return
                }
                record[field] = CKAsset(fileURL: url)
            }
            status("小ファイルセット完了。weight 分割中...")

            // weight.bin をチャンク分割してセット
            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ckchunks")
            try? FileManager.default.removeItem(at: tmpDir)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

            var chunkIndex = 0
            for src in weightSources {
                let url = base.appendingPathComponent(src.relativePath)
                status("分割中: \(src.label) weight.bin")

                if chunkIndex != src.firstChunkIndex {
                    print("CloudKitUpload: WARNING chunk index 不整合 expected=\(src.firstChunkIndex) actual=\(chunkIndex)")
                }

                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while true {
                    guard let data = try handle.read(upToCount: chunkBytes), !data.isEmpty else { break }
                    let chunkURL = tmpDir.appendingPathComponent("chunk_\(chunkIndex).bin")
                    try data.write(to: chunkURL)
                    record["weightChunk\(chunkIndex)"] = CKAsset(fileURL: chunkURL)
                    chunkIndex += 1
                }

                // preflight で計算済みの SHA256 をレコードにセット
                if let info = preflight[src.label] {
                    record[src.sha256Field] = info.sha256 as CKRecordValue
                }
            }
            record["weightChunkCount"] = Int64(chunkIndex)

            let summary = "合計 \(chunkIndex) チャンク / " + weightSources.compactMap { src in
                preflight[src.label].map { "\(src.label)=\(String(format: "%.0f", Double($0.size) / 1024 / 1024))MB" }
            }.joined(separator: " ")
            print("CloudKitUpload: \(summary)")
            status("\(summary) を CloudKit に保存中（数分かかります）...")

            _ = try await database.save(record)

            // Post-upload: 保存したレコードを読み戻して SHA256 とチャンク数が書き込まれているか検証
            status("保存完了。CloudKit 側を検証中...")
            let keys = weightSources.map { $0.sha256Field } + ["weightChunkCount"]
            let verifyOp = CKFetchRecordsOperation(recordIDs: [recordID])
            verifyOp.desiredKeys = keys
            let verifyRecord = try await fetch(operation: verifyOp, recordID: recordID)

            var mismatches: [String] = []
            for src in weightSources {
                let stored = verifyRecord[src.sha256Field] as? String
                let expected = preflight[src.label]?.sha256
                if stored != expected {
                    mismatches.append("\(src.label): expected=\(expected ?? "nil") stored=\(stored ?? "nil")")
                }
            }
            if let storedCount = verifyRecord["weightChunkCount"] as? Int64, storedCount != Int64(chunkIndex) {
                mismatches.append("chunkCount: expected=\(chunkIndex) stored=\(storedCount)")
            }

            if mismatches.isEmpty {
                print("CloudKitUpload: ✅ 検証 OK")
                status("✅ CloudKit 更新・検証完了（\(chunkIndex) チャンク）")
            } else {
                print("CloudKitUpload: ❌ 検証失敗\n  " + mismatches.joined(separator: "\n  "))
                status("❌ 保存は成功したが検証失敗: \(mismatches.count) 件")
            }

        } catch {
            print("CloudKitUpload: ❌ \(error.localizedDescription)")
            status("❌ エラー: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private static func sha256AndSize(of url: URL) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        let bufferSize = 1024 * 1024
        while true {
            guard let data = try handle.read(upToCount: bufferSize), !data.isEmpty else { break }
            hasher.update(data: data)
            total += Int64(data.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, total)
    }

    private static func fetch(operation: CKFetchRecordsOperation, recordID: CKRecord.ID) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord, Error>) in
            operation.qualityOfService = .userInitiated
            operation.perRecordResultBlock = { _, result in
                switch result {
                case .success(let record): continuation.resume(returning: record)
                case .failure(let error):  continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }
}
#endif
