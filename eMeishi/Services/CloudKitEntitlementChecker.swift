import Foundation

/// 実行ファイルのコード署名に CloudKit container entitlement が含まれるかを判定する。
/// Info.plist やソース上の entitlements ファイルではなく、署名済み Mach-O の
/// entitlement blob を読むため、署名時に capability が欠落した環境を弾ける。
protocol CloudKitEntitlementChecking: Sendable {
    nonisolated func canCreateContainer(identifier: String) -> Bool
}

nonisolated struct SignedCloudKitEntitlementChecker: CloudKitEntitlementChecking {
    private let containerIdentifiers: Set<String>
    private let hasCloudKitService: Bool
    private let isTestProcess: Bool

    nonisolated init(
        executableURL: URL? = Bundle.main.executableURL,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        isTestProcess = arguments.contains("-UITestMode")
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil

        guard !isTestProcess,
              let executableURL,
              let entitlements = Self.signedEntitlements(at: executableURL) else {
            containerIdentifiers = []
            hasCloudKitService = false
            return
        }

        containerIdentifiers = Set(
            entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] ?? []
        )
        let services = entitlements["com.apple.developer.icloud-services"] as? [String] ?? []
        hasCloudKitService = services.contains("CloudKit")
    }

    nonisolated func canCreateContainer(identifier: String) -> Bool {
        !isTestProcess && hasCloudKitService && containerIdentifiers.contains(identifier)
    }

    /// Mach-O の LC_CODE_SIGNATURE から XML entitlement blob を取り出す。
    /// App Store配布物を含む実際の署名結果を検査でき、外部コマンドや非公開APIを使わない。
    nonisolated static func signedEntitlements(at executableURL: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: executableURL, options: .mappedIfSafe) else {
            return nil
        }

        for sliceOffset in machOSliceOffsets(in: data) {
            guard let signatureRange = codeSignatureRange(in: data, sliceOffset: sliceOffset),
                  let entitlements = entitlementDictionary(
                    in: data,
                    signatureOffset: signatureRange.lowerBound,
                    signatureSize: signatureRange.count
                  ) else {
                continue
            }
            return entitlements
        }
        return nil
    }

    nonisolated private static func machOSliceOffsets(in data: Data) -> [Int] {
        guard let magic = data.uint32BE(at: 0) else { return [] }

        // FAT_MAGIC / FAT_MAGIC_64。各 slice の offset は big-endian。
        if magic == 0xCAFEBABE || magic == 0xCAFEBABF,
           let countValue = data.uint32BE(at: 4) {
            let count = Int(countValue)
            let is64 = magic == 0xCAFEBABF
            let stride = is64 ? 32 : 20
            return (0..<count).compactMap { index in
                let entry = 8 + index * stride
                if is64 {
                    return data.uint64BE(at: entry + 8).flatMap(Int.init(exactly:))
                }
                return data.uint32BE(at: entry + 8).map(Int.init)
            }
        }

        return [0]
    }

    nonisolated private static func codeSignatureRange(in data: Data, sliceOffset: Int) -> Range<Int>? {
        guard let magic = data.uint32LE(at: sliceOffset),
              magic == 0xFEEDFACF || magic == 0xFEEDFACE,
              let commandCountValue = data.uint32LE(at: sliceOffset + 16) else {
            return nil
        }

        let headerSize = magic == 0xFEEDFACF ? 32 : 28
        var commandOffset = sliceOffset + headerSize
        for _ in 0..<Int(commandCountValue) {
            guard let command = data.uint32LE(at: commandOffset),
                  let commandSizeValue = data.uint32LE(at: commandOffset + 4) else {
                return nil
            }
            let commandSize = Int(commandSizeValue)
            guard commandSize >= 8, commandOffset + commandSize <= data.count else { return nil }

            // LC_CODE_SIGNATURE / linkedit_data_command
            if command == 0x1D,
               let dataOffsetValue = data.uint32LE(at: commandOffset + 8),
               let dataSizeValue = data.uint32LE(at: commandOffset + 12) {
                let start = sliceOffset + Int(dataOffsetValue)
                let end = start + Int(dataSizeValue)
                guard start >= 0, end <= data.count else { return nil }
                return start..<end
            }
            commandOffset += commandSize
        }
        return nil
    }

    nonisolated private static func entitlementDictionary(
        in data: Data,
        signatureOffset: Int,
        signatureSize: Int
    ) -> [String: Any]? {
        guard data.uint32BE(at: signatureOffset) == 0xFADE0CC0,
              let blobLengthValue = data.uint32BE(at: signatureOffset + 4),
              let countValue = data.uint32BE(at: signatureOffset + 8) else {
            return nil
        }

        let blobLength = min(Int(blobLengthValue), signatureSize)
        let count = Int(countValue)
        for index in 0..<count {
            let entryOffset = signatureOffset + 12 + index * 8
            guard let relativeOffsetValue = data.uint32BE(at: entryOffset + 4) else { return nil }
            let blobOffset = signatureOffset + Int(relativeOffsetValue)
            guard blobOffset + 8 <= signatureOffset + blobLength,
                  data.uint32BE(at: blobOffset) == 0xFADE7171,
                  let entitlementLengthValue = data.uint32BE(at: blobOffset + 4) else {
                continue
            }

            let entitlementLength = Int(entitlementLengthValue)
            let payloadStart = blobOffset + 8
            let payloadEnd = blobOffset + entitlementLength
            guard entitlementLength >= 8,
                  payloadEnd <= signatureOffset + blobLength,
                  payloadEnd <= data.count else {
                continue
            }

            var payload = data.subdata(in: payloadStart..<payloadEnd)
            while payload.last == 0 { payload.removeLast() }
            guard let plist = try? PropertyListSerialization.propertyList(
                from: payload,
                options: [],
                format: nil
            ) else {
                continue
            }
            return plist as? [String: Any]
        }
        return nil
    }
}

private extension Data {
    nonisolated func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    nonisolated func uint32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    nonisolated func uint64BE(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return withUnsafeBytes {
            UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }
}
