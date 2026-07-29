import Accelerate
import Foundation
@preconcurrency import CoreML

/// Core MLモデルとstateful KV cacheを所有し、推論・再読込み・削除を相互排他的に実行する。
actor LocalLLMInferenceWorker {
    struct ModelPaths: Equatable, Sendable {
        let embed: URL
        let ffn: URL
        let lmhead: URL
        let tokenizer: URL
    }

    enum InferenceError: Error {
        case modelUnavailable
        case noLogits
        case noHiddenStates
        case invalidShape
    }

    private let batchSize = 64
    private let maxContextLength = 512
    private let splitLMHead = 16
    private let vocabSize = 151_936

    private var embedModel: MLModel?
    private var ffnModel: MLModel?
    private var lmheadModel: MLModel?
    private var tokenizer: Qwen25Tokenizer?
    private var ffnState: MLState?
    private var loadedPaths: ModelPaths?

    // actorはawait中に再入可能なため、明示ゲートでCore ML処理とモデル更新を直列化する。
    private var leaseIsHeld = false
    private var leaseWaiters: [CheckedContinuation<Void, Never>] = []

    func responseToken(for prompt: String, paths: ModelPaths) async throws -> String {
        await acquireLease()
        defer { releaseLease() }
        try Task.checkCancellation()
        try loadIfNeeded(paths: paths)
        guard let tokenizer else { throw InferenceError.modelUnavailable }
        let ids = tokenizer.encode(prompt)
        guard !ids.isEmpty else { throw InferenceError.noLogits }
        let logits = try await forwardPrefill(ids: ids)
        try Task.checkCancellation()
        guard let tokenID = argmaxLastToken(logits: logits) else {
            throw InferenceError.noLogits
        }
        return tokenizer.decode([tokenID])
    }

    func performModelUpdate(
        pathsAfterUpdate: ModelPaths,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        await acquireLease()
        defer { releaseLease() }
        unload()
        do {
            try await operation()
            try Task.checkCancellation()
            try loadIfNeeded(paths: pathsAfterUpdate)
        } catch {
            // 配布処理は現行ファイルを保持するため、失敗時は従来モデルの再ロードを試す。
            try? loadIfNeeded(paths: pathsAfterUpdate)
            throw error
        }
    }

    func deleteModel(directory: URL) async throws {
        await acquireLease()
        defer { releaseLease() }
        unload()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func loadIfNeeded(paths: ModelPaths) throws {
        if loadedPaths != paths {
            unload()
        }

        let embedConfig = MLModelConfiguration()
        embedConfig.computeUnits = .cpuOnly
        let aneConfig = MLModelConfiguration()
        aneConfig.computeUnits = .cpuAndNeuralEngine

        if embedModel == nil {
            embedModel = try MLModel(contentsOf: paths.embed, configuration: embedConfig)
        }
        if ffnModel == nil {
            let model = try MLModel(contentsOf: paths.ffn, configuration: aneConfig)
            ffnModel = model
            ffnState = model.makeState()
        }
        if lmheadModel == nil {
            lmheadModel = try MLModel(contentsOf: paths.lmhead, configuration: aneConfig)
        }
        if tokenizer == nil {
            tokenizer = try Qwen25Tokenizer(url: paths.tokenizer)
        }
        loadedPaths = paths
    }

    private func unload() {
        embedModel = nil
        ffnModel = nil
        lmheadModel = nil
        tokenizer = nil
        ffnState = nil
        loadedPaths = nil
    }

    private func forwardPrefill(ids: [Int]) async throws -> MLMultiArray {
        guard let ffnModel else { throw InferenceError.modelUnavailable }
        let actualIDs = ids.count > maxContextLength
            ? Array(ids.suffix(maxContextLength))
            : ids
        guard !actualIDs.isEmpty else { throw InferenceError.noLogits }

        let numberOfBatches = (actualIDs.count + batchSize - 1) / batchSize
        let paddedLength = numberOfBatches * batchSize
        let paddedIDs = actualIDs + Array(repeating: 0, count: paddedLength - actualIDs.count)
        ffnState = ffnModel.makeState()

        var lastBatchOutput: MLMultiArray?
        for batchIndex in 0..<numberOfBatches {
            try Task.checkCancellation()
            let start = batchIndex * batchSize
            let batch = Array(paddedIDs[start..<(start + batchSize)])
            let hidden = try await forwardEmbedBatch(ids: batch)
            lastBatchOutput = try await forwardFFNBatch(
                hidden: hidden,
                positionOffset: start,
                sequenceLength: actualIDs.count
            )
        }
        guard let lastBatchOutput else { throw InferenceError.noLogits }
        let tokenIndex = (actualIDs.count - 1) % batchSize
        let finalHidden = try extractHiddenState(from: lastBatchOutput, tokenIndex: tokenIndex)
        return try await forwardLMHeadToLogits(hidden: finalHidden)
    }

    private func forwardEmbedBatch(ids: [Int]) async throws -> MLMultiArray {
        guard let embedModel else { throw InferenceError.modelUnavailable }
        let inputArray = try MLMultiArray(shape: [1, ids.count as NSNumber], dataType: .int32)
        let pointer = inputArray.dataPointer.assumingMemoryBound(to: Int32.self)
        for (index, id) in ids.enumerated() { pointer[index] = Int32(id) }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputArray),
        ])
        let output = try await embedModel.prediction(from: input)
        guard let hidden = output.featureValue(for: "hidden_states")?.multiArrayValue else {
            throw InferenceError.noHiddenStates
        }
        return hidden
    }

    private func forwardFFNBatch(
        hidden: MLMultiArray,
        positionOffset: Int,
        sequenceLength: Int
    ) async throws -> MLMultiArray {
        guard let ffnModel, let ffnState else { throw InferenceError.modelUnavailable }
        let positions = try MLMultiArray(shape: [batchSize as NSNumber], dataType: .int32)
        let positionPointer = positions.dataPointer.assumingMemoryBound(to: Int32.self)
        for index in 0..<batchSize { positionPointer[index] = Int32(positionOffset + index) }

        let currentPosition = try MLMultiArray(shape: [1], dataType: .int32)
        currentPosition.dataPointer.assumingMemoryBound(to: Int32.self)[0] = Int32(positionOffset + batchSize)
        let mask = try buildBatchCausalMask(batchStart: positionOffset, sequenceLength: sequenceLength)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "hidden_states": MLFeatureValue(multiArray: hidden),
            "position_ids": MLFeatureValue(multiArray: positions),
            "causal_mask": MLFeatureValue(multiArray: mask),
            "current_pos": MLFeatureValue(multiArray: currentPosition),
        ])
        let output = try await ffnModel.prediction(from: input, using: ffnState)
        guard let hiddenOutput = output.featureValue(for: "output_hidden_states")?.multiArrayValue else {
            throw InferenceError.noHiddenStates
        }
        return hiddenOutput
    }

    private func buildBatchCausalMask(
        batchStart: Int,
        sequenceLength: Int
    ) throws -> MLMultiArray {
        let mask = try MLMultiArray(
            shape: [1, 1, batchSize as NSNumber, maxContextLength as NSNumber],
            dataType: .float16
        )
        let pointer = mask.dataPointer.assumingMemoryBound(to: UInt16.self)
        pointer.initialize(repeating: 0xF753, count: batchSize * maxContextLength)
        for query in 0..<batchSize {
            let allowCount = min(batchStart + query + 1, maxContextLength)
            if allowCount > 0 {
                pointer.advanced(by: query * maxContextLength)
                    .initialize(repeating: 0, count: allowCount)
            }
        }
        return mask
    }

    private func extractHiddenState(
        from output: MLMultiArray,
        tokenIndex: Int
    ) throws -> MLMultiArray {
        let shape = output.shape.map(\.intValue)
        guard shape.count >= 3 else { throw InferenceError.invalidShape }
        let hiddenSize = shape[2]
        let sourceOffset = tokenIndex * output.strides[1].intValue
        let result = try MLMultiArray(
            shape: [1, 1, hiddenSize as NSNumber],
            dataType: output.dataType
        )
        switch output.dataType {
        case .float16:
            result.dataPointer.assumingMemoryBound(to: UInt16.self).initialize(
                from: output.dataPointer.assumingMemoryBound(to: UInt16.self).advanced(by: sourceOffset),
                count: hiddenSize
            )
        case .float32:
            result.dataPointer.assumingMemoryBound(to: Float32.self).initialize(
                from: output.dataPointer.assumingMemoryBound(to: Float32.self).advanced(by: sourceOffset),
                count: hiddenSize
            )
        default:
            for index in 0..<hiddenSize { result[index] = output[sourceOffset + index] }
        }
        return result
    }

    private func forwardLMHeadToLogits(hidden: MLMultiArray) async throws -> MLMultiArray {
        guard let lmheadModel else { throw InferenceError.modelUnavailable }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "hidden_states": MLFeatureValue(multiArray: hidden),
        ])
        let output = try await lmheadModel.prediction(from: input)
        let result = try MLMultiArray(shape: [1, 1, vocabSize as NSNumber], dataType: .float32)
        let resultPointer = result.dataPointer.assumingMemoryBound(to: Float32.self)
        let defaultChunkSize = vocabSize / splitLMHead

        for index in 1...splitLMHead {
            guard let chunk = output.featureValue(for: "logits\(index)")?.multiArrayValue,
                  let sizeNumber = chunk.shape.last else {
                throw InferenceError.noLogits
            }
            let chunkSize = sizeNumber.intValue
            let offset = (index - 1) * defaultChunkSize
            guard offset + chunkSize <= vocabSize else { throw InferenceError.invalidShape }
            switch chunk.dataType {
            case .float16:
                let pointer = chunk.dataPointer.assumingMemoryBound(to: UInt16.self)
                for item in 0..<chunkSize { resultPointer[offset + item] = float16ToFloat32(pointer[item]) }
            case .float32:
                let pointer = chunk.dataPointer.assumingMemoryBound(to: Float32.self)
                for item in 0..<chunkSize { resultPointer[offset + item] = pointer[item] }
            default:
                for item in 0..<chunkSize { resultPointer[offset + item] = chunk[item].floatValue }
            }
        }
        return result
    }

    private func argmaxLastToken(logits: MLMultiArray) -> Int? {
        let shape = logits.shape.map(\.intValue)
        let strides = logits.strides.map(\.intValue)
        guard let vocabSize = shape.last, vocabSize > 0, let vocabStride = strides.last else { return nil }
        let totalElements = shape.reduce(1, *)
        let baseOffset = max(0, totalElements - vocabSize * vocabStride)
        var maximum = -Float.infinity
        var result = 0
        switch logits.dataType {
        case .float16:
            let pointer = logits.dataPointer.assumingMemoryBound(to: UInt16.self)
            for index in 0..<vocabSize {
                let value = float16ToFloat32(pointer[baseOffset + index * vocabStride])
                if value > maximum { maximum = value; result = index }
            }
        case .float32:
            let pointer = logits.dataPointer.assumingMemoryBound(to: Float32.self)
            for index in 0..<vocabSize {
                let value = pointer[baseOffset + index * vocabStride]
                if value > maximum { maximum = value; result = index }
            }
        default:
            for index in 0..<vocabSize {
                let value = logits[baseOffset + index * vocabStride].floatValue
                if value > maximum { maximum = value; result = index }
            }
        }
        return result
    }

    private func float16ToFloat32(_ bits: UInt16) -> Float {
        let sign = UInt32(bits >> 15) << 31
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x3FF)
        let result: UInt32
        if exponent == 0 {
            if mantissa == 0 {
                result = sign
            } else {
                var normalized = mantissa
                var adjustedExponent = Int32(-14)
                while (normalized & 0x400) == 0 { normalized <<= 1; adjustedExponent -= 1 }
                normalized &= 0x3FF
                result = sign | (UInt32(adjustedExponent + 127) << 23) | (normalized << 13)
            }
        } else if exponent == 31 {
            result = sign | 0x7F80_0000 | (mantissa << 13)
        } else {
            result = sign | (UInt32(exponent - 15 + 127) << 23) | (mantissa << 13)
        }
        return Float(bitPattern: result)
    }

    private func acquireLease() async {
        if !leaseIsHeld {
            leaseIsHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            leaseWaiters.append(continuation)
        }
    }

    private func releaseLease() {
        if leaseWaiters.isEmpty {
            leaseIsHeld = false
        } else {
            leaseWaiters.removeFirst().resume()
        }
    }
}
