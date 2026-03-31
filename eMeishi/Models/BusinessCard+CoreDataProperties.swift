import CoreData
import Foundation

extension BusinessCard {

    // MARK: - フェッチリクエスト

    @nonobjc public class func fetchRequest() -> NSFetchRequest<BusinessCard> {
        return NSFetchRequest<BusinessCard>(entityName: "BusinessCard")
    }

    // MARK: - 属性

    @NSManaged public var id: UUID?
    @NSManaged public var lastName: String?
    @NSManaged public var lastNameReading: String?
    @NSManaged public var firstName: String?
    @NSManaged public var firstNameReading: String?
    @NSManaged public var company: String?
    @NSManaged public var companyReading: String?
    @NSManaged public var department: String?
    @NSManaged public var title: String?
    @NSManaged public var email: String?
    @NSManaged public var phone: String?
    @NSManaged public var address: String?
    @NSManaged public var website: String?
    @NSManaged public var notes: String?
    @NSManaged public var imageData: Data?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var isFavorite: Bool
    @NSManaged public var tags: NSSet?

    // MARK: - タグ操作

    /// 紐づくタグの配列（名前順）
    public var tagArray: [Tag] {
        let set = tags as? Set<Tag> ?? []
        return set.sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    @objc(addTagsObject:)
    @NSManaged public func addToTags(_ value: Tag)

    @objc(removeTagsObject:)
    @NSManaged public func removeFromTags(_ value: Tag)

    @objc(addTags:)
    @NSManaged public func addToTags(_ values: NSSet)

    @objc(removeTags:)
    @NSManaged public func removeFromTags(_ values: NSSet)

    // MARK: - 計算プロパティ

    /// phone フィールドを改行区切りで分割した電話番号リスト
    public var phoneList: [String] {
        guard let phone = phone, !phone.isEmpty else { return [] }
        return phone.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// アバター表示用のイニシャルを返す（姓・名の先頭各1文字、どちらも空なら会社名の先頭1文字）
    public var initials: String {
        let last  = lastName?.prefix(1)  ?? ""
        let first = firstName?.prefix(1) ?? ""
        if last.isEmpty && first.isEmpty {
            return String(company?.prefix(1).uppercased() ?? "?")
        }
        return "\(last)\(first)"
    }

    /// 会社名ソート用キー：読みがあればそのまま使用（保存時に法人格除去済み）、なければ漢字名から法人格を除去して返す
    public var companySortKey: String {
        let base = companyReading?.trimmingCharacters(in: .whitespaces) ?? ""
        if !base.isEmpty { return base }
        return BusinessCard.stripLegalEntityKanji(from: company ?? "")
    }

    // 法人格（ひらがな表記）を読みから除去する（CardFormViewModel での自動生成時に使用）
    static func stripLegalEntityReading(from text: String) -> String {
        LegalEntityTerms.stripReading(from: text)
    }

    // 法人格（漢字表記）をソートキーから除去（companyReading 未設定時のフォールバック用）
    static func stripLegalEntityKanji(from text: String) -> String {
        LegalEntityTerms.stripKanji(from: text)
    }

    /// 「姓読み 名読み」形式の読み仮名を返す
    public var fullNameReading: String {
        let last  = lastNameReading?.trimmingCharacters(in: .whitespaces) ?? ""
        let first = firstNameReading?.trimmingCharacters(in: .whitespaces) ?? ""
        switch (last.isEmpty, first.isEmpty) {
        case (false, false): return "\(last) \(first)"
        case (false, true):  return last
        case (true, false):  return first
        default:             return ""
        }
    }

    /// 「姓 名」形式のフルネームを返す
    public var fullName: String {
        let last  = lastName?.trimmingCharacters(in: .whitespaces) ?? ""
        let first = firstName?.trimmingCharacters(in: .whitespaces) ?? ""
        switch (last.isEmpty, first.isEmpty) {
        case (false, false): return "\(last) \(first)"
        case (false, true):  return last
        case (true, false):  return first
        default:             return ""
        }
    }
}

// List / ForEach で使えるように Identifiable 準拠
extension BusinessCard: Identifiable {}
