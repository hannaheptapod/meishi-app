import SwiftUI
import UIKit

// 名刺一覧画面
struct CardListView: View {

    @StateObject private var viewModel = CardListViewModel()
    @State private var searchText = ""
    @State private var isShowingForm = false
    @State private var isShowingCamera = false
    @State private var capturedImage: UIImage? = nil
    @State private var exportItem: ExportItem? = nil
    @State private var isShowingSettings = false

    private let exportService = ExportService()

    private var displayedCards: [BusinessCard] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return viewModel.cards }
        return viewModel.cards.filter { card in
            card.fullName.lowercased().contains(q)
            || (card.company?.lowercased().contains(q) ?? false)
            || (card.title?.lowercased().contains(q) ?? false)
            || (card.email?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.cards.isEmpty {
                    emptyState
                } else {
                    cardList
                }
            }
            .navigationTitle("名刺")
            .toolbar {
                // 左：設定・ソート・重複チェック・エクスポートをまとめた ellipsis メニュー
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        // ソート
                        Menu {
                            Picker("並び替え", selection: $viewModel.sortOrder) {
                                ForEach(CardSortOrder.allCases) { order in
                                    Label(order.rawValue, systemImage: order.systemImage).tag(order)
                                }
                            }
                        } label: {
                            Label("並び替え", systemImage: "arrow.up.arrow.down")
                        }

                        // 設定
                        Button { isShowingSettings = true } label: {
                            Label("設定", systemImage: "gearshape")
                        }

                        if !viewModel.cards.isEmpty {
                            Divider()

                            // 重複チェック
                            NavigationLink {
                                DuplicateListView(
                                    pairs: viewModel.duplicatePairs,
                                    onMerge: viewModel.fetchCards
                                )
                            } label: {
                                Label(
                                    viewModel.duplicatePairs.isEmpty
                                        ? "重複チェック"
                                        : "重複チェック（\(viewModel.duplicatePairs.count)件）",
                                    systemImage: "person.2.slash"
                                )
                            }

                            Divider()

                            Button { exportAllCSV() } label: {
                                Label("CSV としてエクスポート", systemImage: "tablecells")
                            }
                            Button { exportAllVCard() } label: {
                                Label("vCard としてエクスポート", systemImage: "person.crop.rectangle")
                            }
                        }
                    } label: {
                        // 重複がある場合は赤バッジ
                        if !viewModel.duplicatePairs.isEmpty {
                            Image(systemName: "ellipsis.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.red, .primary)
                        } else {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }

            }
            .sheet(isPresented: $isShowingForm, onDismiss: viewModel.fetchCards) {
                CardFormView(onSave: { isShowingForm = false })
            }
            .fullScreenCover(isPresented: $isShowingCamera) {
                CameraView(capturedImage: $capturedImage)
                    .ignoresSafeArea()
            }
            .sheet(item: $capturedImage, onDismiss: viewModel.fetchCards) { image in
                CardFormView(image: image, onSave: { capturedImage = nil })
            }
            .sheet(item: $exportItem) { item in
                ShareSheet(activityItems: [item.url])
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .onAppear(perform: viewModel.fetchCards)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Menu {
                        Button {
                            isShowingCamera = true
                        } label: {
                            Label("カメラで撮影", systemImage: "camera")
                        }
                        Button {
                            isShowingForm = true
                        } label: {
                            Label("手動で入力", systemImage: "square.and.pencil")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.accentColor, in: Circle())
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - サブビュー

    private var cardList: some View {
        List {
            ForEach(displayedCards) { card in
                NavigationLink {
                    CardDetailView(card: card, onUpdate: viewModel.fetchCards)
                } label: {
                    CardRowView(card: card)
                }
            }
            .onDelete { offsets in
                viewModel.deleteCards(offsets.map { displayedCards[$0] })
            }
        }
        .searchable(text: $searchText, prompt: "名前・会社名・メールで検索")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("名刺がありません")
                .font(.title3)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button {
                    isShowingCamera = true
                } label: {
                    Label("カメラで撮影", systemImage: "camera")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    isShowingForm = true
                } label: {
                    Label("手動で追加", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - エクスポート

    private func exportAllCSV() {
        do {
            let url = try exportService.exportCSV(from: viewModel.cards)
            exportItem = ExportItem(url: url)
        } catch {
            print("CSVエクスポート失敗: \(error)")
        }
    }

    private func exportAllVCard() {
        do {
            let url = try exportService.exportVCard(from: viewModel.cards)
            exportItem = ExportItem(url: url)
        } catch {
            print("vCardエクスポート失敗: \(error)")
        }
    }
}

// MARK: - 一覧行

private struct CardRowView: View {

    let card: BusinessCard

    var body: some View {
        HStack(spacing: 12) {
            // イニシャルアバター（Circle）
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Text(initials)
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(card.fullName.isEmpty ? "（名前なし）" : card.fullName)
                    .font(.headline)
                    .lineLimit(1)
                if let company = card.company, !company.isEmpty {
                    Text(company)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                let phones = card.phoneList
                let email  = card.email ?? ""
                if !phones.isEmpty || !email.isEmpty {
                    HStack(spacing: 8) {
                        if let phone = phones.first {
                            Label(phone, systemImage: "phone")
                                .lineLimit(1)
                        }
                        if !email.isEmpty && phones.isEmpty {
                            // 電話がない場合のみメールを表示（行が長くなりすぎるのを防ぐ）
                            Label(email, systemImage: "envelope")
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var initials: String {
        let last  = card.lastName?.prefix(1)  ?? ""
        let first = card.firstName?.prefix(1) ?? ""
        if last.isEmpty && first.isEmpty {
            return String(card.company?.prefix(1).uppercased() ?? "?")
        }
        return "\(last)\(first)"
    }
}

// MARK: - 共有シート

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

extension UIImage: @retroactive Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}
