import Foundation
import CoreML
import Accelerate
import Combine

// オンデバイス Qwen2.5-0.5B-Instruct（4bit量子化 CoreML）による意味分析サービス
class LocalLLMService: ObservableObject {

    static let shared = LocalLLMService()

    // MARK: - 定数

    let modelFileName = "Qwen2.5-0.5B-Instruct-4bit.mlmodelc"

    /// CoreML モデルファイル群（mlmodelc はディレクトリ構造）
    private let hfModelBase = "https://huggingface.co/finnvoorhees/coreml-Qwen2.5-0.5B-Instruct-4bit/resolve/main/Qwen2.5-0.5B-Instruct-4bit.mlmodelc"
    private let modelFiles: [(path: String, approxBytes: Int64)] = [
        ("metadata.json",            10_000),
        ("coremldata.bin",           50_000),
        ("analytics/coremldata.bin",  5_000),
        ("model.mil",             5_000_000),
        ("weights/weight.bin",  268_000_000),
    ]

    /// tokenizer.json（Qwen/Qwen2.5-0.5B-Instruct）
    private let tokenizerSource = "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/resolve/main/tokenizer.json"
    private let tokenizerApproxBytes: Int64 = 7_500_000

    // MARK: - 状態

    @Published var isModelAvailable: Bool = false
    @Published var isDownloading:    Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var isInferencing:    Bool = false

    private var loadedModel: MLModel? = nil
    private var tokenizer:   Qwen25Tokenizer? = nil

    /// モデルロード後に設定する CoreML の入出力フィーチャー名
    private var inputFeatureName:        String = "inputIds"
    private var logitsFeatureName:       String = "logits"
    private var needsAttentionMask:      Bool   = false
    private var attentionMaskFeatureName: String = "causal_mask"
    /// causal_mask の次元数（モデルによって 2D または 4D）
    private var attentionMaskRank:       Int    = 4
    /// causal_mask のデータ型（int32: 1/0マスク、float32/float16: 0.0/-大値加算マスク）
    private var attentionMaskDataType:   MLMultiArrayDataType = .int32

    // MARK: - ファイルパス

