import Foundation
import PhotosUI
import SwiftUI

/// 写真ライブラリ画像を順序どおりに読み込み、向き正規化・名刺外周クロップ・JPEG圧縮を行う。
actor PhotoImportService {
    static let shared = PhotoImportService()

    struct Failure: Identifiable, Sendable {
        enum Reason: String, Sendable {
            case unavailable
            case unsupportedFormat
            case corruptImage
            case outOfMemory
            case cancelled
            case unknown

            var message: String {
                switch self {
                case .unavailable: "iCloudから画像を取得できませんでした"
                case .unsupportedFormat: "対応していない画像形式です"
                case .corruptImage: "画像が破損しています"
                case .outOfMemory: "画像を処理するメモリが不足しています"
                case .cancelled: "読込みがキャンセルされました"
                case .unknown: "画像を読み込めませんでした"
                }
            }
        }

        let id: String
        let index: Int
        let reason: Reason
    }

    struct Result: Sendable {
        let images: [CardImageInput]
        let failures: [Failure]
    }

    private let imageProcessor: CardImageProcessingService

    init(imageProcessor: CardImageProcessingService = .shared) {
        self.imageProcessor = imageProcessor
    }

    func importImages(from items: [PhotosPickerItem]) async -> Result {
        var images: [CardImageInput] = []
        var failures: [Failure] = []

        for (index, item) in items.prefix(10).enumerated() {
            if Task.isCancelled {
                break
            }

            do {
                guard var sourceData = try await item.loadTransferable(type: Data.self) else {
                    failures.append(Failure(id: item.itemIdentifier ?? UUID().uuidString,
                                            index: index, reason: .unavailable))
                    continue
                }
                try Task.checkCancellation()

                // 画像変換actor内で最大3000pxへ縮小してから現在の1枚だけを展開する。
                // バッチ側へは圧縮済みDataだけを返し、UIImage配列は作らない。
                let input = try await imageProcessor.prepareInput(
                    from: sourceData,
                    source: .photoLibrary
                )
                sourceData.removeAll(keepingCapacity: false)
                try Task.checkCancellation()
                images.append(input)
            } catch is CancellationError {
                failures.append(Failure(id: item.itemIdentifier ?? UUID().uuidString,
                                        index: index, reason: .cancelled))
                break
            } catch CardImageProcessingService.ProcessingError.unsupportedFormat {
                failures.append(Failure(id: item.itemIdentifier ?? UUID().uuidString,
                                        index: index, reason: .unsupportedFormat))
            } catch CardImageProcessingService.ProcessingError.corruptImage {
                failures.append(Failure(id: item.itemIdentifier ?? UUID().uuidString,
                                        index: index, reason: .corruptImage))
            } catch let error as CocoaError where error.code == .fileReadTooLarge {
                failures.append(Failure(id: item.itemIdentifier ?? UUID().uuidString,
                                        index: index, reason: .outOfMemory))
            } catch {
                failures.append(Failure(id: item.itemIdentifier ?? UUID().uuidString,
                                        index: index, reason: .unavailable))
            }
        }

        return Result(images: images, failures: failures)
    }
}
