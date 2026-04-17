import Foundation
// MLModel は Sendable 準拠がなく、`prediction(from:)` の async 呼び出し時に
// 「sending 'self.xxxModel' risks causing data races」警告が 3 件発生する。
// CoreML 全体を `@preconcurrency` で import して抑制する。
// iOS 側で MLModel が Sendable になれば外せる見込み。
@preconcurrency import CoreML
import Accelerate
import Combine
import os

// オンデバイス Qwen3-0.6B（ANE対応 Anemll 変換版）による意味分析サービス
// モデルソース: anemll/anemll-Qwen-Qwen3-0.6B-ctx512_0.3.4
//
// アーキテクチャ: Embed + FFN Prefill（stateful KV cache） + LM Head（split 16）
// ComputeUnits: .cpuAndNeuralEngine（ANE で Transformer 層を実行）
//
// モデルファイル配置先（2通り）:
//   A) CloudKit 経由ダウンロード → ~/Library/Application Support/LocalLLM/
//   B) 開発用ローカル配置 → Documents/LocalLLM/（Finder / iTunes ファイル共有で転送）
//
// 必要ファイル構成:
//   <modelDir>/
//     qwen_embeddings.mlmodelc/        (トークン埋め込み)
//     qwen_FFN_PF_lut6.mlmodelc/      (Transformer FFN・stateful KV cache・LUT6量子化)
//     qwen_lm_head_lut6.mlmodelc/     (LM Head・logits を 16 チャンクに分割出力)
//     tokenizer.json                  (BPE トークナイザー)
@MainActor
class LocalLLMService: ObservableObject {

    static let shared = LocalLLMService()

    // MARK: - モデルファイル名

    private let embedModelName   = "qwen_embeddings.mlmodelc"
    private let ffnModelName     = "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc"
    private let lmheadModelName  = "qwen_lm_head_lut6.mlmodelc"

    // MARK: - 推論パラメータ（Anemll meta.yaml から）

    /// Anemll Qwen3-0.6B-ctx512 の最大コンテキスト長
    let maxContextLength: Int = 512
    /// FFN モデルの入力バッチサイズ（固定）
    private let batchSize: Int = 64
    /// LM Head の分割数（logits1〜logits16）
    private let splitLMHead: Int = 16
    /// 語彙サイズ（Qwen3 共通）
    private let vocabSize: Int = 151936

    // MARK: - 状態

    @Published var isModelAvailable: Bool = false
    @Published var isDownloading:    Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var isInferencing:    Bool = false

    // クラス全体が @MainActor のため全アクセスが MainActor 上で直列化される。
    // （MLModel 自体は non-Sendable だが `@preconcurrency import CoreML` で吸収）
    private(set) var embedModel:  MLModel? = nil
    private(set) var ffnModel:    MLModel? = nil
    private(set) var lmheadModel: MLModel? = nil
    private(set) var tokenizer:   Qwen25Tokenizer? = nil
    private var ffnState: MLState? = nil  // iOS 18+ stateful KV cache

    // MARK: - ファイルパス

