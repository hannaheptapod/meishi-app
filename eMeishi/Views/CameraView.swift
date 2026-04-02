import SwiftUI
import UIKit

// 連続撮影カメラ（UIKit のみで管理）
// fullScreenCover を使わず、UIKit の present/dismiss だけでカメラを表示・解除する。
// SwiftUI のモーダルシステムを一切経由しないため、dismiss 競合によるフリーズが発生しない。
// showsCameraControls = true で標準カメラUI（ズーム・タップフォーカス等）をすべて維持。
// cameraOverlayView で撮影枚数カウンター + 「完了」ボタンを標準UIの上に重ねる。

class CameraBatchCapture: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    static let shared = CameraBatchCapture()

    private var images: [UIImage] = []
    private var completion: (([UIImage]) -> Void)?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// カメラを起動して連続撮影を開始する
    /// - Parameter completion: 撮影完了時に呼ばれる（撮影画像の配列。0枚ならキャンセル）
    func start(completion: @escaping ([UIImage]) -> Void) {
        self.images = []
        self.completion = completion
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

    // MARK: - UIImagePickerControllerDelegate

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        if let image = info[.originalImage] as? UIImage {
            images.append(image)
        }
        // dismiss → 即 re-present（連続撮影）
        picker.dismiss(animated: false) { [weak self] in
            self?.presentPicker()
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        let captured = images
        let handler = completion
        images = []
        completion = nil

        picker.dismiss(animated: true) {
            handler?(captured)
        }
    }

    /// オーバーレイの「完了」ボタンから呼ばれる
    @objc private func finishCapture() {
        let captured = images
        let handler = completion
        images = []
        completion = nil

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
        let screen = UIScreen.main.bounds
        let overlay = PassthroughView(frame: screen)
        overlay.backgroundColor = .clear

        let count = images.count

        // 撮影済みカウンター（上部中央）
        if count > 0 {
            let badge = UILabel()
            badge.text = "  \(count)枚撮影済み  "
            badge.font = .systemFont(ofSize: 14, weight: .semibold)
            badge.textColor = .white
            badge.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            badge.textAlignment = .center
            badge.layer.cornerRadius = 14
            badge.clipsToBounds = true
            badge.sizeToFit()
            badge.frame = CGRect(
                x: (screen.width - badge.frame.width - 16) / 2,
                y: 60,
                width: badge.frame.width + 16,
                height: 28
            )
            overlay.addSubview(badge)
        }

        // 「完了」ボタン（上部右寄り・1枚以上撮影時のみ表示）
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
            doneButton.frame = CGRect(
                x: screen.width - doneButton.frame.width - 16,
                y: 54,
                width: doneButton.frame.width,
                height: 36
            )
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
