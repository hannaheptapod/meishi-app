import SwiftUI
import UIKit

// 名刺一覧画面
struct CardListView: View {

    @StateObject private var viewModel = CardListViewModel()
    @State private var isShowingForm = false
    @State private var isShowingCamera = false
    @State private var capturedImage: UIImage? = nil
    @State private var exportItem: ExportItem? = nil
    @State private var isShowingExportMenu = false

    private let exportService = ExportService()

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
                // 左：エクスポート・重複チェックメニュー（名刺がある場合のみ）
                if !viewModel.cards.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu {
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
                        } label: {
                            // 重複がある場合はバッジ付きアイコン
                            if viewModel.duplicatePairs.isEmpty {
                                Image(systemName: "ellipsis.circle")
                            } else {
                                Image(systemName: "ellipsis.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.red, .primary)
                            }
                        }
                    }
                }
                // 右：カメラ・追加
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        isShowingCamera = true
                    } label: {
                        Image(systemName: "camera")
                    }
                    Button {
                        isShowingForm = true
                    } label: {
                        Image(systemName: "plus")
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
            .onAppear(perform: viewModel.fetchCards)
        }
    }

    // MARK: - サブビュー

    private var cardList: some View {
        List {
            ForEach(viewModel.cards) { card in
                NavigationLink {
                    CardDetailView(card: card, onUpdate: viewModel.fetchCards)
                } label: {
                    CardRowView(card: card)
                }
            }
            .onDelete(perform: viewModel.deleteCards)
        }
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
        VStack(alignment: .leading, spacing: 4) {
            let fullName = card.fullName
            Text(fullName.isEmpty ? "（名前なし）" : fullName)
                .font(.headline)
            if let company = card.company, !company.isEmpty {
                Text(company)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if let title = card.title, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
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

// sheet(item:) 用の Identifiable ラッパー
struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

// UIImage を sheet(item:) で使えるように Identifiable に準拠させる拡張
extension UIImage: @retroactive Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}
