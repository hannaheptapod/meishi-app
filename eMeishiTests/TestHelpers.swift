import Testing
import CoreData
import CoreGraphics
@testable import eMeishi

// MARK: - テスト用ヘルパー（共有）
// eMeishiTests 全 Suite で共通して使用するファクトリ関数。

/// テスト用インメモリ CoreData コンテキストを生成する
func makeTestContext() -> NSManagedObjectContext {
    PersistenceController(inMemory: true).container.viewContext
}

/// テスト用 BusinessCard を生成する
func makeCard(
    context: NSManagedObjectContext,
    lastName: String? = nil,
    lastNameReading: String? = nil,
    firstName: String? = nil,
    firstNameReading: String? = nil,
    company: String? = nil,
    companyReading: String? = nil,
    department: String? = nil,
    title: String? = nil,
    email: String? = nil,
    phone: String? = nil,
    address: String? = nil,
    website: String? = nil,
    notes: String? = nil
) -> BusinessCard {
    let card = BusinessCard(context: context)
    card.id               = UUID()
    card.lastName         = lastName
    card.lastNameReading  = lastNameReading
    card.firstName        = firstName
    card.firstNameReading = firstNameReading
    card.company          = company
    card.companyReading   = companyReading
    card.department       = department
    card.title            = title
    card.email            = email
    card.phone            = phone
    card.address          = address
    card.website          = website
    card.notes            = notes
    card.createdAt        = Date()
    card.updatedAt        = Date()
    return card
}

/// テスト用 RecognizedLine を生成する（midX/midY で中心位置を指定）
func makeLine(
    _ text: String,
    midX: CGFloat = 0.5,
    midY: CGFloat = 0.6,
    width: CGFloat = 0.3,
    height: CGFloat = 0.05
) -> RecognizedLine {
    RecognizedLine(
        text: text,
        boundingBox: CGRect(
            x: midX - width / 2,
            y: midY - height / 2,
            width: width,
            height: height
        ),
        confidence: 1.0
    )
}
