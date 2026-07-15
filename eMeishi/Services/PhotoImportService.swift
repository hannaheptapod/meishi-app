import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit

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

    private enum ImportError: Error {
        case unsupportedFormat
        case corruptImage
    }

    private let ocrService: OCRService

    init(ocrService: OCRService = OCRService()) {
        self.ocrService = ocrService
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

                // UIImageで元画像を全解像度展開せず、ImageIOで最大3000pxの
                // サムネイルを直接生成する。48MP画像でもデコード時のピークを抑える。
                let normalizedJPEG = try Self.downsampledJPEGData(from: sourceData)
                sourceData.removeAll(keepingCapacity: false)
                try Task.checkCancellation()
                guard let normalizedImage = UIImage(data: normalizedJPEG) else {
                    throw ImportError.corruptImage
                }

                // 写真ライブラリ画像もカメラと同じ外周検出へ通す。
                // 妥当な矩形がなければ OCRService が正規化済み画像をそのまま返す。
                let croppedImage = await ocrService.detectAndCropCard(from: normalizedImage)
                try Task.checkCancellation()
                guard let croppedJPEG = croppedImage.jpegData(compressionQuality: 0.82) else {
                    throw ImportError.unsupportedFormat
                }
                images.append(CardImageInput(data: croppedJPEG, source: .photoLibrary))
            } catch is CancellationError {
                failures.append(Failure(id: item.itemIdentifier ?? UUID().uuidString,
                                        index: index, reason: .cancelled))
                break
            } catch ImportError.unsupportedFormat {
                failures.append(Failure(id: item.itemIdentifier ?? UUID().uuidString,
                                        index: index, reason: .unsupportedFormat))
            } catch ImportError.corruptImage {
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

    static func downsampledJPEGData(from data: Data, maxPixelSize: Int = 3_000) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else {
            throw ImportError.unsupportedFormat
        }

        let status = CGImageSourceGetStatus(source)
        guard status == .statusComplete || status == .statusIncomplete else {
            throw ImportError.corruptImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImportError.corruptImage
        }

        let image = UIImage(cgImage: thumbnail, scale: 1, orientation: .up)
        guard let jpeg = image.jpegData(compressionQuality: 0.82) else {
            throw ImportError.unsupportedFormat
        }
        return jpeg
    }
}
