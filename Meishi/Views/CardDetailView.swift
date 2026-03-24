import SwiftUI

// 名刺詳細画面
struct CardDetailView: View {

    let card: BusinessCard
    let onUpdate: () -> Void

    @State private var isShowingEditForm = false

    var body: some View {
        List {
            if !card.fullName.isEmpty {
                Section("氏名") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let lastName = card.lastName, !lastName.isEmpty {
                            LabeledContent("姓", value: lastName)
                        }
                        if let firstName = card.firstName, !firstName.isEmpty {
                            LabeledContent("名", value: firstName)
                        }
                    }
                }
            }
            if let company = card.company, !company.isEmpty {
                Section("会社名") { Text(company) }
            }
            if let title = card.title, !title.isEmpty {
                Section("役職") { Text(title) }
            }
            if let phone = card.phone, !phone.isEmpty {
                Section("電話番号") {
                    let digits = phone.filter { $0.isNumber || $0 == "+" }
                    if let url = URL(string: "tel:\(digits)") {
                        Link(phone, destination: url)
                    } else {
                        Text(phone)
                    }
                }
            }
            if let email = card.email, !email.isEmpty {
                Section("メール") {
                    if let url = URL(string: "mailto:\(email)") {
                        Link(email, destination: url)
                    } else {
                        Text(email)
                    }
                }
            }
            if let address = card.address, !address.isEmpty {
                Section("住所") { Text(address) }
            }
            if let website = card.website, !website.isEmpty {
                Section("Webサイト") {
                    if let url = URL(string: website) {
                        Link(website, destination: url)
                    } else {
                        Text(website)
                    }
                }
            }
            if let notes = card.notes, !notes.isEmpty {
                Section("メモ") { Text(notes) }
            }
            if let createdAt = card.createdAt {
                Section("登録日時") {
                    Text(createdAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(card.fullName.isEmpty ? "名刺詳細" : card.fullName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("編集") { isShowingEditForm = true }
            }
        }
        .sheet(isPresented: $isShowingEditForm, onDismiss: onUpdate) {
            CardFormView(card: card, onSave: { isShowingEditForm = false })
        }
    }
}
