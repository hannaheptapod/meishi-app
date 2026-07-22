import PhotosUI
import SwiftUI
import UIKit

/// 追加フローを選択中タブから独立させ、完了・キャンセル後も元のタブを維持する。
struct CardAdditionFlowModifier: ViewModifier {
    @EnvironmentObject private var viewModel: CardListViewModel
    @EnvironmentObject private var navigationState: AppNavigationState

    @State private var isShowingForm = false
    @State private var batchImages: [UIImage] = []
    @State private var isReviewingBatch = false
    @State private var isShowingAddSheet = false
    @State private var pendingAddAction: AddCardAction?
    @State private var isShowingPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isImportingPhotos = false
    @State private var photoImportMessage: String?
    @State private var isShowingPendingOCRPrompt = false
    @State private var pendingOCRImages: [UIImage] = []

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isShowingForm) {
                CardFormView(onSave: {
                    viewModel.fetchCards()
                    isShowingForm = false
                })
            }
            .sheet(
                isPresented: $isShowingAddSheet,
                onDismiss: performPendingAddAction
            ) {
                AddCardSheet(
                    pendingCount: pendingOCRImages.count,
                    isImporting: isImportingPhotos,
                    onCamera: { dismissAddSheet(then: .camera) },
                    onPhotos: { dismissAddSheet(then: .photos) },
                    onManual: { dismissAddSheet(then: .manual) },
                    onResume: pendingOCRImages.isEmpty ? nil : {
                        dismissAddSheet(then: .resumePendingOCR)
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isReviewingBatch, onDismiss: {
                batchImages = []
                viewModel.fetchCards()
            }) {
                BatchReviewView(images: $batchImages, onComplete: {
                    isReviewingBatch = false
                })
                .environmentObject(viewModel)
            }
            .photosPicker(
                isPresented: $isShowingPhotoPicker,
                selection: $selectedPhotoItems,
                maxSelectionCount: 10,
                selectionBehavior: .ordered,
                matching: .images,
                preferredItemEncoding: .compatible
            )
            .onChange(of: selectedPhotoItems) { _, items in
                handlePhotoSelection(items)
            }
            .alert("写真の読込み", isPresented: Binding(
                get: { photoImportMessage != nil },
                set: { if !$0 { photoImportMessage = nil } }
            )) {
                Button("OK", role: .cancel) { photoImportMessage = nil }
            } message: {
                Text(photoImportMessage ?? "")
            }
            .alert("未完了の読み取り", isPresented: $isShowingPendingOCRPrompt) {
                Button("再開") {
                    batchImages = pendingOCRImages
                    isReviewingBatch = !batchImages.isEmpty
                }
                Button("破棄", role: .destructive) {
                    pendingOCRImages = []
                    Task { await discardPendingOCR() }
                }
            } message: {
                Text("前回中断した名刺が\(pendingOCRImages.count)枚あります。")
            }
            .onChange(of: navigationState.isCardAdditionRequested) { _, requested in
                if requested { presentRequestedAddSheetIfNeeded() }
            }
            .onAppear {
                presentRequestedAddSheetIfNeeded()
            }
            .task {
                await loadPendingOCR()
            }
    }

    private func presentRequestedAddSheetIfNeeded() {
        guard navigationState.isCardAdditionRequested else { return }
        isShowingAddSheet = true
        navigationState.consumeCardAdditionRequest()
    }

    /// 先に追加メニューを閉じ、dismiss完了後に次のモーダルを開始する。
    private func dismissAddSheet(then action: AddCardAction) {
        pendingAddAction = action
        isShowingAddSheet = false
    }

    private func performPendingAddAction() {
        guard let action = pendingAddAction else { return }
        pendingAddAction = nil

        switch action {
        case .camera:
            startCameraCapture()
        case .photos:
            selectedPhotoItems = []
            isShowingPhotoPicker = true
        case .manual:
            isShowingForm = true
        case .resumePendingOCR:
            batchImages = pendingOCRImages
            isReviewingBatch = !batchImages.isEmpty
        }
    }

    private func startCameraCapture() {
        CameraBatchCapture.shared.start { images in
            batchImages = images
            if !images.isEmpty {
                Task {
                    let inputs = images.compactMap { image in
                        image.jpegData(compressionQuality: 0.82).map {
                            CardImageInput(data: $0, source: .camera)
                        }
                    }
                    do {
                        try await PendingOCRStore.shared.persist(inputs)
                    } catch {
                        photoImportMessage = "未完了の読み取り情報を保存できませんでした。アプリ終了後の再開はできませんが、このまま確認を続けられます。"
                    }
                    isReviewingBatch = true
                }
            }
        }
    }

    private func importSelectedPhotos(_ items: [PhotosPickerItem]) async {
        isImportingPhotos = true
        defer {
            isImportingPhotos = false
            selectedPhotoItems = []
        }

        let result = await PhotoImportService.shared.importImages(from: items)
        batchImages = result.images.compactMap { UIImage(data: $0.data) }

        if batchImages.isEmpty {
            let reason = result.failures.first?.reason.message ?? "画像を読み込めませんでした"
            photoImportMessage = "読込みに失敗しました。\(reason)。もう一度お試しください。"
            return
        }

        if !result.failures.isEmpty {
            photoImportMessage = "\(batchImages.count)枚を読み込み、\(result.failures.count)枚は読み込めませんでした。"
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        do {
            try await PendingOCRStore.shared.persist(result.images)
        } catch {
            photoImportMessage = "未完了の読み取り情報を保存できませんでした。アプリ終了後の再開はできませんが、このまま確認を続けられます。"
        }
        isReviewingBatch = true
    }

    private func handlePhotoSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task { await importSelectedPhotos(items) }
    }

    private func loadPendingOCR() async {
        guard !ScreenshotMode.isActive else { return }
        do {
            let restored = try await PendingOCRStore.shared.restore()
            pendingOCRImages = restored.compactMap { UIImage(data: $0.data) }
            isShowingPendingOCRPrompt = !pendingOCRImages.isEmpty
        } catch {
            photoImportMessage = "前回の未完了読み取りを復元できませんでした。破損した一時データは設定を変えずに保持しています。"
        }
    }

    private func discardPendingOCR() async {
        do {
            try await PendingOCRStore.shared.discard()
        } catch {
            photoImportMessage = "未完了の読み取り情報を破棄できませんでした。"
        }
    }
}

extension View {
    func cardAdditionFlow() -> some View {
        modifier(CardAdditionFlowModifier())
    }
}

private enum AddCardAction {
    case camera
    case photos
    case manual
    case resumePendingOCR
}
