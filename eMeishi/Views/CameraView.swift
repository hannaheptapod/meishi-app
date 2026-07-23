import AVFoundation
import SwiftUI
import UIKit

/// Apple標準カメラUIを使い、最大10枚まで連続撮影する画面。
/// SwiftUIはfullScreenCoverを1つだけ所有し、撮影ごとの標準カメラ再表示は
/// cover内の固定Host View Controllerだけが管理する。
struct CameraCaptureView: View {
    let onComplete: ([CardImageInput]) -> Void
    let onCancel: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var authorizationState: CameraAuthorizationState = .checking

    var body: some View {
        Group {
            switch authorizationState {
            case .checking:
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView("カメラを準備中")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            case .authorized:
                SystemCameraBatchView(
                    maximumCaptureCount: 10,
                    onComplete: onComplete,
                    onCancel: onCancel
                )
                .ignoresSafeArea()
            case .denied:
                cameraUnavailableContent(
                    title: "カメラを使用できません",
                    description: "設定でカメラへのアクセスを許可してください。",
                    showsSettingsButton: true
                )
            case .unavailable:
                cameraUnavailableContent(
                    title: "カメラを使用できません",
                    description: "この端末ではカメラを利用できません。",
                    showsSettingsButton: false
                )
            }
        }
        .task {
            await resolveAuthorization()
        }
    }

    private func cameraUnavailableContent(
        title: String,
        description: String,
        showsSettingsButton: Bool
    ) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ContentUnavailableView {
                Label(title, systemImage: "camera.fill")
                    .foregroundStyle(.white)
            } description: {
                Text(description)
                    .foregroundStyle(.white.opacity(0.8))
            } actions: {
                HStack(spacing: AppTheme.Spacing.medium) {
                    Button("閉じる", action: onCancel)
                        .buttonStyle(.glass)
                        .tint(.white)
                    if showsSettingsButton {
                        Button("設定を開く") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            openURL(url)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.white)
                        .foregroundStyle(.black)
                    }
                }
            }
        }
    }

    private func resolveAuthorization() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            authorizationState = .unavailable
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationState = .authorized
        case .notDetermined:
            authorizationState = await AVCaptureDevice.requestAccess(for: .video)
                ? .authorized
                : .denied
        case .denied, .restricted:
            authorizationState = .denied
        @unknown default:
            authorizationState = .denied
        }
    }
}

private enum CameraAuthorizationState: Sendable {
    case checking
    case authorized
    case denied
    case unavailable
}

