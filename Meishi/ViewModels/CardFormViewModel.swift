import Foundation
import CoreData
import Combine
import UIKit
import FoundationModels

// 名刺の新規作成・編集フォームのViewModel
class CardFormViewModel: ObservableObject {

    @Published var lastName: String = ""
    @Published var firstName: String = ""
    @Published var company: String = ""
    @Published var title: String = ""
    @Published var email: String = ""
    @Published var phones: [String] = [""]
    @Published var address: String = ""
    @Published var website: String = ""
    @Published var notes: String = ""

    // OCR処理中フラグ・エラーメッセージ
    @Published var isProcessingOCR: Bool = false
    @Published var ocrErrorMessage: String? = nil

    // モデル未取得時にダウンロード同意アラートを表示するフラグ
    @Published var shouldPromptLLMDownload: Bool = false

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
        // 矩形検出前にオリジナル画像をいったんセットしておく（検出後に上書き）
        self.capturedImageData = image.jpegData(compressionQuality: 0.8)
        Task {
            // 矩形検出 → パースペクティブ補正済みの名刺画像を取得
            let cardImage = await ocrService.detectAndCropCard(from: image)
            // 補正済み画像で保存データを上書き
            self.capturedImageData = cardImage.jpegData(compressionQuality: 0.8)
            await populateFromOCR(image: cardImage)
        }
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
        let stored = card.phoneList
        phones    = stored.isEmpty ? [""] : stored
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
                await populateWithLocalLLMOrClassifier(lines: lines)
            }
        } catch {
            ocrErrorMessage = "OCR処理に失敗しました: \(error.localizedDescription)"
        }

        isProcessingOCR = false
    }

    // Foundation Models（Apple Intelligence）による構造化
    @available(iOS 18.0, *)
    private func populateWithFoundationModels(lines: [String]) async {
        switch SystemLanguageModel.default.availability {
        case .available:
            do {
                let rawText = lines.joined(separator: "\n")
                let session = LanguageModelSession()
                let prompt = """
                    以下は名刺から読み取ったテキストです。各フィールドに分類してください。
                    姓と名は必ず分けてください。
                    \(rawText)
                    """
                let response = try await session.respond(to: prompt, generating: ParsedCard.self)
                let parsed = response.content
                lastName  = parsed.lastName
                firstName = parsed.firstName
                company   = parsed.company
                title     = parsed.title
                phones    = parsed.phone.isEmpty ? [""] : [parsed.phone]
                email     = parsed.email
                address   = parsed.address
                website   = parsed.website
            } catch {
                await populateWithLocalLLMOrClassifier(lines: lines)
            }
        default:
            await populateWithLocalLLMOrClassifier(lines: lines)
        }
    }

    // 層2: Core ML OSSモデル → 層3: 正規表現フォールバック
    private func populateWithLocalLLMOrClassifier(lines: [String]) async {
        if !LocalLLMService.shared.isModelAvailable {
            // モデル未取得 → ダウンロード同意アラートを表示してから正規表現にフォールバック
            shouldPromptLLMDownload = true
            populateWithClassifier(lines: lines)
            return
        }

        if let parsed = await LocalLLMService.shared.classify(lines: lines) {
            // 層2: Core ML OSSモデルで構造化成功
            lastName  = parsed.lastName
            firstName = parsed.firstName
            company   = parsed.company
            title     = parsed.title
            phones    = parsed.phones.isEmpty ? [""] : parsed.phones
            email     = parsed.email
            address   = parsed.address
            website   = parsed.website
        } else {
            // 層3: 正規表現フォールバック（既存）
            populateWithClassifier(lines: lines)
        }
    }

    private func populateWithClassifier(lines: [String]) {
        let parsed = classifier.classify(lines: lines)
        lastName  = parsed.lastName
        firstName = parsed.firstName
        company   = parsed.company
        title     = parsed.title
        phones    = parsed.phones.isEmpty ? [""] : parsed.phones
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
        target.phone     = phones
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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

@Generable
struct ParsedCard {
    @Guide(description: "姓（ファミリーネーム）")  var lastName: String
    @Guide(description: "名（ファーストネーム）")  var firstName: String
    @Guide(description: "会社名")                  var company: String
    @Guide(description: "役職")                    var title: String
    @Guide(description: "電話番号")                var phone: String
    @Guide(description: "メールアドレス")          var email: String
    @Guide(description: "住所")                    var address: String
    @Guide(description: "WebサイトURL")            var website: String
}
