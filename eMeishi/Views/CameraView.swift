import SwiftUI
import UIKit
import os

// 連続撮影カメラ（UIKit のみで管理）
// fullScreenCover を使わず、UIKit の present/dismiss だけでカメラを表示・解除する。
// SwiftUI のモーダルシステムを一切経由しないため、dismiss 競合によるフリーズが発生しない。
// showsCameraControls = true で標準カメラUI（ズーム・タップフォーカス等）をすべて維持。
// cameraOverlayView で「完了」ボタンを標準UIの上に重ねる。

class CameraBatchCapture: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    static let shared = CameraBatchCapture()

    private var images: [UIImage] = []
    private var completion: (([UIImage]) -> Void)?
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    /// dismiss → re-present の隙間を隠すスナップショット
    private var snapshotView: UIView?

    /// カメラを起動して連続撮影を開始する
    /// - Parameter completion: 撮影完了時に呼ばれる（撮影画像の配列。0枚ならキャンセル）
    func start(completion: @escaping ([UIImage]) -> Void) {
        self.images = []
        self.completion = completion
        AppLogger.camera.info("カメラ起動")
        presentPicker()
    }

    // MARK: - UIKit 表示

    private func presentPicker() {
        guard let topVC = Self.topViewController() else { return }

        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        picker.modalPresentationStyle = .fullScreen
        picker.cameraOverlayView = buildOverlay()

        topVC.present(picker, animated: images.isEmpty)
    }

    private static func topViewController() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let rootVC = windowScene.windows.first?.rootViewController else {
            return nil
        }
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        return topVC
    }

    /// picker の見た目のスナップショットを window に貼り、dismiss 中の CardListView 露出を隠す
    private func coverWithSnapshot(from picker: UIImagePickerController) {
        guard let window = picker.view.window else { return }
        // picker の現在の画面をスナップショットとしてキャプチャ
        if let snapshot = picker.view.snapshotView(afterScreenUpdates: false) {
            snapshot.frame = window.bounds
            window.addSubview(snapshot)
            snapshotView = snapshot
        }
    }

    private func removeSnapshot() {
        snapshotView?.removeFromSuperview()
        snapshotView = nil
    }

    // MARK: - UIImagePickerControllerDelegate

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        if let image = info[.originalImage] as? UIImage,
           let data = image.jpegData(compressionQuality: 0.8),
           let compressed = UIImage(data: data) {
            images.append(compressed)
            haptic.impactOccurred()
        }
        // dismiss 前にスナップショットを window に貼る → CardListView が見えない
        coverWithSnapshot(from: picker)
        picker.dismiss(animated: false) { [weak self] in
            self?.presentPicker()
            // present のアニメーション完了を待ってからスナップショットを除去
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.05))
                self?.removeSnapshot()
            }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        let captured = images
        let handler = completion
        images = []
        completion = nil

        removeSnapshot()
        picker.dismiss(animated: true) {
            handler?(captured)
        }
    }

    /// オーバーレイの「完了」ボタンから呼ばれる
    @objc private func finishCapture() {
        haptic.impactOccurred()
        AppLogger.camera.info("撮影完了: \(self.images.count, privacy: .public)枚")
        let captured = images
        let handler = completion
        images = []
        completion = nil

        removeSnapshot()

        guard let topVC = Self.topViewController(),
              topVC is UIImagePickerController else {
            handler?(captured)
            return
        }

        topVC.dismiss(animated: true) {
            handler?(captured)
        }
    }

    // MARK: - オーバーレイ構築

    private func buildOverlay() -> UIView {
        // iOS 26.0+ では UIScreen.main が非推奨のため、windowScene 経由で取得
        let screen: CGRect
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            screen = windowScene.screen.bounds
        } else {
            // フォールバック: 通常は起こらないが、万が一のためデフォルト値
            screen = CGRect(x: 0, y: 0, width: 390, height: 844)
        }
        let overlay = PassthroughView(frame: screen)
        overlay.backgroundColor = .clear

        let count = images.count

        // 「完了」ボタン（1枚以上撮影時のみ表示）
        // 左上に配置（標準カメラUIと干渉しない位置）
        if count > 0 {
            let doneButton = UIButton(type: .system)
            doneButton.setTitle("完了（\(count)枚）", for: .normal)
            var config = UIButton.Configuration.filled()
            config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.5)
            config.baseForegroundColor = .systemYellow
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
                var attr = attr
                attr.font = UIFont.systemFont(ofSize: 16, weight: .bold)
                return attr
            }
            doneButton.configuration = config
            doneButton.sizeToFit()
            let safeTop = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.windows.first?.safeAreaInsets.top ?? 54
            // HIG: ヒット領域は最低 44x44pt
            let buttonWidth = max(doneButton.frame.width, 44)
            let buttonHeight: CGFloat = 44
            doneButton.frame = CGRect(
                x: 16,
                y: safeTop + 4,
                width: buttonWidth,
                height: buttonHeight
            )
            doneButton.accessibilityLabel = "撮影完了、\(count)枚撮影済み"
            doneButton.addTarget(self, action: #selector(finishCapture), for: .touchUpInside)
            overlay.addSubview(doneButton)
        }

        return overlay
    }
}

// MARK: - タッチパススルー View

/// 自身へのタッチは下層（標準カメラUI）に透過し、サブビュー（ボタン等）のみタッチを受け取る
private class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
