import SwiftUI
import UIKit

// 名刺詳細画面
struct CardDetailView: View {

    @ObservedObject var card: BusinessCard

    @EnvironmentObject private var listViewModel: CardListViewModel
    @State private var isShowingEditForm = false
    @State private var exportItem: ExportItem? = nil
    @State private var alertMessage: String? = nil
    @State private var isShowingAlert = false
    @State private var isShowingCardImage = false

    private let contactsService = ContactsService.shared
    private let exportService   = ExportService.shared

    var body: some View {
        List {
            // ── 名刺画像 ──
            if let data = card.imageData, let image = UIImage(data: data) {
                Section {
                    Button {
                        isShowingCardImage = true
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 260)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.footnote.weight(.semibold))
                                    .padding(9)
                                    .glassEffect(.regular, in: .circle)
                                    .padding(8)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("名刺画像を全画面表示")
                    .accessibilityHint("ダブルタップすると画像を拡大表示します")
                    .accessibilityIdentifier("cardImagePreview")
                }
            }

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
                                    .tint(.blue)
                            } icon: {
                                Image(systemName: "phone")
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityHint("タップして電話をかける")
                        } else {
                            Label(phone, systemImage: "phone")
                                .foregroundStyle(.primary, .secondary)
                        }
                    }
                    if let email = card.email, !email.isEmpty {
                        if let url = URL(string: "mailto:\(email)") {
                            Label {
                                Link(email, destination: url)
                                    .tint(.blue)
                            } icon: {
                                Image(systemName: "envelope")
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityHint("タップしてメールを送る")
                        } else {
                            Label(email, systemImage: "envelope")
                                .foregroundStyle(.primary, .secondary)
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
                        Label {
                            if let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                               let mapURL = URL(string: "maps://?q=\(encoded)") {
                                Link(address, destination: mapURL)
                                    .tint(.blue)
                            } else {
                                Text(address)
                            }
                        } icon: {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityHint("タップして地図アプリで開く")
                    }
                    if let website = card.website, !website.isEmpty {
                        if let url = ExternalURLNormalizer.websiteURL(from: website) {
                            Label {
                                Link(website, destination: url)
                                    .tint(.blue)
                            } icon: {
                                Image(systemName: "globe")
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityHint("タップしてブラウザで開く")
                        } else {
                            Label(website, systemImage: "globe")
                                .foregroundStyle(.primary, .secondary)
                        }
                    }
                    if let notes = card.notes, !notes.isEmpty {
                        Label(notes, systemImage: "note.text")
                            .foregroundStyle(.primary, .secondary)
                    }
                }
            }

            // ── タグ ──
            if !card.tagArray.isEmpty {
                Section("タグ") {
                    FlowLayout(spacing: 6) {
                        ForEach(card.tagArray) { tag in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 8, height: 8)
                                Text(tag.tagName)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(tag.color.opacity(0.12))
                            .clipShape(Capsule())
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("タグ: \(tag.tagName)\(tag.colorName.isEmpty ? "" : "、\(tag.colorName)")")
                        }
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
        .navigationTitle("名刺詳細")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        listViewModel.toggleFavorite(card)
                    } label: {
                        Image(systemName: card.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(card.isFavorite ? .yellow : .secondary)
                    }
                    .accessibilityLabel(card.isFavorite ? "お気に入り解除" : "お気に入りに追加")
                    Button("編集") { isShowingEditForm = true }
                }
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

    // MARK: - アバター（一覧と統一して Circle）

    @ViewBuilder
    private var avatarView: some View {
        CardAvatarView(card: card, size: 58)
            .accessibilityLabel("\(card.fullName.isEmpty ? "名前なし" : card.fullName)のアバター")
    }

    // MARK: - アクション

    private func exportToContacts() async {
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

// MARK: - 名刺画像の全画面表示

private struct FullScreenCardImageView: View {
    let image: UIImage
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            ZoomableCardImageScrollView(image: image)
                .ignoresSafeArea()
                .accessibilityLabel("名刺画像")
                .accessibilityHint("ピンチ操作で拡大、ダブルタップで拡大と元のサイズを切り替えます")
                .accessibilityIdentifier("fullScreenCardImage")

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .tint(.white)
                    .accessibilityLabel("閉じる")
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Spacer()
            }
        }
        .statusBarHidden()
    }
}

/// UIScrollView標準のズームとパンを使い、ピンチ中心と慣性を自然に保つ。
private struct ZoomableCardImageScrollView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "名刺画像"
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView,
                  let imageView else { return }

            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let targetScale = min(2.5, scrollView.maximumZoomScale)
            let point = recognizer.location(in: imageView)
            let targetSize = CGSize(
                width: scrollView.bounds.width / targetScale,
                height: scrollView.bounds.height / targetScale
            )
            let targetRect = CGRect(
                x: point.x - targetSize.width / 2,
                y: point.y - targetSize.height / 2,
                width: targetSize.width,
                height: targetSize.height
            )
            scrollView.zoom(to: targetRect, animated: true)
        }
    }
}

// FlowLayout, ShareSheet, ExportItem は Utilities/ に定義
