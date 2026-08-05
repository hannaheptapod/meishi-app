import Testing
import CoreData
import CoreGraphics
@testable import eMeishi

// MARK: - テスト用ヘルパー（共有）
// eMeishiTests 全 Suite で共通して使用するファクトリ関数。

/// テスト用インメモリ CoreData コンテキストを生成する
@MainActor
func makeTestContext() -> NSManagedObjectContext {
    PersistenceController(inMemory: true).container.viewContext
}

/// テスト用 BusinessCard を生成する
@MainActor
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

/// テスト用 CardExportDTO を生成する（CoreData 不要・ExportService 系テスト用）
func makeDTO(
    lastName: String? = nil,
    firstName: String? = nil,
    company: String? = nil,
    department: String? = nil,
    title: String? = nil,
    email: String? = nil,
    phone: String? = nil,
    address: String? = nil,
    website: String? = nil,
    notes: String? = nil,
    createdAt: Date? = nil
) -> CardExportDTO {
    let phoneList: [String] = {
        guard let phone, !phone.isEmpty else { return [] }
        return phone.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }()
    return CardExportDTO(
        lastName: lastName,
        firstName: firstName,
        company: company,
        department: department,
        title: title,
        phoneList: phoneList,
        email: email,
        address: address,
        website: website,
        notes: notes,
        createdAt: createdAt
    )
}

/// テスト用 RecognizedLine を生成する（midX/midY で中心位置を指定）
func makeLine(
    _ text: String,
    midX: CGFloat = 0.5,
    midY: CGFloat = 0.6,
    width: CGFloat = 0.3,
    height: CGFloat = 0.05,
    confidence: Float = 1.0,
    textDirection: RecognizedTextDirection = .unknown
) -> RecognizedLine {
    RecognizedLine(
        text: text,
        boundingBox: CGRect(
            x: midX - width / 2,
            y: midY - height / 2,
            width: width,
            height: height
        ),
        confidence: confidence,
        textDirection: textDirection
    )
}