/// UIKitの標準カメラを、SwiftUIの単一presentation内へ閉じ込める橋渡し。
private struct SystemCameraBatchView: UIViewControllerRepresentable {
    let maximumCaptureCount: Int
    let onComplete: ([CardImageInput]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> SystemCameraBatchHostViewController {
        SystemCameraBatchHostViewController(
            maximumCaptureCount: maximumCaptureCount,
            onComplete: onComplete,
            onCancel: onCancel
        )
    }

    func updateUIViewController(
        _ controller: SystemCameraBatchHostViewController,
        context: Context
    ) {
        controller.updateCallbacks(onComplete: onComplete, onCancel: onCancel)
    }

    static func dismantleUIViewController(
        _ controller: SystemCameraBatchHostViewController,
        coordinator: Void
    ) {
        controller.stopWithoutCallback()
    }
}

/// 撮影ごとに変わらない固定Host。
/// Windowや最前面View Controllerを探索せず、このHostだけが標準カメラを再提示する。
private final class SystemCameraBatchHostViewController:
    UIViewController,
    UIImagePickerControllerDelegate,
    UINavigationControllerDelegate {

    private let maximumCaptureCount: Int
    private var capturedInputs: [CardImageInput] = []
    private var completion: ([CardImageInput]) -> Void
    private var cancellation: () -> Void
    private var isTransitioning = false
    private var isFinishing = false
    private weak var activePicker: UIImagePickerController?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    init(
        maximumCaptureCount: Int,
        onComplete: @escaping ([CardImageInput]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.maximumCaptureCount = maximumCaptureCount
        completion = onComplete
        cancellation = onCancel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentCameraIfNeeded()
    }

    func updateCallbacks(
        onComplete: @escaping ([CardImageInput]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        completion = onComplete
        cancellation = onCancel
    }

    func stopWithoutCallback() {
        isFinishing = true
        activePicker?.delegate = nil
        activePicker?.dismiss(animated: false)
        activePicker = nil
    }

    private func presentCameraIfNeeded() {
        guard !isFinishing,
              !isTransitioning,
              presentedViewController == nil,
              UIImagePickerController.isSourceTypeAvailable(.camera) else { return }

        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.showsCameraControls = true
        picker.delegate = self
        picker.modalPresentationStyle = .fullScreen
        // cameraOverlayView は frame=.zero のViewを自動では画面全体へ広げない。
        // Picker自身のboundsを初期値にし、回転・サイズ変更にも追従させる。
        picker.loadViewIfNeeded()
        picker.cameraOverlayView = makeCameraOverlay(
            capturedCount: capturedInputs.count,
            frame: picker.view.bounds
        )
        activePicker = picker
        present(picker, animated: capturedInputs.isEmpty)
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        guard !isFinishing else { return }
        guard let image = info[.originalImage] as? UIImage,
              let data = image.jpegData(compressionQuality: 0.92) else {
            dismissPicker(picker) { [weak self] in
                self?.showCaptureError()
            }
            return
        }

        capturedInputs.append(CardImageInput(data: data, source: .camera))
        haptic.impactOccurred()
        dismissPicker(picker) { [weak self] in
            guard let self else { return }
            if capturedInputs.count >= maximumCaptureCount {
                finishWithCapturedImages()
            } else {
                presentCameraIfNeeded()
            }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        guard !isFinishing else { return }
        dismissPicker(picker) { [weak self] in
            guard let self else { return }
            if capturedInputs.isEmpty {
                finishByCancelling()
            } else {
                finishWithCapturedImages()
            }
        }
    }

    @objc private func finishButtonTapped() {
        guard !capturedInputs.isEmpty, !isFinishing else { return }
        if let activePicker {
            dismissPicker(activePicker) { [weak self] in
                self?.finishWithCapturedImages()
            }
        } else {
            finishWithCapturedImages()
        }
    }

    private func dismissPicker(
        _ picker: UIImagePickerController,
        completion: @escaping () -> Void
    ) {
        isTransitioning = true
        picker.delegate = nil
        picker.dismiss(animated: false) { [weak self] in
            guard let self else { return }
            if activePicker === picker {
                activePicker = nil
            }
            isTransitioning = false
            completion()
        }
    }

    private func finishWithCapturedImages() {
        guard !isFinishing, !capturedInputs.isEmpty else { return }
        isFinishing = true
        let inputs = capturedInputs
        capturedInputs = []
        completion(inputs)
    }

    private func finishByCancelling() {
        guard !isFinishing else { return }
        isFinishing = true
        capturedInputs = []
        cancellation()
    }

    private func showCaptureError() {
        guard !isFinishing else { return }
        let alert = UIAlertController(
            title: "撮影できませんでした",
            message: "画像を保存できませんでした。もう一度お試しください。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.presentCameraIfNeeded()
        })
        present(alert, animated: true)
    }

    private func makeCameraOverlay(capturedCount: Int, frame: CGRect) -> UIView {
        let overlay = CameraPassthroughView(frame: frame)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = .clear

        guard capturedCount > 0 else { return overlay }

        let countLabel = UILabel()
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.text = "\(capturedCount) / \(maximumCaptureCount)枚"
        countLabel.font = .preferredFont(forTextStyle: .subheadline)
        countLabel.textColor = .white
        countLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        countLabel.textAlignment = .center
        countLabel.layer.cornerRadius = 15
        countLabel.clipsToBounds = true
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let finishButton = UIButton(type: .system)
        finishButton.translatesAutoresizingMaskIntoConstraints = false
        var configuration = UIButton.Configuration.prominentGlass()
        configuration.title = "完了"
        configuration.baseForegroundColor = UIColor.white
        finishButton.configuration = configuration
        finishButton.addTarget(self, action: #selector(finishButtonTapped), for: .touchUpInside)

        overlay.addSubview(countLabel)
        overlay.addSubview(finishButton)
        NSLayoutConstraint.activate([
            countLabel.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 12),
            countLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            countLabel.heightAnchor.constraint(equalToConstant: 30),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            finishButton.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            finishButton.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
        return overlay
    }
}

/// 標準カメラへのタッチを維持し、追加した完了ボタンだけが入力を受け取る。
private final class CameraPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        return hitView === self ? nil : hitView
    }
}
