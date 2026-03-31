import SwiftUI

// MARK: - 一覧行

struct CardRowView: View {

    @ObservedObject var card: BusinessCard

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Text(card.initials)
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(card.fullName.isEmpty ? "（名前なし）" : card.fullName)
                        .font(.headline)
                        .lineLimit(1)
                    if card.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                if let company = card.company, !company.isEmpty {
                    Text(company)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                let dept = card.department ?? ""
                let ttl = card.title ?? ""
                let deptTitle = [dept, ttl].filter { !$0.isEmpty }.joined(separator: " ")
                if !deptTitle.isEmpty {
                    Text(deptTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cardAccessibilityLabel)
    }

    private var cardAccessibilityLabel: String {
        var parts = [card.fullName.isEmpty ? "名前なし" : card.fullName]
        if let company = card.company, !company.isEmpty { parts.append(company) }
        if card.isFavorite { parts.append("お気に入り") }
        return parts.joined(separator: "、")
    }

}
