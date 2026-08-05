import CoreData
import SwiftUI

/// コンテキストメニュー用の読み取り専用プレビュー。通常詳細のtoolbarは持ち込まない。
struct CardPeekView: View {
    @Environment(\.managedObjectContext) private var viewContext
    private let item: CardListItemSnapshot

    init(item: CardListItemSnapshot) {
        self.item = item
    }

    var body: some View {
        let imageRequest = StoredCardImageRequest.businessCard(
            objectURI: item.id,
            imageIdentifier: item.imageIdentifier,
            coordinator: viewContext.persistentStoreCoordinator
        )
        let displaySnapshot = item.detail

        VStack(alignment: .leading, spacing: AppTheme.Spacing.large) {
            StoredCardImageHero(
                request: imageRequest,
                initials: displaySnapshot.initials,
                maximumHeight: 250,
                onTap: nil
            )

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
                if !displaySnapshot.fullNameReading.isEmpty {
                    Text(displaySnapshot.fullNameReading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(displaySnapshot.displayName)
                    .font(.title2.weight(.bold))
                if !displaySnapshot.company.isEmpty {
                    Text(displaySnapshot.company)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !displaySnapshot.previewContacts.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                    ForEach(displaySnapshot.previewContacts) { contact in
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
}
