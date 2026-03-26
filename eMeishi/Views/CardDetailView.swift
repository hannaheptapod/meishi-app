import SwiftUI

// 名刺詳細画面
struct CardDetailView: View {

    let card: BusinessCard

    @EnvironmentObject private var listViewModel: CardListViewModel
    @State private var isShowingEditForm = false
    @State private var exportItem: ExportItem? = nil
    @State private var alertMessage: String? = nil
    @State private var isShowingAlert = false

    private let contactsService = ContactsService.shared
    private let exportService   = ExportService.shared

    var body: some View {
        List {
            // ── プロフィールヘッダー ──
            Section {
                HStack(spacing: 14) {
                    avatarView
                    VStack(alignment: .leading, spacing: 3) {
                        if !card.fullNameReading.isEmpty {
                            Text(card.fullNameReading)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(card.fullName.isEmpty ? "（名前なし）" : card.fullName)
                            .font(.title3.bold())
                        if let company = card.company, !company.isEmpty {
                            Text(company)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let department = card.department, !department.isEmpty {
                            Text(department)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let title = card.title, !title.isEmpty {
                            Text(title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // ── 名刺画像（高さ上限あり） ──
            if let data = card.imageData, let image = UIImage(data: data) {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            // ── 連絡先（電話 + メール） ──
            let phoneList = card.phoneList
            let hasEmail  = !(card.email ?? "").isEmpty
            if !phoneList.isEmpty || hasEmail {
                Section("連絡先") {
                    ForEach(phoneList, id: \.self) { phone in
                        let digits = phone.filter { $0.isNumber || $0 == "+" }
                        if let url = URL(string: "tel:\(digits)") {
                            Label {
                                Link(phone, destination: url)
                            } icon: {
                                Image(systemName: "phone.fill")
                                    .foregroundStyle(.green)
                            }
                        } else {
                            Label(phone, systemImage: "phone.fill")
                        }
                    }
                    if let email = card.email, !email.isEmpty {
                        if let url = URL(string: "mailto:\(email)") {
                            Label {
                                Link(email, destination: url)
                            } icon: {
                                Image(systemName: "envelope.fill")
                                    .foregroundStyle(.blue)
                            }
                        } else {
                            Label(email, systemImage: "envelope.fill")
                        }
                    }
                }
            }

            // ── その他（住所・Web・メモ） ──
            let hasAddress = !(card.address ?? "").isEmpty
            let hasWebsite = !(card.website ?? "").isEmpty
            let hasNotes   = !(card.notes   ?? "").isEmpty
            if hasAddress || hasWebsite || hasNotes {
                Section("その他") {
                    if let address = card.address, !address.isEmpty {
                        Label(address, systemImage: "map.fill")
                            .foregroundStyle(.primary, .orange)
                    }
                    if let website = card.website, !website.isEmpty {
                        if let url = URL(string: website) {
                            Label {
                                Link(website, destination: url)
                            } icon: {
                                Image(systemName: "globe")
                                    .foregroundStyle(.indigo)
                            }
                        } else {
                            Label(website, systemImage: "globe")
                        }
                    }
                    if let notes = card.notes, !notes.isEmpty {
                        Label(notes, systemImage: "note.text")
                    }
                }
            }

            // ── 登録日時 ──
            if let createdAt = card.createdAt {
                Section {
                    Label(
                        createdAt.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "calendar"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("登録日時")
                }
            }
        }
        .navigationTitle(card.fullName.isEmpty ? "名刺詳細" : card.fullName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("編集") { isShowingEditForm = true }
            }
            // アクションを底部ツールバーに配置
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    Task { await exportToContacts() }
                } label: {
                    Label("連絡先に保存", systemImage: "person.crop.circle.badge.plus")
                }
                Spacer()
                Button {
                    shareVCard()
                } label: {
                    Label("vCard として共有", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $isShowingEditForm, onDismiss: listViewModel.fetchCards) {
            CardFormView(card: card, onSave: { isShowingEditForm = false })
        }
        .sheet(item: $exportItem) { item in
            ShareSheet(activityItems: [item.url])
        }
        .alert("連絡先", isPresented: $isShowingAlert, presenting: alertMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - アバター（一覧と統一して Circle）

    @ViewBuilder
    private var avatarView: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 58, height: 58)
            Text(card.initials)
                .font(.title3.bold())
                .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - アクション

    private func exportToContacts() async {
        do {
            try await contactsService.export(card: card)
            alertMessage = "\(card.fullName) を連絡先に保存しました。"
            isShowingAlert = true
        } catch {
            alertMessage = error.localizedDescription
            isShowingAlert = true
        }
    }

    private func shareVCard() {
        do {
            let url = try exportService.exportVCard(from: [card])
            exportItem = ExportItem(url: url)
        } catch {
            alertMessage = "vCard の生成に失敗しました: \(error.localizedDescription)"
            isShowingAlert = true
        }
    }
}

// ShareSheet と ExportItem は CardListView.swift で定義
