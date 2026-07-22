import SwiftUI
import UIKit

// 名刺詳細画面
struct CardDetailView: View {

    @ObservedObject var card: BusinessCard

    @EnvironmentObject private var listViewModel: CardListViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingEditForm = false
    @State private var exportItem: ExportItem? = nil
    @State private var alertMessage: String? = nil
    @State private var isShowingAlert = false
    @State private var isShowingCardImage = false
    @State private var isSavingToContacts = false

    private let contactsService = ContactsService.shared
    private let exportService   = ExportService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xLarge) {
                CardImageHero(
                    imageData: card.imageData,
                    cacheIdentifier: imageCacheIdentifier,
                    initials: initials,
                    maximumHeight: 420,
                    onTap: card.imageData == nil ? nil : { isShowingCardImage = true }
                )
                .overlay(alignment: .bottomTrailing) {
                    if card.imageData != nil {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.footnote.weight(.semibold))
                            .padding(9)
                            .glassEffect(.regular, in: .circle)
                            .padding(8)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(card.imageData == nil ? "名刺画像なし" : "名刺画像を全画面表示")
                .accessibilityIdentifier("cardImagePreview")

                profileSection

                if !contactItems.isEmpty {
                    ContentSection("連絡先") {
                        VStack(spacing: 0) {
                            ForEach(Array(contactItems.enumerated()), id: \.element.id) { index, item in
                                if index > 0 {
                                    Divider()
                                }
                                DetailValueRow(
                                    title: item.title,
                                    value: item.value,
                                    isLink: item.destination != nil,
                                    actionLabel: "\(item.title)を開く",
                                    actionSystemImage: item.actionSystemImage,
                                    action: item.destination.map { destination in
                                        { open(destination, label: item.title) }
                                    }
                                )
                            }
                        }
                    }
                }

                if let notes = card.notes, !notes.isEmpty {
                    ContentSection("メモ") {
                        Text(notes)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !card.tagArray.isEmpty || card.createdAt != nil {
                    ContentSection("タグ・登録情報") {
                        if !card.tagArray.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(card.tagArray) { tag in
                                    HStack(spacing: 4) {
                                        Circle().fill(tag.color).frame(width: 8, height: 8)
                                        Text(tag.tagName).font(.caption)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(tag.color.opacity(0.12), in: .capsule)
                                }
                            }
                        }
                        if let createdAt = card.createdAt {
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
                                Text("登録日時")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                            .padding(.top, card.tagArray.isEmpty ? 0 : AppTheme.Spacing.medium)
                        }
                    }
                }
            }
            .frame(maxWidth: AppTheme.contentMaximumWidth)
            .padding(.horizontal, AppTheme.Spacing.large)
            .padding(.vertical, AppTheme.Spacing.xLarge)
            .frame(maxWidth: .infinity)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: detailRevision
            )
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("名刺詳細")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    listViewModel.toggleFavorite(card)
                } label: {
                    Image(systemName: card.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(card.isFavorite ? .yellow : .secondary)
                }
                .accessibilityLabel(card.isFavorite ? "お気に入り解除" : "お気に入りに追加")
                .sensoryFeedback(.selection, trigger: card.isFavorite)

                Button("編集") { isShowingEditForm = true }
                    .tint(Color.primary)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    Task { await exportToContacts() }
                } label: {
                    if isSavingToContacts {
                        Label {
                            Text("保存中")
                        } icon: {
                            ProgressView()
                        }
                    } else {
                        Label("連絡先に保存", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                .tint(Color.primary)
                .disabled(isSavingToContacts)
                .accessibilityIdentifier("saveToContactsButton")

                Spacer()

                Button {
                    shareVCard()
                } label: {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
                .tint(Color.primary)
                .accessibilityIdentifier("shareCardButton")
            }
        }
        .sheet(isPresented: $isShowingEditForm) {
            CardFormView(card: card, onSave: {
                listViewModel.fetchCards()
                isShowingEditForm = false
            })
        }
        .sheet(item: $exportItem) { item in
            ShareSheet(activityItems: [item.url])
        }
        .fullScreenCover(isPresented: $isShowingCardImage) {
            if let data = card.imageData, let image = UIImage(data: data) {
                FullScreenCardImageView(image: image) {
                    isShowingCardImage = false
                }
            }
        }
        .alert("連絡先", isPresented: $isShowingAlert, presenting: alertMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            if !card.fullNameReading.isEmpty {
                Text(card.fullNameReading)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(card.fullName.isEmpty ? "（名前なし）" : card.fullName)
                .font(.largeTitle.weight(.bold))
                .contentTransition(.interpolate)
            if let company = card.company, !company.isEmpty {
                Text(company)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
            }
            let departmentAndTitle = [card.department, card.title]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            if !departmentAndTitle.isEmpty {
                Text(departmentAndTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xSmall)
        .textSelection(.enabled)
    }

    private var initials: String {
        let last = card.lastName?.first.map(String.init) ?? ""
        let first = card.firstName?.first.map(String.init) ?? ""
        return last + first
    }

    private var imageCacheIdentifier: String {
        CardImageCacheKey.businessCard(card, dataCount: card.imageData?.count ?? 0)
    }

    private var contactItems: [ContactDetailItem] {
        var items = card.phoneList.enumerated().map { index, phone in
            ContactDetailItem(
                id: "phone-\(index)-\(phone)",
                title: "電話",
                value: phone,
                actionSystemImage: "phone.fill",
                destination: telephoneURL(phone)
            )
        }
        if let email = card.email, !email.isEmpty {
            items.append(
                ContactDetailItem(
                    id: "email-\(email)",
                    title: "メール",
                    value: email,
                    actionSystemImage: "envelope.fill",
                    destination: emailURL(email)
                )
            )
        }
        if let address = card.address, !address.isEmpty {
            items.append(
                ContactDetailItem(
                    id: "address-\(address)",
                    title: "住所",
                    value: address,
                    actionSystemImage: "arrow.triangle.turn.up.right.diamond.fill",
                    destination: mapURL(address)
                )
            )
        }
        if let website = card.website, !website.isEmpty {
            items.append(
                ContactDetailItem(
                    id: "website-\(website)",
                    title: "Webサイト",
                    value: website,
                    actionSystemImage: "safari.fill",
                    destination: ExternalURLNormalizer.websiteURL(from: website)
                )
            )
        }
        return items
    }

    private var detailRevision: String {
        [
            card.fullName,
            card.fullNameReading,
            card.company ?? "",
            card.department ?? "",
            card.title ?? "",
            card.phoneList.joined(separator: "|"),
            card.email ?? "",
            card.address ?? "",
            card.website ?? "",
            card.notes ?? "",
            card.isFavorite.description,
            card.tagArray.map(\.tagName).sorted().joined(separator: "|")
        ].joined(separator: "\u{1F}")
    }

    private func telephoneURL(_ phone: String) -> URL? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "tel"
        components.path = digits
        return components.url
    }

    private func emailURL(_ email: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        return components.url
    }

    private func mapURL(_ address: String) -> URL? {
        var components = URLComponents(string: "maps://")
        components?.queryItems = [URLQueryItem(name: "q", value: address)]
        return components?.url
    }

    private func open(_ destination: URL, label: String) {
        openURL(destination) { accepted in
            guard !accepted else { return }
            alertMessage = "\(label)を開けませんでした。"
            isShowingAlert = true
        }
    }

    // MARK: - アクション

    private func exportToContacts() async {
        guard !isSavingToContacts else { return }
        isSavingToContacts = true
        defer { isSavingToContacts = false }
        let dto = card.toExportDTO()
        do {
            try await contactsService.export(card: dto)
            alertMessage = "\(card.fullName) を連絡先に保存しました。"
            isShowingAlert = true
        } catch {
            alertMessage = error.localizedDescription
            isShowingAlert = true
        }
    }

    private func shareVCard() {
        do {
            let url = try exportService.exportVCard(from: [card.toExportDTO()])
            exportItem = ExportItem(url: url)
        } catch {
            alertMessage = "vCard の生成に失敗しました: \(error.localizedDescription)"
            isShowingAlert = true
        }
    }
}

private struct ContactDetailItem: Identifiable {
    let id: String
    let title: String
    let value: String
    let actionSystemImage: String
    let destination: URL?

}

// FlowLayout, ShareSheet, ExportItem は Utilities/ に定義
