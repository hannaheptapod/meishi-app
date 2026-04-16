import Foundation

// BusinessCard を MainActor 外（actor 跨ぎ）で安全に渡すための値型 DTO。
// ExportService / ContactsService は本 DTO を受け取り、CoreData オブジェクトに依存しない。
struct CardExportDTO: Sendable {
    let lastName: String?
    let firstName: String?
    let company: String?
    let department: String?
    let title: String?
    let phoneList: [String]
    let email: String?
    let address: String?
    let website: String?
    let notes: String?
    let imageData: Data?
    let createdAt: Date?

    /// 「姓 名」形式（空白トリム済み）。BusinessCard.fullName と同じ挙動
    var fullName: String {
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

@MainActor
extension BusinessCard {
    func toExportDTO() -> CardExportDTO {
        CardExportDTO(
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
            imageData: imageData,
            createdAt: createdAt
        )
    }
}