    /// Application Support 内のモデルディレクトリ（CloudKit ダウンロード先）
    var modelDirURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLM", isDirectory: true)
    }

    /// Documents 内のモデルディレクトリ（開発用ローカル配置）
    private var localModelDirURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLM", isDirectory: true)
    }

    /// 実際に使用するモデルディレクトリ（Documents 優先、なければ Application Support）
    private var activeModelDir: URL {
        let localEmbed = localModelDirURL.appendingPathComponent(embedModelName)
        if FileManager.default.fileExists(atPath: localEmbed.path) {
            return localModelDirURL
        }
        return modelDirURL
    }

    var embedModelURL:  URL { activeModelDir.appendingPathComponent(embedModelName) }
    var ffnModelURL:    URL { activeModelDir.appendingPathComponent(ffnModelName) }
    var lmheadModelURL: URL { activeModelDir.appendingPathComponent(lmheadModelName) }
    var tokenizerFileURL: URL { activeModelDir.appendingPathComponent("tokenizer.json") }

    // 後方互換: 呼び出し元（DuplicateChecker 等）が prefillModelURL を使う場合に対応
    var prefillModelURL: URL { embedModelURL }

    private init() {
        isModelAvailable = checkModelFiles()
    }

    /// モデルファイルの存在を確認（Documents → Application Support の順）
    private func checkModelFiles() -> Bool {
        let fm = FileManager.default
        // Documents 内を先にチェック
        let localDir = localModelDirURL
        let localFiles = [embedModelName, ffnModelName, lmheadModelName, "tokenizer.json"]
        if localFiles.allSatisfy({ fm.fileExists(atPath: localDir.appendingPathComponent($0).path) }) {
            return true
        }
        // Application Support 内をチェック
        let appDir = modelDirURL
        return localFiles.allSatisfy({ fm.fileExists(atPath: appDir.appendingPathComponent($0).path) })
    }

    // MARK: - モデル管理

    func loadModelIfNeeded() throws {
        guard isModelAvailable else { return }

        // Embed モデル: .cpuOnly を使用
        // iOS 26 で .cpuAndNeuralEngine / .all 指定時に MIL→EIR 変換（ANE コンパイルパス）で
        // bad_cast が発生しロードに失敗する（error -14）。
        // .cpuOnly にすれば MIL→EIR を一切走らせないため確実にロードできる。
        // Embed はトークン埋め込みルックアップ（gather）のみで計算負荷が極めて軽く CPU で十分。
        let embedConfig = MLModelConfiguration()
        embedConfig.computeUnits = .cpuOnly

        // FFN・LMHead: ANE 必須（Transformer の重い演算はANEで実行）
        let aneConfig = MLModelConfiguration()
        aneConfig.computeUnits = .cpuAndNeuralEngine

        if embedModel == nil {
            embedModel = try MLModel(contentsOf: embedModelURL, configuration: embedConfig)
            AppLogger.llm.info("Embed モデルロード完了 (cpuOnly)")
        }
        if ffnModel == nil {
            ffnModel = try MLModel(contentsOf: ffnModelURL, configuration: aneConfig)
            AppLogger.llm.info("FFN モデルロード完了 (cpuAndNeuralEngine)")
            ffnState = ffnModel!.makeState()
        }
        if lmheadModel == nil {
            lmheadModel = try MLModel(contentsOf: lmheadModelURL, configuration: aneConfig)
            AppLogger.llm.info("LMHead モデルロード完了 (cpuAndNeuralEngine)")
        }
        if tokenizer == nil {
            tokenizer = try Qwen25Tokenizer(url: tokenizerFileURL)
        }
    }

    // MARK: - モデルロード（公開ヘルパー）

    /// モデルをロードし、利用可能なら (prefill: embedModel, tokenizer) を返す。
    /// 後方互換: prefill フィールドには embedModel を返す（forwardPrefill は内部でフル推論を実行）。
    func ensureModelLoaded() -> (prefill: MLModel, tokenizer: Qwen25Tokenizer)? {
        if embedModel == nil || tokenizer == nil {
            isModelAvailable = checkModelFiles()
            do {
                try loadModelIfNeeded()
            } catch {
                AppLogger.llm.error("モデルロードエラー: \(error)")
            }
        }
        guard let embed = embedModel, let tok = tokenizer else { return nil }
        return (prefill: embed, tokenizer: tok)
    }

    // MARK: - 推論（公開API）

    /// 未分類行のみをLLMで分類する。
    /// ルールベース前段処理は呼び出し元（CardFormViewModel）で実施済み。
    /// モデル未ロード・推論失敗時は nil を返す。
    ///
    /// 推論方式: 単一パス分類（1行1回の 3段 forward pass でカテゴリ判定）
    ///   Embed → FFN Prefill（stateful・バッチ64）→ LM Head（16 チャンク分割）
    func classifyUnclassifiedLines(_ lines: [String]) async -> CardFieldClassifier.ParsedCard? {
        if embedModel == nil || ffnModel == nil || lmheadModel == nil || tokenizer == nil {
            isInferencing = true
            isModelAvailable = checkModelFiles()
            do {
                try loadModelIfNeeded()
            } catch {
                AppLogger.llm.error("モデルロードエラー: \(error)")
            }
        }
        guard let tok = tokenizer, embedModel != nil, ffnModel != nil, lmheadModel != nil else {
            isInferencing = false
            AppLogger.llm.warning("モデル未ロード（embed=\(self.embedModel != nil, privacy: .public), ffn=\(self.ffnModel != nil, privacy: .public), lmhead=\(self.lmheadModel != nil, privacy: .public), tok=\(self.tokenizer != nil, privacy: .public)）")
            return nil
        }

        isInferencing = true
        defer { isInferencing = false }

        let timeoutSeconds: TimeInterval = 10
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let startTime = Date()

        AppLogger.llm.info("単一パス分類開始。未分類行: \(lines.count, privacy: .public)行")

        do {
            let llmResult = try await classifyByLine(tokenizer: tok, lines: lines, deadline: deadline)
            let elapsed = Date().timeIntervalSince(startTime)
            AppLogger.llm.info("分類完了。\(String(format: "%.1f", elapsed), privacy: .public)秒")

            let hasContent = !llmResult.lastName.isEmpty || !llmResult.firstName.isEmpty
                || !llmResult.title.isEmpty || !llmResult.department.isEmpty
                || !llmResult.company.isEmpty
            if !hasContent {
                AppLogger.llm.info("LLM結果が空")
                return nil
            }
            return llmResult
        } catch InferenceError.timeout {
            let elapsed = Date().timeIntervalSince(startTime)
            AppLogger.llm.warning("分類タイムアウト（\(String(format: "%.1f", elapsed), privacy: .public)秒）")
            return nil
        } catch {
            AppLogger.llm.error("分類エラー: \(error)")
            return nil
        }
    }

    // MARK: - 単一パス分類

    private enum LineCategory: String {
        case name, title, department, company, unknown
    }

    private func classifyByLine(tokenizer: Qwen25Tokenizer,
                                lines: [String],
                                deadline: Date) async throws -> CardFieldClassifier.ParsedCard {
        var result = CardFieldClassifier.ParsedCard()

        for (i, line) in lines.enumerated() {
            if Date() > deadline { throw InferenceError.timeout }

            let prompt = buildClassificationPrompt(line: line)
            let ids = tokenizer.encode(prompt)

            let stepStart = CFAbsoluteTimeGetCurrent()
            // forwardPrefill: Embed → FFN Prefill batches → LM Head → [1,1,151936] logits
            let logits = try await forwardPrefill(model: embedModel!, ids: ids, seqLen: ids.count)
            let stepMs = (CFAbsoluteTimeGetCurrent() - stepStart) * 1000

            guard let tokenId = argmaxLastToken(logits: logits) else {
                AppLogger.llm.debug("行\(i+1, privacy: .public) [ANE] \(String(format: "%.0f", stepMs), privacy: .public)ms: argmax失敗")
                continue
            }
            let decoded = tokenizer.decode([tokenId]).lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let category: LineCategory
            if decoded.hasPrefix("n") || decoded.hasPrefix("名") || decoded.hasPrefix("person") { category = .name }
            else if decoded.hasPrefix("t") || decoded.hasPrefix("役") || decoded.hasPrefix("position") { category = .title }
            else if decoded.hasPrefix("d") || decoded.hasPrefix("部") || decoded.hasPrefix("sect") { category = .department }
            else if decoded.hasPrefix("c") || decoded.hasPrefix("会") || decoded.hasPrefix("org") { category = .company }
            else { category = .unknown }

            AppLogger.llm.debug("行\(i+1, privacy: .public) [ANE] \(String(format: "%.0f", stepMs), privacy: .public)ms (\(ids.count, privacy: .public)tok): \(line, privacy: .private) → \(category.rawValue, privacy: .public) (token=\(decoded, privacy: .public) id=\(tokenId, privacy: .public))")

            switch category {
            case .name:
                let (last, first) = splitJapaneseName(line)
                if result.lastName.isEmpty { result.lastName = last }
                if result.firstName.isEmpty { result.firstName = first }
            case .title:
                if result.title.isEmpty { result.title = line.trimmingCharacters(in: .whitespaces) }
            case .department:
                if result.department.isEmpty { result.department = line.trimmingCharacters(in: .whitespaces) }
            case .company:
                if result.company.isEmpty { result.company = line.trimmingCharacters(in: .whitespaces) }
            case .unknown:
                break
            }
        }

        return result
    }

    /// 分類用 ChatML プロンプト（Qwen3 形式）
    private func buildClassificationPrompt(line: String) -> String {
        return "<|im_start|>system\nClassify the business card field. Reply with exactly one word. A person's name is typically 2-6 kanji characters, often with a space between family and given name.<|im_end|>\n<|im_start|>user\nWhat type of field is this on a Japanese business card?\n\"\(line)\"\nOptions: name, title, department, company, address, other<|im_end|>\n<|im_start|>assistant\n/no_think\n"
    }

    /// 日本語名を姓・名に分割
    private func splitJapaneseName(_ text: String) -> (lastName: String, firstName: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count >= 2 { return (parts[0], parts[1]) }
        let fwParts = trimmed.split(separator: "\u{3000}", maxSplits: 1).map(String.init)
        if fwParts.count >= 2 { return (fwParts[0], fwParts[1]) }
        return (trimmed, "")
    }

    // MARK: - Anemll 3段 Forward Pass

    /// Anemll 3段推論パイプライン（後方互換 public API）
    ///
    /// 内部的に Embed → FFN Prefill（batched stateful）→ LM Head（split 16）を実行し、
    /// 結合した [1, 1, 151936] float32 logits を返す。
    /// `model` パラメータは後方互換のために残すが内部では使用しない。
    func forwardPrefill(model: MLModel, ids: [Int], seqLen: Int) async throws -> MLMultiArray {
        guard embedModel != nil, let ffn = ffnModel, lmheadModel != nil else {
            throw InferenceError.noLogits
        }

        // コンテキスト長を超えるプロンプトは末尾 maxContextLength トークンに切り詰め
        let actualIds: [Int]
        if ids.count > maxContextLength {
            AppLogger.llm.warning("プロンプト長 \(ids.count, privacy: .public) がコンテキスト長 \(self.maxContextLength, privacy: .public) を超過。末尾トークンを使用")
            actualIds = Array(ids.suffix(maxContextLength))
        } else {
            actualIds = ids
        }
        let actualLen = actualIds.count

        // バッチ数（64 の倍数に切り上げ）
        let numBatches = (actualLen + batchSize - 1) / batchSize
        let paddedLen  = numBatches * batchSize
        let paddedIds  = actualIds + Array(repeating: 0, count: paddedLen - actualLen)

        // FFN KV キャッシュをリセット（各プロンプトで独立した推論）
        ffnState = ffn.makeState()

        var lastBatchOutput: MLMultiArray? = nil

        for batchIdx in 0..<numBatches {
            let batchStart = batchIdx * batchSize
            let batchIds   = Array(paddedIds[batchStart..<batchStart + batchSize])

            // Step 1: Embed バッチ
            let hidden = try await forwardEmbedBatch(ids: batchIds)

            // Step 2: FFN Prefill バッチ（stateful）
            let outHidden = try await forwardFFNBatch(
                hidden: hidden,
                posOffset: batchStart,
                seqLen: actualLen
            )
            lastBatchOutput = outHidden
        }

        guard let lastOutput = lastBatchOutput else { throw InferenceError.noLogits }

        // Step 3: 最後のバッチの実トークン位置の hidden state を取り出す
        let lastTokenInBatch = (actualLen - 1) % batchSize
        let finalHidden = try extractHiddenState(from: lastOutput, tokenIdx: lastTokenInBatch)

        // Step 4: LM Head → 16 チャンク logits を結合して [1, 1, 151936] を返す
        return try await forwardLMHeadToLogits(hidden: finalHidden)
    }

    // MARK: - Embed（バッチ単位）

    /// トークン ID を埋め込みベクトルに変換する（batchSize=64 固定）
    /// 入力: input_ids [1, 64] int32
    /// 出力: hidden_states [1, 64, hiddenSize] float16
    private func forwardEmbedBatch(ids: [Int]) async throws -> MLMultiArray {
        let n = ids.count  // = batchSize
        let inputArray = try MLMultiArray(shape: [1, n as NSNumber], dataType: .int32)
        let ptr = inputArray.dataPointer.assumingMemoryBound(to: Int32.self)
        for (i, id) in ids.enumerated() { ptr[i] = Int32(id) }

        let input  = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputArray)
        ])
        let output = try await embedModel!.prediction(from: input)
        guard let hidden = output.featureValue(for: "hidden_states")?.multiArrayValue else {
            throw InferenceError.noHiddenStates
        }
        return hidden
    }

    // MARK: - FFN Prefill（バッチ単位・stateful）

    /// Transformer FFN を stateful KV キャッシュ付きで実行する
    /// 入力: hidden_states [1, 64, hiddenSize] + position_ids [64] + causal_mask [1,1,64,512] + current_pos [1]
    /// 出力: output_hidden_states [1, 64, hiddenSize]（KV キャッシュは state に蓄積）
    private func forwardFFNBatch(hidden: MLMultiArray,
                                 posOffset: Int,
                                 seqLen: Int) async throws -> MLMultiArray {
        guard let state = ffnState else { throw InferenceError.noHiddenStates }

        // position_ids: [posOffset, posOffset+1, ..., posOffset+batchSize-1]
        let posArray = try MLMultiArray(shape: [batchSize as NSNumber], dataType: .int32)
        let posPtr   = posArray.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<batchSize { posPtr[i] = Int32(posOffset + i) }

        // current_pos: このバッチが終了した後のポジション
        let curPosArray = try MLMultiArray(shape: [1], dataType: .int32)
        let curPosPtr   = curPosArray.dataPointer.assumingMemoryBound(to: Int32.self)
        curPosPtr[0]    = Int32(posOffset + batchSize)

        // causal_mask [1, 1, batchSize, maxContextLength]
        let mask = try buildBatchCausalMask(batchStart: posOffset, seqLen: seqLen)

        let input  = try MLDictionaryFeatureProvider(dictionary: [
            "hidden_states": MLFeatureValue(multiArray: hidden),
            "position_ids":  MLFeatureValue(multiArray: posArray),
            "causal_mask":   MLFeatureValue(multiArray: mask),
            "current_pos":   MLFeatureValue(multiArray: curPosArray),
        ])
        let output = try await ffnModel!.prediction(from: input, using: state)
        guard let outHidden = output.featureValue(for: "output_hidden_states")?.multiArrayValue else {
            throw InferenceError.noHiddenStates
        }
        return outHidden
    }

    // MARK: - Batch Causal Mask

    /// FFN バッチ用 causal mask [1, 1, batchSize, maxContextLength]（Float16）
    ///
    /// クエリ q（ローカル位置 0..batchSize-1）の絶対位置は batchStart+q。
    /// キー k（0..maxContextLength-1）について:
    ///   k <= batchStart+q → 0.0（参照可）
    ///   k >  batchStart+q → -30000.0（マスク）
    private func buildBatchCausalMask(batchStart: Int, seqLen: Int) throws -> MLMultiArray {
        let shape: [NSNumber] = [1, 1,
                                 batchSize as NSNumber,
                                 maxContextLength as NSNumber]
        let mask = try MLMultiArray(shape: shape, dataType: .float16)

        let ptr        = mask.dataPointer.assumingMemoryBound(to: UInt16.self)
        let allowBits: UInt16 = 0x0000  // Float16:  0.0
        let blockBits: UInt16 = 0xF753  // Float16: -30000.0

        ptr.initialize(repeating: blockBits, count: batchSize * maxContextLength)

        for q in 0..<batchSize {
            let absPos     = batchStart + q
            let rowStart   = q * maxContextLength
            let allowCount = min(absPos + 1, maxContextLength)
            if allowCount > 0 {
                ptr.advanced(by: rowStart).initialize(repeating: allowBits, count: allowCount)
            }
        }
        return mask
    }

    // MARK: - Hidden State 抽出

    /// FFN 出力 [1, batchSize, hiddenSize] からトークン tokenIdx の hidden state [1, 1, hiddenSize] を取り出す
    private func extractHiddenState(from output: MLMultiArray, tokenIdx: Int) throws -> MLMultiArray {
        let shape      = output.shape.map { $0.intValue }
        let hiddenSize = shape[2]
        let stride1    = output.strides[1].intValue  // token 次元のストライド

        let result = try MLMultiArray(shape: [1, 1, hiddenSize as NSNumber], dataType: output.dataType)
        let srcOffset  = tokenIdx * stride1

        switch output.dataType {
        case .float16:
            let src = output.dataPointer.assumingMemoryBound(to: UInt16.self).advanced(by: srcOffset)
            let dst = result.dataPointer.assumingMemoryBound(to: UInt16.self)
            dst.initialize(from: src, count: hiddenSize)
        case .float32:
            let src = output.dataPointer.assumingMemoryBound(to: Float32.self).advanced(by: srcOffset)
            let dst = result.dataPointer.assumingMemoryBound(to: Float32.self)
            dst.initialize(from: src, count: hiddenSize)
        default:
            for i in 0..<hiddenSize { result[i] = output[srcOffset + i] }
        }
        return result
    }

    // MARK: - LM Head（分割 logits 結合）

    /// LM Head を実行し、16 分割 logits を結合して [1, 1, 151936] float32 を返す
    /// 入力: hidden_states [1, 1, hiddenSize]
    /// 出力: logits [1, 1, 151936] float32（argmaxLastToken 互換）
    private func forwardLMHeadToLogits(hidden: MLMultiArray) async throws -> MLMultiArray {
        let input  = try MLDictionaryFeatureProvider(dictionary: [
            "hidden_states": MLFeatureValue(multiArray: hidden)
        ])
        let output = try await lmheadModel!.prediction(from: input)

        let result    = try MLMultiArray(shape: [1, 1, vocabSize as NSNumber], dataType: .float32)
        let resultPtr = result.dataPointer.assumingMemoryBound(to: Float32.self)
        let chunkSize = vocabSize / splitLMHead  // 9496

        for i in 1...splitLMHead {
            guard let chunk = output.featureValue(for: "logits\(i)")?.multiArrayValue else {
                throw InferenceError.noLogits
            }
            let actualChunkSize = chunk.shape.last!.intValue
            let offset          = (i - 1) * chunkSize

            switch chunk.dataType {
            case .float16:
                let ptr = chunk.dataPointer.assumingMemoryBound(to: UInt16.self)
                for j in 0..<actualChunkSize {
                    resultPtr[offset + j] = float16ToFloat32(ptr[j])
                }
            case .float32:
                let ptr = chunk.dataPointer.assumingMemoryBound(to: Float32.self)
                for j in 0..<actualChunkSize {
                    resultPtr[offset + j] = ptr[j]
                }
            default:
                for j in 0..<actualChunkSize {
                    resultPtr[offset + j] = chunk[j].floatValue
                }
            }
        }
        return result
    }

    // MARK: - エラー型

    enum InferenceError: Error { case noLogits, noHiddenStates, timeout }

    // MARK: - Argmax（後方互換 public API）

    /// logits [1, 1, vocabSize] から argmax を返す
    func argmaxLastToken(logits: MLMultiArray) -> Int? {
        let shape   = logits.shape.map { $0.intValue }
        let strides = logits.strides.map { $0.intValue }

        let vocabSz: Int
        let baseOffset: Int
        switch shape.count {
        case 1:
            vocabSz    = shape[0]
            baseOffset = 0
        case 2:
            vocabSz    = shape[1]
            baseOffset = max(0, shape[0] - 1) * strides[0]
        case 3:
            vocabSz    = shape[2]
            baseOffset = max(0, shape[1] - 1) * strides[1]
        default:
            return nil
        }

        let vocabStride = strides.last ?? 1
        var maxVal: Float = -.infinity
        var argmax = 0

        switch logits.dataType {
        case .float32:
            let ptr = logits.dataPointer.assumingMemoryBound(to: Float32.self)
            for v in 0..<vocabSz {
                let val = ptr[baseOffset + v * vocabStride]
                if val > maxVal { maxVal = val; argmax = v }
            }
        case .float16:
            let ptr = logits.dataPointer.assumingMemoryBound(to: UInt16.self)
            for v in 0..<vocabSz {
                let val = float16ToFloat32(ptr[baseOffset + v * vocabStride])
                if val > maxVal { maxVal = val; argmax = v }
            }
        default:
            for v in 0..<vocabSz {
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
                var m = mantissa
                var e = Int32(-14)
                while (m & 0x400) == 0 { m <<= 1; e -= 1 }
                m &= 0x3FF
                f32bits = sign | (UInt32(e + 127) << 23) | (m << 13)
            }
        } else if exp16 == 31 {
            f32bits = sign | 0x7F800000 | (mantissa << 13)
        } else {
            f32bits = sign | (UInt32(exp16 - 15 + 127) << 23) | (mantissa << 13)
        }
        return Float(bitPattern: f32bits)
    }

    // MARK: - モデルダウンロード

    func downloadModel() async throws {
        isDownloading    = true
        downloadProgress = 0.0
        defer { isDownloading = false }

        let dir = modelDirURL
        // 中途半端な前回ダウンロードを削除してからやり直す
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try await CloudKitModelService.shared.downloadModel(
            modelDir: dir,
            tokenizerDestination: dir.appendingPathComponent("tokenizer.json")
        ) { [weak self] p in
            self?.downloadProgress = p
        }

        isModelAvailable = checkModelFiles()
        try loadModelIfNeeded()
        isModelAvailable = true
    }

    // MARK: - モデル削除

    func deleteModel() throws {
        try? FileManager.default.removeItem(at: modelDirURL)
        embedModel   = nil
        ffnModel     = nil
        lmheadModel  = nil
        ffnState     = nil
        tokenizer    = nil
        isModelAvailable = checkModelFiles()
    }

    // MARK: - モデルファイルサイズ

    var modelFileSize: Int64? {
        guard isModelAvailable else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: activeModelDir,
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
