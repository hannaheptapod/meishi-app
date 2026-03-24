import CoreData
import Foundation

extension BusinessCard {

    // MARK: - フェッチリクエスト

    @nonobjc public class func fetchRequest() -> NSFetchRequest<BusinessCard> {
        return NSFetchRequest<BusinessCard>(entityName: "BusinessCard")
    }

    // MARK: - 属性

    @NSManaged public var id: UUID?
    @NSManaged public var name: String?
    @NSManaged public var company: String?
    @NSManaged public var title: String?
    @NSManaged public var email: String?
    @NSManaged public var phone: String?
    @NSManaged public var address: String?
    @NSManaged public var website: String?
    @NSManaged public var notes: String?
    @NSManaged public var imageData: Data?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?
}

// List / ForEach で使えるように Identifiable 準拠
extension BusinessCard: Identifiable {}
