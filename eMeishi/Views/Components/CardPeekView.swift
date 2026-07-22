import SwiftUI

/// コンテキストメニュー用の読み取り専用プレビュー。通常詳細のtoolbarは持ち込まない。
struct CardPeekView: View {
    @ObservedObject var card: BusinessCard

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.large) {
            CardImageHero(
                imageData: card.imageData,
                cacheIdentifier: CardImageCacheKey.businessCard(
                    card,
                    dataCount: card.imageData?.count ?? 0
                ),
                initials: initials,
                maximumHeight: 250,
                onTap: nil
            )

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
                if !card.fullNameReading.isEmpty {
                    Text(card.fullNameReading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(card.fullName.isEmpty ? "（名前なし）" : card.fullName)
                    .font(.title2.weight(.bold))
                if let company = card.company, !company.isEmpty {
                    Text(company)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !previewContacts.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                    ForEach(previewContacts, id: \.value) { contact in
                        Label(contact.value, systemImage: contact.systemImage)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.large)
        .frame(minWidth: 280, idealWidth: 360, maxWidth: 390, alignment: .leading)
        .background(AppTheme.background)
        .accessibilityElement(children: .contain)
    }

    private var previewContacts: [(value: String, systemImage: String)] {
        var contacts = card.phoneList.prefix(2).map { ($0, "phone") }
        if contacts.count < 2, let email = card.email, !email.isEmpty {
            contacts.append((email, "envelope"))
        }
        return Array(contacts.prefix(2))
    }

    private var initials: String {
        let last = card.lastName?.first.map(String.init) ?? ""
        let first = card.firstName?.first.map(String.init) ?? ""
        return last + first
    }
}
