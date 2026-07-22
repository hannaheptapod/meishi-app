import CoreData
import SwiftUI
import UIKit

// 名刺詳細画面
struct CardDetailView: View {

    @EnvironmentObject private var listViewModel: CardListViewModel
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.openURL) private var openURL
    @State private var presentationState = CardDetailPresentationState()
    @State private var isSavingToContacts = false
    @State private var viewLifetimeID: UUID?
    @State private var contactsExportRequestID: UUID?
    @State private var contactsExportTask: Task<Void, Never>?
    @State private var shareExportRequestID: UUID?
    @State private var shareExportTask: Task<Void, Never>?
    @State private var openURLRequestID: UUID?
    @State private var item: CardListItemSnapshot

    private let contactsService = ContactsService.shared
    private let exportService   = ExportService.shared
    private let cardDataTransferWorker = CardDataTransferWorker()

    @MainActor
    init(item: CardListItemSnapshot) {
        _item = State(initialValue: item)
    }

    var body: some View {
        let imageRequest = StoredCardImageRequest.businessCard(
            objectURI: item.id,
            imageIdentifier: item.imageIdentifier,
            coordinator: viewContext.persistentStoreCoordinator
        )
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xLarge) {
                StoredCardImageHero(
                    request: imageRequest,
                    initials: displaySnapshot.initials,
                    maximumHeight: 420,
                    showsExpansionIndicator: true,
                    onTap: imageRequest == nil ? nil : {
                        requestPresentation(.fullScreen(.cardImage(objectURI: currentCardURI)))
                    }
                )
                .accessibilityIdentifier("cardImagePreview")

                profileSection

                if !displaySnapshot.contacts.isEmpty {
                    ContentSection("連絡先") {
                        VStack(spacing: 0) {
                            ForEach(Array(displaySnapshot.contacts.enumerated()), id: \.element.id) { index, item in
                                if index > 0 {
                                    Divider()
                                }
                                DetailValueRow(
                                    title: item.title,
                                    value: item.value,
                                    isLink: item.destination != nil,
                                    actionLabel: "\(item.title)を開く",
                                    actionSystemImage: item.systemImage,
                                    action: item.destination.map { destination in
                                        { open(destination, label: item.title) }
                                    }
                                )
                            }
                        }
                    }
                }

                if !displaySnapshot.notes.isEmpty {
                    ContentSection("メモ") {
                        Text(displaySnapshot.notes)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !displaySnapshot.tags.isEmpty || displaySnapshot.createdAt != nil {
                    ContentSection("タグ・登録情報") {
                        if !displaySnapshot.tags.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(displaySnapshot.tags) { tag in
                                    HStack(spacing: 4) {
                                        Circle().fill(Color(hex: tag.colorHex)).frame(width: 8, height: 8)
                                        Text(tag.name).font(.caption)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color(hex: tag.colorHex).opacity(0.12), in: .capsule)
                                }
                            }
                        }
                        if let createdAt = displaySnapshot.createdAt {
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
                                Text("登録日時")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                            .padding(.top, displaySnapshot.tags.isEmpty ? 0 : AppTheme.Spacing.medium)
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
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: displaySnapshot.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(displaySnapshot.isFavorite ? .yellow : .secondary)
                }
                .accessibilityLabel(displaySnapshot.isFavorite ? "お気に入り解除" : "お気に入りに追加")
                .sensoryFeedback(.selection, trigger: displaySnapshot.isFavorite)

                Button("編集") {
                    requestPresentation(.sheet(.editCard(objectURI: currentCardURI)))
                }
                    .tint(Color.primary)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    startContactsExport()
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
                    if shareExportRequestID != nil {
                        Label {
                            Text("準備中")
                        } icon: {
                            ProgressView()
                        }
                    } else {
                        Label("共有", systemImage: "square.and.arrow.up")
                    }
                }
                .tint(Color.primary)
                .disabled(shareExportRequestID != nil)
                .accessibilityIdentifier("shareCardButton")
            }
        }
        .sheet(item: sheetPresentationBinding, onDismiss: {
            completeCurrentPresentationDismissal()
        }) { request in
            sheetContent(for: request)
        }
        .fullScreenCover(item: fullScreenPresentationBinding, onDismiss: {
            completeCurrentPresentationDismissal()
        }) { request in
            fullScreenContent(for: request)
        }
        .alert(item: alertPresentationBinding) { request in
            alert(for: request)
        }
        .background {
            PresentationDismissalObserver(
                activeID: activeAlertRequest?.id,
                dismissingID: dismissingAlertRequestID,
                onDismissalCompleted: completeAlertPresentationDismissal
            )
            .frame(width: 0, height: 0)
        }
        .onAppear {
            // 再表示時は前回の非同期完了を受け付けない新しい画面寿命として扱う。
            viewLifetimeID = UUID()
            refreshDisplaySnapshot()
        }
        .onChange(of: listViewModel.cardsContentRevision) { _, _ in
            refreshDisplaySnapshot()
        }
        .onDisappear {
            cancelViewOwnedWork()
        }
    }

    // MARK: - Presentation state

    private var sheetPresentationBinding: Binding<CardDetailPresentationRequest?> {
        let requestID = activeSheetRequest?.id
        return Binding(
            get: { activeSheetRequest },
            set: { request in
                guard request == nil, let requestID else { return }
                presentationState.clearActive(requestID: requestID)
            }
        )
    }

    private var fullScreenPresentationBinding: Binding<CardDetailPresentationRequest?> {
        let requestID = activeFullScreenRequest?.id
        return Binding(
            get: { activeFullScreenRequest },
            set: { request in
                guard request == nil, let requestID else { return }
                presentationState.clearActive(requestID: requestID)
            }
        )
    }

    private var alertPresentationBinding: Binding<CardDetailPresentationRequest?> {
        let requestID = activeAlertRequest?.id
        return Binding(
            get: { activeAlertRequest },
            set: { request in
                guard request == nil, let requestID else { return }
                presentationState.clearActive(requestID: requestID)
            }
        )
    }

    private var activeSheetRequest: CardDetailPresentationRequest? {
        guard let request = presentationState.active,
              case .sheet = request.destination else { return nil }
        return request
    }

    private var activeFullScreenRequest: CardDetailPresentationRequest? {
        guard let request = presentationState.active,
              case .fullScreen = request.destination else { return nil }
        return request
    }

    private var activeAlertRequest: CardDetailPresentationRequest? {
        guard let request = presentationState.active,
              case .alert = request.destination else { return nil }
        return request
    }

    @ViewBuilder
    private func sheetContent(for request: CardDetailPresentationRequest) -> some View {
        if case .sheet(let destination) = request.destination {
            switch destination {
            case .editCard(let objectURI):
                if let card = listViewModel.cardForEditing(objectURI: objectURI) {
                    CardFormView(card: card, onSave: {
                        completeEdit(requestID: request.id)
                    })
                    .environmentObject(listViewModel)
                } else {
                    unavailableSheet(
                        title: "名刺を編集できません",
                        description: "この名刺は削除されたか、同期によって更新されています。",
                        requestID: request.id
                    )
                }
            case .shareExport(let url):
                ShareSheet(activityItems: [url])
            }
        }
    }

    @ViewBuilder
    private func fullScreenContent(for request: CardDetailPresentationRequest) -> some View {
        if case .fullScreen(.cardImage(let objectURI)) = request.destination,
           let imageRequest = StoredCardImageRequest.businessCard(
               objectURI: objectURI,
               imageIdentifier: item.imageIdentifier,
               coordinator: viewContext.persistentStoreCoordinator
           ) {
            FullScreenCardImageView(
                request: imageRequest
            ) {
                presentationState.clearActive(requestID: request.id)
            }
        } else {
            ZStack {
                Color.black.ignoresSafeArea()
                ContentUnavailableView(
                    "名刺画像を表示できません",
                    systemImage: "photo.badge.exclamationmark"
                )
                .foregroundStyle(.white)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    presentationState.clearActive(requestID: request.id)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(.white)
                .padding()
                .accessibilityLabel("閉じる")
            }
        }
    }

    private func alert(for request: CardDetailPresentationRequest) -> Alert {
        guard case .alert(.message(let title, let message)) = request.destination else {
            return Alert(title: Text("エラー"))
        }
        return Alert(
            title: Text(title),
            message: Text(message),
            dismissButton: .cancel(Text("OK"))
        )
    }

    private func unavailableSheet(
        title: String,
        description: String,
        requestID: UUID
    ) -> some View {
        NavigationStack {
            ContentUnavailableView(
                title,
                systemImage: "exclamationmark.triangle",
                description: Text(description)
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") {
                        presentationState.clearActive(requestID: requestID)
                    }
                }
            }
        }
    }

    private func requestPresentation(_ destination: CardDetailPresentationDestination) {
        presentationState.request(destination)
    }

    private func completeEdit(requestID: UUID) {
        guard presentationState.active?.id == requestID else { return }
        refreshDisplaySnapshot()
        // 一覧更新はCoreData変更通知の統一路線へ任せ、sheet dismissal前の再フェッチを避ける。
        presentationState.clearActive(requestID: requestID)
    }

    private var dismissingAlertRequestID: UUID? {
        guard let request = presentationState.dismissing,
              case .alert = request.destination else { return nil }
        return request.id
    }

    private func completeAlertPresentationDismissal(requestID: UUID) {
        presentationState.presentNext(afterDismissing: requestID)
    }

    private func completeCurrentPresentationDismissal() {
        guard let requestID = presentationState.dismissing?.id else { return }
        presentationState.presentNext(afterDismissing: requestID)
    }

    private var currentCardURI: URL {
        item.id
    }

    private var displaySnapshot: CardDetailDisplaySnapshot { item.detail }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            if !displaySnapshot.fullNameReading.isEmpty {
                Text(displaySnapshot.fullNameReading)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(displaySnapshot.displayName)
                .font(.largeTitle.weight(.bold))
            if !displaySnapshot.company.isEmpty {
                Text(displaySnapshot.company)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if !displaySnapshot.affiliation.isEmpty {
                Text(displaySnapshot.affiliation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xSmall)
        .textSelection(.enabled)
    }

    private func refreshDisplaySnapshot() {
        guard let refreshed = listViewModel.listItem(for: currentCardURI) else { return }
        item = refreshed
    }

    private func toggleFavorite() {
        listViewModel.toggleFavorite(objectURI: currentCardURI)
        item = item.settingFavorite(!item.row.isFavorite)
    }

    private func open(_ destination: URL, label: String) {
        guard let lifetimeID = viewLifetimeID else { return }
        let requestID = UUID()
        openURLRequestID = requestID
        openURL(destination) { accepted in
            guard viewLifetimeID == lifetimeID,
                  openURLRequestID == requestID else { return }
            openURLRequestID = nil
            guard !accepted else { return }
            requestPresentation(
                .alert(.message(title: "リンクを開けません", message: "\(label)を開けませんでした。"))
            )
        }
    }

    // MARK: - アクション

    private func startContactsExport() {
        guard !isSavingToContacts,
              let lifetimeID = viewLifetimeID else { return }

        let requestID = UUID()
        contactsExportRequestID = requestID
        isSavingToContacts = true
        contactsExportTask = Task {
            await exportToContacts(lifetimeID: lifetimeID, requestID: requestID)
        }
    }

    private func exportToContacts(lifetimeID: UUID, requestID: UUID) async {
        guard let coordinator = viewContext.persistentStoreCoordinator else {
            guard finishContactsExport(lifetimeID: lifetimeID, requestID: requestID) else { return }
            requestPresentation(
                .alert(.message(title: "連絡先", message: "名刺データを読み込めませんでした。"))
            )
            return
        }
        let request = ContactExportRequest(
            objectURI: currentCardURI,
            coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator)
        )
        do {
            try await contactsService.export(request: request)
            guard finishContactsExport(lifetimeID: lifetimeID, requestID: requestID) else { return }
            requestPresentation(
                .alert(.message(title: "連絡先", message: "連絡先に保存しました。"))
            )
        } catch is CancellationError {
            _ = finishContactsExport(lifetimeID: lifetimeID, requestID: requestID)
        } catch {
            guard finishContactsExport(lifetimeID: lifetimeID, requestID: requestID) else { return }
            requestPresentation(
                .alert(.message(title: "連絡先", message: error.localizedDescription))
            )
        }
    }

    @discardableResult
    private func finishContactsExport(lifetimeID: UUID, requestID: UUID) -> Bool {
        guard !Task.isCancelled,
              viewLifetimeID == lifetimeID,
              contactsExportRequestID == requestID else { return false }
        contactsExportRequestID = nil
        contactsExportTask = nil
        isSavingToContacts = false
        return true
    }

    private func cancelViewOwnedWork() {
        viewLifetimeID = nil
        openURLRequestID = nil
        contactsExportRequestID = nil
        contactsExportTask?.cancel()
        contactsExportTask = nil
        isSavingToContacts = false
        shareExportRequestID = nil
        shareExportTask?.cancel()
        shareExportTask = nil
    }

    private func shareVCard() {
        guard shareExportRequestID == nil,
              let lifetimeID = viewLifetimeID,
              let coordinator = viewContext.persistentStoreCoordinator else { return }
        let requestID = UUID()
        shareExportRequestID = requestID
        let objectURI = currentCardURI
        let coordinatorReference = PersistentStoreCoordinatorReference(coordinator: coordinator)
        let worker = cardDataTransferWorker
        let exporter = exportService

        shareExportTask = Task {
            do {
                let dto = try await worker.loadCard(
                    objectURI: objectURI,
                    coordinatorReference: coordinatorReference
                )
                try Task.checkCancellation()
                let url = try await exporter.exportVCardInBackground(from: [dto])
                guard finishShareExport(lifetimeID: lifetimeID, requestID: requestID) else { return }
                requestPresentation(.sheet(.shareExport(url: url)))
            } catch is CancellationError {
                _ = finishShareExport(lifetimeID: lifetimeID, requestID: requestID)
            } catch {
                guard finishShareExport(lifetimeID: lifetimeID, requestID: requestID) else { return }
                requestPresentation(
                    .alert(
                        .message(
                            title: "共有できません",
                            message: "vCard の生成に失敗しました: \(error.localizedDescription)"
                        )
                    )
                )
            }
        }
    }

    @discardableResult
    private func finishShareExport(lifetimeID: UUID, requestID: UUID) -> Bool {
        guard !Task.isCancelled,
              viewLifetimeID == lifetimeID,
              shareExportRequestID == requestID else { return false }
        shareExportRequestID = nil
        shareExportTask = nil
        return true
    }
}

// FlowLayout, ShareSheet, ExportItem は Utilities/ に定義
