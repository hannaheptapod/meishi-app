import SwiftUI
import UIKit

// 名刺詳細画面
struct CardDetailView: View {

    @ObservedObject var card: BusinessCard

    @EnvironmentObject private var listViewModel: CardListViewModel
    @EnvironmentObject private var navigationState: AppNavigationState
    @Environment(\.openURL) private var openURL
    @State private var isShowingEditForm = false
    @State private var exportItem: ExportItem? = nil
    @State private var alertMessage: String? = nil
    @State private var isShowingAlert = false
    @State private var isShowingCardImage = false

    private let contactsService = ContactsService.shared
    private let exportService   = ExportService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xLarge) {
                CardImageHero(
                    imageData: card.imageData,
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
                detailActions

                if !card.phoneList.isEmpty || !(card.email ?? "").isEmpty {
                    titledSurface("連絡先") {
                        ForEach(card.phoneList, id: \.self) { phone in
                            InformationRow(
                                title: "電話",
                                value: phone,
                                systemImage: "phone",
                                actionLabel: "\(phone)へ電話",
                                action: telephoneAction(phone)
                            )
                        }
                        if let email = card.email, !email.isEmpty {
                            InformationRow(
                                title: "メール",
                                value: email,
                                systemImage: "envelope",
                                actionLabel: "\(email)へメール",
                                action: urlAction(URL(string: "mailto:\(email)"))
                            )
                        }
                    }
                }

                if hasOtherInformation {
                    titledSurface("その他") {
                        if let address = card.address, !address.isEmpty {
                            InformationRow(
                                title: "住所",
                                value: address,
                                systemImage: "mappin.and.ellipse",
                                actionLabel: "地図で開く",
                                action: mapAction(address)
                            )
                        }
                        if let website = card.website, !website.isEmpty {
                            InformationRow(
                                title: "Webサイト",
                                value: website,
                                systemImage: "globe",
                                actionLabel: "ブラウザで開く",
                                action: urlAction(ExternalURLNormalizer.websiteURL(from: website))
                            )
                        }
                        if let notes = card.notes, !notes.isEmpty {
                            InformationRow(title: "メモ", value: notes, systemImage: "note.text")
                        }
                    }
                }

                if !card.tagArray.isEmpty || card.createdAt != nil {
                    titledSurface("タグ・登録情報") {
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
                            InformationRow(
                                title: "登録日時",
                                value: createdAt.formatted(date: .abbreviated, time: .shortened),
                                systemImage: "calendar"
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: AppTheme.contentMaximumWidth)
            .padding(.horizontal, AppTheme.Spacing.large)
            .padding(.vertical, AppTheme.Spacing.xLarge)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.background.ignoresSafeArea())
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
        }
        .onAppear { navigationState.isRootBarHidden = true }
        .onDisappear { navigationState.isRootBarHidden = false }
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

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            if !card.fullNameReading.isEmpty {
                Text(card.fullNameReading)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(card.fullName.isEmpty ? "（名前なし）" : card.fullName)
                .font(.largeTitle.weight(.bold))
            if let company = card.company, !company.isEmpty {
                Text(company)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
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
    }

    private var detailActions: some View {
        HStack(spacing: AppTheme.Spacing.medium) {
            Button {
                Task { await exportToContacts() }
            } label: {
                Label("連絡先に保存", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glass)

            Button {
                shareVCard()
            } label: {
                Label("共有", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glass)
        }
    }

    private var initials: String {
        let last = card.lastName?.first.map(String.init) ?? ""
        let first = card.firstName?.first.map(String.init) ?? ""
        return last + first
    }

    private var hasOtherInformation: Bool {
        !(card.address ?? "").isEmpty
            || !(card.website ?? "").isEmpty
            || !(card.notes ?? "").isEmpty
    }

    private func titledSurface<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppTheme.Spacing.xSmall)
            ContentSurface(content: content)
        }
    }

    private func urlAction(_ url: URL?) -> (() -> Void)? {
        guard let url else { return nil }
        return { openURL(url) }
    }

    private func telephoneAction(_ phone: String) -> (() -> Void)? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        return urlAction(URL(string: "tel:\(digits)"))
    }

    private func mapAction(_ address: String) -> (() -> Void)? {
        guard let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return urlAction(URL(string: "maps://?q=\(encoded)"))
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
