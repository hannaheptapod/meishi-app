import Foundation
import CoreData
import Combine
import UIKit

// 名刺の新規作成・編集フォームのViewModel
class CardFormViewModel: ObservableObject {

    @Published var lastName: String = ""
    @Published var firstName: String = ""
    @Published var company: String = ""
    @Published var title: String = ""
    @Published var email: String = ""
    @Published var phone: String = ""
    @Published var address: String = ""
    @Published var website: String = ""
    @Published var notes: String = ""

    // OCR処理中フラグ・エラーメッセージ
    @Published var isProcessingOCR: Bool = false
    @Published var ocrErrorMessage: String? = nil

    // 撮影した名刺画像（保存用）
    var capturedImageData: Data? = nil

    // 編集中かどうかを外部から確認できるように公開
    var isEditing: Bool { card != nil }

    private let context: NSManagedObjectContext
    private var card: BusinessCard?
    private let ocrService = OCRService()
    private let classifier = CardFieldClassifier()

    // MARK: - 初期化（新規作成）

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
    }

    // MARK: - 初期化（カメラ撮影画像からOCR）

    init(image: UIImage,
         context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
        self.capturedImageData = image.jpegData(compressionQuality: 0.8)
        Task { await populateFromOCR(image: image) }
    }

    // MARK: - 初期化（既存カードの編集）

    init(card: BusinessCard,
         context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.card = card
        self.context = context
        lastName  = card.lastName  ?? ""
        firstName = card.firstName ?? ""
        company   = card.company   ?? ""
        title     = card.title     ?? ""
        email     = card.email     ?? ""
        phone     = card.phone     ?? ""
        address   = card.address   ?? ""
        website   = card.website   ?? ""
        notes     = card.notes     ?? ""
    }

    // MARK: - OCR + AI意味分析

    @MainActor
    func populateFromOCR(image: UIImage) async {
        isProcessingOCR = true
        ocrErrorMessage = nil

        do {
            let lines = try await ocrService.recognizeText(from: image)
            guard !lines.isEmpty else {
                ocrErrorMessage = "テキストを認識できませんでした"
                isProcessingOCR = false
                return
            }

            if #available(iOS 18.0, *) {
                await populateWithFoundationModels(lines: lines)
            } else {
                populateWithClassifier(lines: lines)
            }
        } catch {
            ocrErrorMessage = "OCR処理に失敗しました: \(error.localizedDescription)"
        }

        isProcessingOCR = false
    }

    // Foundation Models（Apple Intelligence）による構造化
    @available(iOS 18.0, *)
    private func populateWithFoundationModels(lines: [String]) async {
        // NOTE: FoundationModels framework をリンク後、下のコメントを外して有効化
        // シミュレータでは動作しないため実機（iPhone 15 Pro以降）でテスト
        populateWithClassifier(lines: lines)

        // switch SystemLanguageModel.default.availability {
        // case .available:
        //     do {
        //         let rawText = lines.joined(separator: "\n")
        //         let session = LanguageModelSession()
        //         let prompt = """
        //             以下は名刺から読み取ったテキストです。各フィールドに分類してください。
        //             姓と名は必ず分けてください。
        //             \(rawText)
        //             """
        //         let response = try await session.respond(to: prompt, generating: ParsedCard.self)
        //         let parsed = response.content
        //         await MainActor.run {
        //             self.lastName  = parsed.lastName
        //             self.firstName = parsed.firstName
        //             self.company   = parsed.company
        //             self.title     = parsed.title
        //             self.phone     = parsed.phone
        //             self.email     = parsed.email
        //             self.address   = parsed.address
        //             self.website   = parsed.website
        //         }
        //     } catch {
        //         populateWithClassifier(lines: lines)
        //     }
        // default:
        //     populateWithClassifier(lines: lines)
        // }
    }

    private func populateWithClassifier(lines: [String]) {
        let parsed = classifier.classify(lines: lines)
        lastName  = parsed.lastName
        firstName = parsed.firstName
        company   = parsed.company
        title     = parsed.title
        phone     = parsed.phone
        email     = parsed.email
        address   = parsed.address
        website   = parsed.website
    }

    // MARK: - 保存

    func save() {
        let target = card ?? {
            let newCard = BusinessCard(context: context)
            newCard.id = UUID()
            newCard.createdAt = Date()
            return newCard
        }()

        target.lastName  = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        target.firstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        target.company   = company.trimmingCharacters(in: .whitespacesAndNewlines)
        target.title     = title.trimmingCharacters(in: .whitespacesAndNewlines)
        target.email     = email.trimmingCharacters(in: .whitespacesAndNewlines)
        target.phone     = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        target.address   = address.trimmingCharacters(in: .whitespacesAndNewlines)
        target.website   = website.trimmingCharacters(in: .whitespacesAndNewlines)
        target.notes     = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        target.imageData = capturedImageData
        target.updatedAt = Date()

        do {
            try context.save()
        } catch {
            print("名刺の保存に失敗しました: \(error)")
        }
    }
}

// MARK: - ParsedCard（Foundation Models @Generable 定義）
// FoundationModels framework リンク後に有効化
//
// @Generable
// struct ParsedCard {
//     @Guide("姓（ファミリーネーム）")  var lastName: String
//     @Guide("名（ファーストネーム）")  var firstName: String
//     @Guide("会社名")                  var company: String
//     @Guide("役職")                    var title: String
//     @Guide("電話番号")                var phone: String
//     @Guide("メールアドレス")          var email: String
//     @Guide("住所")                    var address: String
//     @Guide("WebサイトURL")            var website: String
// }
