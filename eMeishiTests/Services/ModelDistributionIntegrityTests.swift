import Foundation
import Testing
@testable import eMeishi

struct ModelDistributionIntegrityTests {
    @Test
    func atomicInstallReplacesCompleteDirectory() async throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory
            .appendingPathComponent("ModelInstallTests-\(UUID().uuidString)", isDirectory: true)
        let target = parent.appendingPathComponent("LocalLLM", isDirectory: true)
        let staging = parent.appendingPathComponent("staging", isDirectory: true)
        defer { try? fm.removeItem(at: parent) }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appendingPathComponent("model.bin"))
        try Data("new".utf8).write(to: staging.appendingPathComponent("model.bin"))

        try await ModelInstallService().install(stagingDirectory: staging, at: target)

        #expect(try Data(contentsOf: target.appendingPathComponent("model.bin")) == Data("new".utf8))
        #expect(!fm.fileExists(atPath: staging.path))
    }

    @Test
    func manifestAcceptsOnlyCompleteValidatedModelSet() throws {
        let data = try makeManifestData()
        let manifest = try CloudKitModelService.validatedManifest(from: data, expectedVersion: "1.2.0")
        #expect(manifest.files.count == 13)
    }

    @Test
    func manifestRejectsPathTraversal() throws {
        let data = try makeManifestData(replacingPath: ("tokenizer.json", "../tokenizer.json"))
        #expect(throws: CloudKitModelService.CloudKitModelError.self) {
            _ = try CloudKitModelService.validatedManifest(from: data, expectedVersion: "1.2.0")
        }
    }

    @Test
    func manifestRejectsInvalidChunkHash() throws {
        let data = try makeManifestData(invalidChunkHash: true)
        #expect(throws: CloudKitModelService.CloudKitModelError.self) {
            _ = try CloudKitModelService.validatedManifest(from: data, expectedVersion: "1.2.0")
        }
    }

    private func makeManifestData(
        replacingPath: (String, String)? = nil,
        invalidChunkHash: Bool = false
    ) throws -> Data {
        let roots = [
            "qwen_embeddings.mlmodelc",
            "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc",
            "qwen_lm_head_lut6.mlmodelc",
        ]
        let paths = roots.flatMap { root in
            [
                "\(root)/coremldata.bin",
                "\(root)/metadata.json",
                "\(root)/model.mil",
                "\(root)/weights/weight.bin",
            ]
        } + ["tokenizer.json"]
        let validHash = String(repeating: "a", count: 64)
        let files: [[String: Any]] = paths.enumerated().map { index, originalPath in
            let path = replacingPath?.0 == originalPath ? replacingPath!.1 : originalPath
            return [
                "relativePath": path,
                "size": 1,
                "sha256": validHash,
                "chunks": [[
                    "recordName": "chunk-\(index)",
                    "size": 1,
                    "sha256": invalidChunkHash && index == 0 ? "invalid" : validHash,
                ]],
            ]
        }
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "version": "1.2.0",
            "chunkBytes": 10 * 1024 * 1024,
            "files": files,
        ])
    }
}
