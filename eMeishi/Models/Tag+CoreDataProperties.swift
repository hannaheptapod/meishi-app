import CoreData
import Foundation
import SwiftUI

extension Tag {

    // MARK: - フェッチリクエスト

    @nonobjc public class func fetchRequest() -> NSFetchRequest<Tag> {
        return NSFetchRequest<Tag>(entityName: "Tag")
    }

    // MARK: - 属性

    @NSManaged public var id: UUID?
    @NSManaged public var name: String?
    @NSManaged public var colorHex: String?
    @NSManaged public var sortOrder: Int16
    @NSManaged public var createdAt: Date?
    @NSManaged public var cards: NSSet?

    // MARK: - 計算プロパティ

    /// タグ名（nil安全）
    public var tagName: String {
        name ?? ""
    }

    /// SwiftUI Color に変換
    public var color: Color {
        Color(hex: colorHex ?? "#007AFF")
    }

    /// アクセシビリティ用の色名
    public var colorName: String {
        switch colorHex?.uppercased() {
        case "#007AFF": return "ブルー"
        case "#FF3B30": return "レッド"
        case "#34C759": return "グリーン"
        case "#FF9500": return "オレンジ"
        case "#AF52DE": return "パープル"
        case "#FF2D55": return "ピンク"
        case "#5AC8FA": return "ティール"
        case "#FFCC00": return "イエロー"
        default: return ""
        }
    }

    /// 紐づくカードの配列
    public var cardArray: [BusinessCard] {
        let set = cards as? Set<BusinessCard> ?? []
        return Array(set)
    }
}

// MARK: - リレーション操作

extension Tag {

    @objc(addCardsObject:)
    @NSManaged public func addToCards(_ value: BusinessCard)

    @objc(removeCardsObject:)
    @NSManaged public func removeFromCards(_ value: BusinessCard)

    @objc(addCards:)
    @NSManaged public func addToCards(_ values: NSSet)

    @objc(removeCards:)
    @NSManaged public func removeFromCards(_ values: NSSet)
}

extension Tag: Identifiable {}

// MARK: - Color hex 変換ヘルパー

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgbValue: UInt64 = 0
        scanner.scanHexInt64(&rgbValue)

        let r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = Double((rgbValue & 0x0000FF)) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}