    var modelDirURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLM", isDirectory: true)
    }
    var modelFileURL: URL {
        modelDirURL.appendingPathComponent(modelFileName, isDirectory: true)
    }
    var tokenizerFileURL: URL {
        modelDirURL.appendingPathComponent("tokenizer.json")
    }

    private init() {
        let weightURL    = modelFileURL.appendingPathComponent("weights/weight.bin")
        let tokenizerURL = tokenizerFileURL
        isModelAvailable = FileManager.default.fileExists(atPath: weightURL.path)
                        && FileManager.default.fileExists(atPath: tokenizerURL.path)
    }

    // MARK: - モデル管理

    func loadModelIfNeeded() throws {
        guard isModelAvailable else { return }

        if loadedModel == nil {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            loadedModel = try MLModel(contentsOf: modelFileURL, configuration: config)
            introspectModel()
        }
        if tokenizer == nil {
            tokenizer = try Qwen25Tokenizer(url: tokenizerFileURL)
        }
    }

    /// ロード済みモデルの入出力フィーチャー名とマスク形式を自動検出する
    private func introspectModel() {
        guard let model = loadedModel else { return }
        let desc = model.modelDescription

        for (name, fDesc) in desc.inputDescriptionsByName {
            guard fDesc.type == .multiArray,
                  let c = fDesc.multiArrayConstraint else { continue }

            let lower = name.lowercased()

            // マスク系フィーチャーを優先判定（名前に "mask" や "causal" を含む）
            if lower.contains("mask") || lower.contains("causal") {
                needsAttentionMask        = true
                attentionMaskFeatureName  = name
                attentionMaskDataType     = c.dataType  // float32/float16/int32 を記録
                // 期待される次元数をシェイプ制約から取得
                let sc = c.shapeConstraint
                switch sc.type {
                case .enumerated:
                    attentionMaskRank = sc.enumeratedShapes.first?.count ?? 4
                case .range:
                    attentionMaskRank = sc.sizeRangeForDimension.count
                default:
                    attentionMaskRank = 4
                }
            } else if c.dataType == .int32 {
                // マスク以外の int32 MultiArray → トークンID入力
                inputFeatureName = name
            }
        }

        // 出力フィーチャー: float MultiArray → ロジット
        for (name, fDesc) in desc.outputDescriptionsByName {
            if fDesc.type == .multiArray,
               let c = fDesc.multiArrayConstraint,
               (c.dataType == .float32 || c.dataType == .float16) {
                logitsFeatureName = name
                break
            }
        }
    }

    // MARK: - 推論（公開API）

    /// ハイブリッド分類: ルールベースで確実なフィールドを先に抽出し、
    /// 未分類行のみLLMに送って名前・役職・部署を判定する。
    /// モデル未ロード・推論失敗時は nil を返す（呼び出し元はフォールバックへ進む）。
    func classify(lines: [String]) async -> CardFieldClassifier.ParsedCard? {
        // アプリ再起動後に未ロードの場合はここでロードする
        if loadedModel == nil || tokenizer == nil {
            await MainActor.run { isInferencing = true }
            try? loadModelIfNeeded()
        }
        guard let model = loadedModel, let tok = tokenizer else {
            await MainActor.run { isInferencing = false }
            return nil
        }

        await MainActor.run { isInferencing = true }
        defer { Task { @MainActor in self.isInferencing = false } }

        // --- Step 1: ルールベースで確実なフィールドを先に抽出 ---
        let ruleResult = CardFieldClassifier().classifyStructuredFields(lines: lines)
        let baseParsed = ruleResult.parsed

        // 未分類行が空ならLLM不要（全フィールドがルールで解決済み）
        guard !ruleResult.unclassifiedLines.isEmpty else {
            return baseParsed
        }

        // --- Step 2: 未分類行のみをLLMに送る ---
        let prompt   = buildChatMLPrompt(
            unclassifiedLines: ruleResult.unclassifiedLines,
            knownCompany: baseParsed.company
        )
        let inputIds = tok.encode(prompt)

        do {
            let output = try await runGenerationWithTimeout(
                model: model, tokenizer: tok, inputIds: inputIds, timeoutSeconds: 10
            )
            guard let llmResult = parseJSON(output) else { return baseParsed }

            // --- Step 3: ルールベース結果とLLM結果をマージ ---
            return mergeResults(base: baseParsed, llm: llmResult)
        } catch {
            // LLMが失敗してもルールベース結果は返す
            return baseParsed
        }
    }

    /// ルールベース結果にLLM結果を上書きマージする。
    /// LLMは名前・役職・部署のみ返すので、それ以外はルールベース結果を維持。
    private func mergeResults(base: CardFieldClassifier.ParsedCard,
                              llm: CardFieldClassifier.ParsedCard) -> CardFieldClassifier.ParsedCard {
        var merged = base
        // LLMが返した名前・役職・部署で上書き（空でない場合のみ）
        if !llm.lastName.isEmpty  { merged.lastName  = llm.lastName }
        if !llm.firstName.isEmpty { merged.firstName = llm.firstName }
        if !llm.title.isEmpty     { merged.title     = llm.title }
        if !llm.department.isEmpty { merged.department = llm.department }
        // LLMがルールベースで未取得だった会社名を補完した場合
        if merged.company.isEmpty && !llm.company.isEmpty { merged.company = llm.company }
        return merged
    }

    // MARK: - テキスト生成ループ

    /// タイムアウト付きの生成ラッパー
    private func runGenerationWithTimeout(model: MLModel,
                                          tokenizer: Qwen25Tokenizer,
                                          inputIds: [Int],
                                          timeoutSeconds: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try self.runGeneration(model: model, tokenizer: tokenizer, inputIds: inputIds)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw InferenceError.timeout
            }
            // 先に完了したタスクの結果を採用
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func runGeneration(model: MLModel,
                               tokenizer: Qwen25Tokenizer,
                               inputIds: [Int]) throws -> String {
        let promptLen    = inputIds.count
        var generatedIds = [Int]()
        let maxNewTokens = 80
        // JSONの { } をカウントして完了次第即終了（不要なトークン生成を防ぐ）
        var openBraces   = 0
        var jsonStarted  = false

        // MLState で KV キャッシュを管理（iOS 18 stateful prediction）
        let state = model.makeState()

        // --- プリフィル: プロンプト全体を一括処理 ---
        let prefillLogits = try forward(model: model, state: state,
                                        ids: inputIds, startPos: 0)

        guard let firstToken = argmaxLastToken(logits: prefillLogits, seqLen: promptLen) else {
            return ""
        }
        if firstToken == Qwen25Tokenizer.SpecialToken.imEnd
        || firstToken == Qwen25Tokenizer.SpecialToken.eot { return "" }
        generatedIds.append(firstToken)

        // 最初のトークンでブレース追跡開始
        for ch in tokenizer.decode([firstToken]) {
            if ch == "{" { openBraces += 1; jsonStarted = true }
            else if ch == "}" && jsonStarted { openBraces -= 1 }
        }
        if jsonStarted && openBraces <= 0 {
            return tokenizer.decode(generatedIds)
        }

        // --- デコード: 1 トークンずつ生成 ---
        while generatedIds.count < maxNewTokens {
            // タスクキャンセルのチェック
            if Task.isCancelled { break }

            let currentPos = promptLen + generatedIds.count - 1
            let decLogits  = try forward(model: model, state: state,
                                         ids: [generatedIds.last!], startPos: currentPos)
            guard let nextToken = argmaxLastToken(logits: decLogits, seqLen: 1) else { break }
            if nextToken == Qwen25Tokenizer.SpecialToken.imEnd
            || nextToken == Qwen25Tokenizer.SpecialToken.eot { break }
            generatedIds.append(nextToken)

            // { } をカウントしてJSONが閉じたら即終了
            for ch in tokenizer.decode([nextToken]) {
                if ch == "{" { openBraces += 1; jsonStarted = true }
                else if ch == "}" && jsonStarted { openBraces -= 1 }
            }
            if jsonStarted && openBraces <= 0 { break }
        }

        return tokenizer.decode(generatedIds)
    }

    // MARK: - Forward Pass

    /// 1 ステップの forward pass（stateful KV キャッシュ使用）
    /// - startPos: ids[0] の絶対位置（KV キャッシュ内のオフセット）
    private func forward(model: MLModel, state: MLState,
                         ids: [Int], startPos: Int) throws -> MLMultiArray {
        let seqLen = ids.count

        let inputArray = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        for (i, id) in ids.enumerated() { inputArray[i] = NSNumber(value: id) }

        var features: [String: Any] = [inputFeatureName: MLFeatureValue(multiArray: inputArray)]

        if needsAttentionMask {
            // totalLen = KV キャッシュ内の総トークン数（過去 + 現在バッチ）
            let totalLen = startPos + seqLen
            features[attentionMaskFeatureName] = MLFeatureValue(
                multiArray: try buildCausalMask(queryLen: seqLen, keyLen: totalLen))
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: features)
        let output   = try model.prediction(from: provider, using: state)

        guard let logits = output.featureValue(for: logitsFeatureName)?.multiArrayValue else {
            throw InferenceError.noLogits
        }
        return logits
    }

    /// causal_mask を構築する（テスト可能なため internal）
    /// - queryLen=1（デコード）: 全て「参照可」
    /// - queryLen>1（プリフィル）: 下三角のみ「参照可」
    /// データ型はモデルの制約に従って自動選択される:
    ///   - int32  → 1=参照可, 0=マスク（multiplicative）
    ///   - float  → 0.0=参照可, -30000.0=マスク（additive to attention score）
    func buildCausalMask(queryLen: Int, keyLen: Int) throws -> MLMultiArray {
        let dtype  = attentionMaskDataType
        let isFloat = (dtype == .float32 || dtype == .float16)
        let allowVal:  NSNumber = isFloat ? 0.0      : 1
        let blockVal:  NSNumber = isFloat ? -30000.0 : 0

        let shape: [NSNumber] = attentionMaskRank == 4
            ? [1, 1, NSNumber(value: queryLen), NSNumber(value: keyLen)]
            : [1, NSNumber(value: queryLen)]
        let mask = try MLMultiArray(shape: shape, dataType: dtype)

        if attentionMaskRank == 4 {
            for i in 0 ..< queryLen {
                let absI = keyLen - queryLen + i
                for j in 0 ..< keyLen {
                    mask[i * keyLen + j] = (j <= absI) ? allowVal : blockVal
                }
            }
        } else {
            for i in 0 ..< queryLen { mask[i] = allowVal }
        }
        return mask
    }

    private enum InferenceError: Error { case noLogits, timeout }

    // MARK: - Argmax・float16変換

    /// ロジット配列の最後のトークン位置で argmax を取り、最大値のインデックスを返す
    private func argmaxLastToken(logits: MLMultiArray, seqLen: Int) -> Int? {
        let shape   = logits.shape.map { $0.intValue }
        let strides = logits.strides.map { $0.intValue }

        // ロジットの次元数に応じてボキャブラリサイズとオフセットを決定
        // 想定される形状:
        //   [vocabSize]           (1次元: 最後のトークンのみ)
        //   [1, vocabSize]        (2次元: バッチ × vocab)
        //   [1, seqLen, vocabSize] (3次元: バッチ × シーケンス × vocab)
        let vocabSize: Int
        let baseOffset: Int
        switch shape.count {
        case 1:
            vocabSize  = shape[0]
            baseOffset = 0
        case 2:
            vocabSize  = shape[1]
            let lastRow = max(0, shape[0] - 1)
            baseOffset  = lastRow * strides[0]
        case 3:
            vocabSize   = shape[2]
            let lastPos = max(0, shape[1] - 1)
            baseOffset  = lastPos * strides[1]
        default:
            return nil
        }

        let vocabStride = strides.last ?? 1
        var maxVal: Float = -.infinity
        var argmax = 0

        switch logits.dataType {
        case .float32:
            // dataPointer を直接参照して高速に argmax を計算
            let ptr = logits.dataPointer.assumingMemoryBound(to: Float32.self)
            for v in 0 ..< vocabSize {
                let val = ptr[baseOffset + v * vocabStride]
                if val > maxVal { maxVal = val; argmax = v }
            }
        case .float16:
            // float16 → float32 変換して argmax
            let ptr = logits.dataPointer.assumingMemoryBound(to: UInt16.self)
            for v in 0 ..< vocabSize {
                let bits = ptr[baseOffset + v * vocabStride]
                let val  = float16ToFloat32(bits)
                if val > maxVal { maxVal = val; argmax = v }
            }
        default:
            // その他の型は NSNumber 経由（低速だが安全）
            for v in 0 ..< vocabSize {
                let val = logits[baseOffset + v * vocabStride].floatValue
                if val > maxVal { maxVal = val; argmax = v }
            }
        }

        return argmax
    }

    /// IEEE 754 half-precision（float16）を float32 に変換
    private func float16ToFloat32(_ bits: UInt16) -> Float {
        let sign     = UInt32(bits >> 15) << 31
        let exp16    = Int((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x3FF)
        let f32bits: UInt32
        if exp16 == 0 {
            if mantissa == 0 {
                f32bits = sign
            } else {
                // 非正規化数
                var m = mantissa
                var e = Int32(-14)
                while (m & 0x400) == 0 { m <<= 1; e -= 1 }
                m &= 0x3FF
                f32bits = sign | (UInt32(e + 127) << 23) | (m << 13)
            }
        } else if exp16 == 31 {
            f32bits = sign | 0x7F800000 | (mantissa << 13)  // inf または NaN
        } else {
            f32bits = sign | (UInt32(exp16 - 15 + 127) << 23) | (mantissa << 13)
        }
        return Float(bitPattern: f32bits)
    }

    // MARK: - プロンプト構築（ChatML 形式）

    /// ハイブリッド方式用: 未分類行のみを対象に名前・役職・部署を問う簡潔なプロンプト
    func buildChatMLPrompt(unclassifiedLines: [String], knownCompany: String) -> String {
        let rawText = unclassifiedLines.joined(separator: "\n")
        let companyHint = knownCompany.isEmpty ? "" : "\n会社名「\(knownCompany)」は判明済みです。"
        return "<|im_start|>system\nJSONのみ出力。説明不要。<|im_end|>\n<|im_start|>user\n以下は名刺の未分類テキストです。\(companyHint)\nlastName,firstName,company,department,titleをJSONで出力。不明は空文字。\n\n\(rawText)<|im_end|>\n<|im_start|>assistant\n"
    }

    /// 旧API互換: 全行を渡すプロンプト（テスト用に残す）
    func buildChatMLPrompt(lines: [String]) -> String {
        let rawText = lines.joined(separator: "\n")
        return "<|im_start|>system\nJSONのみ出力。説明不要。<|im_end|>\n<|im_start|>user\n以下は名刺のテキストです。lastName,firstName,company,department,title,phone,email,address,websiteをJSONで出力。不明は空文字。\n\n\(rawText)<|im_end|>\n<|im_start|>assistant\n"
    }

    // MARK: - JSON パース

    func parseJSON(_ text: String) -> CardFieldClassifier.ParsedCard? {
        // モデル出力から ```json ``` フェンスや前後の空白を除去
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```",     with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let start = cleaned.firstIndex(of: "{") else { return nil }
        let fromBrace = String(cleaned[start...])

        // 閉じ括弧がない（途中打ち切り）場合は補完して試みる
        let jsonStr: String
        if let end = fromBrace.lastIndex(of: "}") {
            jsonStr = String(fromBrace[fromBrace.startIndex...end])
        } else {
            jsonStr = fromBrace + "}"
        }

        guard let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }

        var result = CardFieldClassifier.ParsedCard()
        result.lastName   = dict["lastName"]   ?? ""
        result.firstName  = dict["firstName"]  ?? ""
        result.company    = dict["company"]    ?? ""
        result.department = dict["department"] ?? ""
        result.title      = dict["title"]      ?? ""
        if let phone = dict["phone"], !phone.isEmpty { result.phones = [phone] }
        result.email      = dict["email"]      ?? ""
        result.address    = dict["address"]    ?? ""
        result.website    = dict["website"]    ?? ""
        return result
    }

    // MARK: - モデルダウンロード

    /// ユーザーの同意後に呼び出す。@Published プロパティで進捗を通知する。
    func downloadModel() async throws {
        await MainActor.run {
            isDownloading    = true
            downloadProgress = 0.0
        }
        defer { Task { @MainActor in self.isDownloading = false } }

        let dir = modelDirURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let totalBytes = modelFiles.reduce(0) { $0 + $1.approxBytes } + tokenizerApproxBytes
        var downloadedBytes: Int64 = 0

        let session = URLSession(configuration: .default)

        // モデルファイルをダウンロード
        let modelDir = modelFileURL
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        for (relativePath, approxBytes) in modelFiles {
            let fileURL   = modelFileURL.appendingPathComponent(relativePath)
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            let remoteURL = URL(string: "\(hfModelBase)/\(relativePath)")!
            let (tempURL, _) = try await session.download(from: remoteURL)
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: tempURL, to: fileURL)

            downloadedBytes += approxBytes
            let p = min(Double(downloadedBytes) / Double(totalBytes), 1.0)
            await MainActor.run { self.downloadProgress = p }
        }

        // tokenizer.json をダウンロード
        let tokURL = URL(string: tokenizerSource)!
        let (tokTemp, _) = try await session.download(from: tokURL)
        try? FileManager.default.removeItem(at: tokenizerFileURL)
        try FileManager.default.moveItem(at: tokTemp, to: tokenizerFileURL)

        downloadedBytes += tokenizerApproxBytes
        await MainActor.run { self.downloadProgress = 1.0 }

        // ロード確認
        try loadModelIfNeeded()
        await MainActor.run { self.isModelAvailable = true }
    }

    // MARK: - モデル削除

    func deleteModel() throws {
        guard isModelAvailable else { return }
        try FileManager.default.removeItem(at: modelDirURL)
        loadedModel      = nil
        tokenizer        = nil
        isModelAvailable = false
    }

    // MARK: - モデルファイルサイズ

    var modelFileSize: Int64? {
        guard isModelAvailable else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: modelDirURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var total: Int64 = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total > 0 ? total : nil
    }
}
