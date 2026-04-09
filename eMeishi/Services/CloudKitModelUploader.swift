#if DEBUG
import Foundation
import CloudKit

/// CloudKit の MLModelPackage レコードを正しいモデルファイルで上書きする（開発用）。
///
/// 使用方法:
///   1. Simulator を起動し、Settings > 開発者向け > "CloudKit モデルを正しいバージョンに更新" をタップ
///   2. 完了後にこのファイルと SettingsView の呼び出し部分を削除する
///
/// アップロード元: Documents/LocalLLM/（Finder 経由で Mac からシミュレータに転送する）
/// 転送方法: Simulator > File > Open Simulator Device Directories > AppUUID/Documents に配置
enum CloudKitModelUploader {

    private static let database   = CKContainer(identifier: "iCloud.com.jinks.emeishi").publicCloudDatabase
    private static let recordID   = CKRecord.ID(recordName: "65526C03-31FB-4EE0-A61D-7C2C91C1C424")
    private static let chunkBytes = 200 * 1024 * 1024  // 200 MB

    static func uploadCorrectModels(status: @escaping (String) -> Void) async {
        // ソースディレクトリ: Simulator の Documents/LocalLLM/
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = docs.appendingPathComponent("LocalLLM")

        guard FileManager.default.fileExists(atPath: base.path) else {
            await MainActor.run { status("エラー: Documents/LocalLLM が見つかりません") }
            return
        }

        await MainActor.run { status("レコード取得中...") }

        do {
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
                    await MainActor.run { status("エラー: \(path) が見つかりません") }
                    return
                }
                record[field] = CKAsset(fileURL: url)
            }
            await MainActor.run { status("小ファイルセット完了。weight 分割中...") }

            // weight.bin をチャンク分割してセット
            let weightDefs: [(String, Int)] = [
                // embed: chunk 0-1
                ("qwen_embeddings.mlmodelc/weights/weight.bin",              0),
                // ffn: chunk 2-3
                ("qwen_FFN_PF_lut6_chunk_01of01.mlmodelc/weights/weight.bin", 2),
                // lmhead: chunk 4
                ("qwen_lm_head_lut6.mlmodelc/weights/weight.bin",            4),
            ]

            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ckchunks")
            try? FileManager.default.removeItem(at: tmpDir)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

            var chunkIndex = 0
            for (weightPath, _) in weightDefs {
                let src = base.appendingPathComponent(weightPath)
                await MainActor.run { status("分割中: \(weightPath.components(separatedBy: "/").last ?? "")") }

                let handle = try FileHandle(forReadingFrom: src)
                defer { try? handle.close() }
                var part = 0
                while true {
                    guard let data = try handle.read(upToCount: chunkBytes), !data.isEmpty else { break }
                    let chunkURL = tmpDir.appendingPathComponent("chunk_\(chunkIndex).bin")
                    try data.write(to: chunkURL)
                    record["weightChunk\(chunkIndex)"] = CKAsset(fileURL: chunkURL)
                    chunkIndex += 1
                    part += 1
                }
            }
            record["weightChunkCount"] = Int64(chunkIndex)
            await MainActor.run { status("合計 \(chunkIndex) チャンク。CloudKit に保存中（数分かかります）...") }

            try await database.save(record)
            await MainActor.run { status("✅ CloudKit 更新完了（\(chunkIndex) チャンク）") }

        } catch {
            await MainActor.run { status("❌ エラー: \(error.localizedDescription)") }
        }
    }
}
#endif
