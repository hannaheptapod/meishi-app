import Foundation
import CoreML
import Combine

// オンデバイスOSSモデルによる意味分析サービス
// Foundation Modelsが利用不可の場合のフォールバック（層2）
class LocalLLMService: ObservableObject {

    static let shared = LocalLLMService()

    // MARK: - 定数

    let modelFileName = "Qwen2.5-0.5B-Instruct-4bit.mlpackage"
    private let downloadURL = URL(string: "https://huggingface.co/finnvoorhees/coreml-Qwen2.5-0.5B-Instruct-4bit/resolve/main/Qwen2.5-0.5B-Instruct-4bit.mlpackage")!

    // MARK: - 状態

    /// モデルが取得済みかつロード可能な状態かどうか
    @Published var isModelAvailable: Bool = false

    /// ダウンロード中かどうか
    @Published var isDownloading: Bool = false

    /// ダウンロード進捗（0.0〜1.0）
    @Published var downloadProgress: Double = 0.0

    private var loadedModel: MLModel? = nil

    var modelFileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLM", isDirectory: true)
        return dir.appendingPathComponent(modelFileName)
    }

    private init() {
        isModelAvailable = FileManager.default.fileExists(atPath: modelFileURL.path)
    }

    // MARK: - モデルロード

    func loadModelIfNeeded() throws {
        guard isModelAvailable, loadedModel == nil else { return }
        let config = MLModelConfiguration()
        config.computeUnits = .all   // ANE / GPU / CPU を自動選択
        loadedModel = try MLModel(contentsOf: modelFileURL, configuration: config)
    }

    // MARK: - 推論

    /// OCR行リストを受け取り、CardFieldClassifier.ParsedCard を返す
    /// エラー時またはモデル未ロード時は nil を返す（呼び出し元はフォールバックへ進む）
    func classify(lines: [String]) async -> CardFieldClassifier.ParsedCard? {
        guard let model = loadedModel else { return nil }

        let prompt = buildPrompt(lines: lines)

        // NOTE: CoreMLPipelines または MLModel の generate API を使用する
        // 実装はモデルのMLPackage仕様に依存するため、
        // ダウンロード後に以下を具体化する
        //
        // let input = try Qwen25Input(prompt: prompt)
        // let output = try model.prediction(from: input)
        // return parseJSON(output.text)

        _ = model   // 未使用警告を抑制（実装プレースホルダー）
        _ = prompt
        return nil
    }

    // MARK: - プロンプト構築

    private func buildPrompt(lines: [String]) -> String {
        let rawText = lines.joined(separator: "\n")
        return """
            以下は名刺から読み取ったテキストです。各フィールドをJSON形式で出力してください。
            キー名は必ず lastName / firstName / company / title / phone / email / address / website を使用してください。
            値が不明な場合は空文字列にしてください。JSONのみ出力し、説明は不要です。

            \(rawText)
            """
    }

    // MARK: - JSONパース

    private func parseJSON(_ text: String) -> CardFieldClassifier.ParsedCard? {
        // モデル出力から ```json ``` フェンスを除去してパース
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }

        var result = CardFieldClassifier.ParsedCard()
        result.lastName  = dict["lastName"]  ?? ""
        result.firstName = dict["firstName"] ?? ""
        result.company   = dict["company"]   ?? ""
        result.title     = dict["title"]     ?? ""
        result.phone     = dict["phone"]     ?? ""
        result.email     = dict["email"]     ?? ""
        result.address   = dict["address"]   ?? ""
        result.website   = dict["website"]   ?? ""
        return result
    }

    // MARK: - ダウンロード

    /// ユーザーの同意を得たあとに呼び出す。@Published プロパティで進捗を通知する
    func downloadModel() async throws {
        await MainActor.run {
            isDownloading = true
            downloadProgress = 0.0
        }
        defer {
            Task { @MainActor in isDownloading = false }
        }

        let dir = modelFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // URLSession の delegate で進捗を追跡
        let tracker = DownloadProgressTracker { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.downloadProgress = progress
            }
        }
        let session = URLSession(configuration: .default, delegate: tracker, delegateQueue: nil)
        let (tempURL, _) = try await session.download(from: downloadURL)
        try FileManager.default.moveItem(at: tempURL, to: modelFileURL)
        try loadModelIfNeeded()

        await MainActor.run { isModelAvailable = true }
    }

    // MARK: - 削除

    /// ダウンロード済みモデルを削除する
    func deleteModel() throws {
        guard isModelAvailable else { return }
        try FileManager.default.removeItem(at: modelFileURL)
        loadedModel = nil
        isModelAvailable = false
    }

    // MARK: - モデルファイルサイズ

    /// ダウンロード済みモデルのファイルサイズ（バイト）
    var modelFileSize: Int64? {
        guard isModelAvailable,
              let attrs = try? FileManager.default.attributesOfItem(atPath: modelFileURL.path),
              let size = attrs[.size] as? Int64
        else { return nil }
        return size
    }
}

// MARK: - ダウンロード進捗トラッカー

private class DownloadProgressTracker: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
