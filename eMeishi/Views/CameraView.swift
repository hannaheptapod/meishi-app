import AVFoundation
import Combine
import os
import SwiftUI
import UIKit

/// 1つのfullScreenCover内で撮影セッションを維持する連続撮影画面。
/// 撮影ごとのdismiss/presentを行わないため、SwiftUIのpresentationと競合しない。
struct CameraCaptureView: View {
    let onComplete: ([CardImageInput]) -> Void
    let onCancel: () -> Void

    @StateObject private var model = CameraCaptureViewModel()
    @State private var rotationAngle: CGFloat = 90
    @State private var isFinishing = false
    @State private var finishTask: Task<Void, Never>?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// 権限ダイアログではsceneが一時的にinactiveになるが、これはカメラ画面の
    /// 終了やbackground移行ではない。active/inactiveを同じTask IDへ正規化し、
    /// `requestAccess`待機中の起動Taskをキャンセルしない。
    private var cameraLifecycleActivity: CameraLifecycleActivity {
        switch scenePhase {
        case .active, .inactive:
            .foreground
        case .background:
            .background
        @unknown default:
            .background
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.isPermissionDenied {
                permissionDeniedContent
            } else {
                CameraPreviewView(
                    session: model.session,
                    rotationAngle: $rotationAngle
                )
                .ignoresSafeArea()

                if !model.isReady {
                    ProgressView("カメラを準備中")
                        .tint(.white)
                        .foregroundStyle(.white)
                }

                cameraControls
            }
        }
        // foreground/backgroundの2値をIDにした構造化Taskだけを起動経路にする。
        // 権限ダイアログのinactiveではTaskを作り直さず、実backgroundだけで停止する。
        .task(id: cameraLifecycleActivity) {
            switch cameraLifecycleActivity {
            case .foreground:
                await model.start()
            case .background:
                model.stop()
            }
        }
        .onDisappear {
            finishTask?.cancel()
            finishTask = nil
            model.stop()
        }
        .alert(
            "撮影できませんでした",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .statusBarHidden()
    }

    private var cameraControls: some View {
        VStack {
            HStack(spacing: AppTheme.Spacing.medium) {
                Button(action: cancelCapture) {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .tint(.white)
                .disabled(isFinishing)
                .accessibilityLabel("撮影をキャンセル")

                Spacer()

                if model.captureCount > 0 {
                    Button {
                        finishCapture()
                    } label: {
                        Text("完了（\(model.captureCount)枚）")
                            .font(.headline)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .disabled(isFinishing || model.isCapturing)
                    .accessibilityLabel("撮影完了、\(model.captureCount)枚撮影済み")
                }
            }
            .padding(.horizontal, AppTheme.Spacing.large)
            .padding(.top, AppTheme.Spacing.medium)

            Spacer()

            VStack(spacing: AppTheme.Spacing.medium) {
                if model.isCapturing {
                    ProgressView("画像を準備中")
                        .tint(.white)
                        .foregroundStyle(.white)
                } else if model.captureCount > 0 {
                    Text("\(model.captureCount) / \(CameraCaptureViewModel.maximumCaptureCount)枚")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, AppTheme.Spacing.medium)
                        .padding(.vertical, AppTheme.Spacing.small)
                        .background(.black.opacity(0.45), in: .capsule)
                }

                Button {
                    model.capture(rotationAngle: rotationAngle)
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 76, height: 76)
                        Circle()
                            .fill(.white)
                            .frame(width: 64, height: 64)
                    }
                    .frame(width: 88, height: 88)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(
                    !model.isReady
                        || model.isCapturing
                        || isFinishing
                        || model.captureCount >= CameraCaptureViewModel.maximumCaptureCount
                )
                .opacity(model.isReady && !model.isCapturing && !isFinishing ? 1 : 0.55)
                .accessibilityLabel("撮影")
                .accessibilityHint("名刺を1枚撮影します")
            }
            .padding(.bottom, AppTheme.Spacing.xLarge)
        }
    }

    private var permissionDeniedContent: some View {
        ContentUnavailableView {
            Label("カメラを使用できません", systemImage: "camera.fill")
                .foregroundStyle(.white)
        } description: {
            Text("設定でカメラへのアクセスを許可してください。")
                .foregroundStyle(.white.opacity(0.8))
        } actions: {
            HStack(spacing: AppTheme.Spacing.medium) {
                Button("閉じる", action: cancelCapture)
                    .buttonStyle(.glass)
                    .tint(.white)
                    .disabled(isFinishing)
                Button("設定を開く") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
                .buttonStyle(.glassProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .disabled(isFinishing)
            }
        }
    }

    private func finishCapture() {
        guard !isFinishing, !model.isCapturing, model.captureCount > 0 else { return }
        let inputs = model.capturedInputs
        isFinishing = true
        finishTask = Task {
            await model.stopAndWait()
            guard !Task.isCancelled else { return }
            onComplete(inputs)
            finishTask = nil
        }
    }

    private func cancelCapture() {
        guard !isFinishing else { return }
        isFinishing = true
        finishTask = Task {
            await model.stopAndWait()
            guard !Task.isCancelled else { return }
            onCancel()
            finishTask = nil
        }
    }
}

nonisolated enum CameraLifecycleActivity: Hashable, Sendable {
    case foreground
    case background
}

@MainActor
private final class CameraCaptureViewModel: ObservableObject {
    static let maximumCaptureCount = 10

    @Published private(set) var capturedInputs: [CardImageInput] = []
    @Published private(set) var isReady = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isPermissionDenied = false
    @Published var errorMessage: String?

    let session: AVCaptureSession

    private let worker: CameraSessionWorker
    private let imageProcessor = CardImageProcessingService.shared
    private var lifecycleID: UUID?
    private var isStarting = false
    private var stopTask: Task<Void, Never>?
    private var stopID: UUID?
    private var captureTask: Task<Void, Never>?
    private var captureID: UUID?

    init() {
        let handle = CameraSessionHandle()
        session = handle.session
        worker = CameraSessionWorker(handle: handle)
    }

    var captureCount: Int { capturedInputs.count }

    func start() async {
        guard !Task.isCancelled, !isReady, !isStarting else { return }
        isStarting = true
        let currentLifecycleID = UUID()
        lifecycleID = currentLifecycleID
        defer {
            if lifecycleID == currentLifecycleID {
                isStarting = false
            }
        }

        if let stopTask {
            await stopTask.value
            self.stopTask = nil
            self.stopID = nil
            guard !Task.isCancelled,
                  lifecycleID == currentLifecycleID else { return }
        }

        let isAuthorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
        case .notDetermined:
            isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            isAuthorized = false
        @unknown default:
            isAuthorized = false
        }

        guard isAuthorized else {
            guard lifecycleID == currentLifecycleID else { return }
            isPermissionDenied = true
            return
        }

        guard !Task.isCancelled,
              lifecycleID == currentLifecycleID else { return }

        do {
            try await worker.start()
            guard !Task.isCancelled,
                  lifecycleID == currentLifecycleID else {
                await worker.stop()
                return
            }
            isReady = true
            isPermissionDenied = false
            errorMessage = nil
            AppLogger.camera.info("カメラ起動")
        } catch {
            guard lifecycleID == currentLifecycleID else { return }
            errorMessage = error.localizedDescription
        }
    }

    func capture(rotationAngle: CGFloat) {
        guard isReady,
              !isCapturing,
              capturedInputs.count < Self.maximumCaptureCount else {
            return
        }

        guard let currentLifecycleID = lifecycleID else { return }
        let currentCaptureID = UUID()
        captureID = currentCaptureID
        isCapturing = true
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if captureID == currentCaptureID {
                    captureID = nil
                    captureTask = nil
                    isCapturing = false
                }
            }
            do {
                let data = try await worker.capturePhoto(rotationAngle: rotationAngle)
                try Task.checkCancellation()
                guard lifecycleID == currentLifecycleID else { return }
                let input = try await imageProcessor.prepareInput(
                    from: data,
                    source: .camera
                )
                try Task.checkCancellation()
                guard lifecycleID == currentLifecycleID else { return }
                capturedInputs.append(input)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch is CancellationError {
                return
            } catch {
                if case CameraCaptureError.captureCancelled = error {
                    return
                }
                guard lifecycleID == currentLifecycleID,
                      captureID == currentCaptureID else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        lifecycleID = nil
        isStarting = false
        isReady = false
        captureID = nil
        captureTask?.cancel()
        captureTask = nil
        isCapturing = false
        if stopTask == nil {
            let currentStopID = UUID()
            stopID = currentStopID
            stopTask = Task {
                await worker.stop()
            }
        }
    }

    /// 次のカメラ画面を開く前にAVCaptureSessionの停止完了を保証する。
    func stopAndWait() async {
        stop()
        guard let task = stopTask else { return }
        let currentStopID = stopID
        await task.value
        if stopID == currentStopID {
            stopTask = nil
            stopID = nil
        }
    }
}

/// AVCaptureSessionはSendableではないが、変更はCameraSessionWorkerだけが行う。
/// MainActor側ではAVCaptureVideoPreviewLayerへの参照設定だけを行う。
nonisolated private final class CameraSessionHandle: @unchecked Sendable {
    let session = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()
}

private actor CameraSessionWorker {
    nonisolated let handle: CameraSessionHandle

    private var isConfigured = false
    private var photoDelegates: [UUID: CameraPhotoDelegate] = [:]

    init(handle: CameraSessionHandle) {
        self.handle = handle
    }

    func start() throws {
        if !isConfigured {
            try configure()
            isConfigured = true
        }
        if !handle.session.isRunning {
            handle.session.startRunning()
        }
    }

    func stop() {
        if handle.session.isRunning {
            handle.session.stopRunning()
        }
        let delegates = Array(photoDelegates.values)
        photoDelegates.removeAll()
        for delegate in delegates {
            delegate.cancel()
        }
    }

    func capturePhoto(rotationAngle: CGFloat) async throws -> Data {
        guard handle.session.isRunning else {
            throw CameraCaptureError.sessionNotRunning
        }

        if let connection = handle.photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }

        let identifier = UUID()
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = CameraPhotoDelegate { [weak self] result in
                continuation.resume(with: result)
                Task {
                    await self?.releasePhotoDelegate(identifier: identifier)
                }
            }
            photoDelegates[identifier] = delegate
            handle.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private func configure() throws {
        let session = handle.session
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        do {
            session.sessionPreset = .photo
            guard let camera = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ) else {
                throw CameraCaptureError.cameraUnavailable
            }

            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                throw CameraCaptureError.cannotConfigureInput
            }
            session.addInput(input)

            guard session.canAddOutput(handle.photoOutput) else {
                throw CameraCaptureError.cannotConfigureOutput
            }
            session.addOutput(handle.photoOutput)
            handle.photoOutput.maxPhotoQualityPrioritization = .quality
        } catch {
            // 入力だけ追加された途中状態を残すと、次回start()の再試行も失敗する。
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            throw error
        }
    }

    private func releasePhotoDelegate(identifier: UUID) {
        photoDelegates[identifier] = nil
    }
}

nonisolated private final class CameraPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Result<Data, Error>) -> Void
    private let lock = NSLock()
    private var hasCompleted = false

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            finish(with: .failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            finish(with: .failure(CameraCaptureError.invalidImage))
            return
        }
        finish(with: .success(data))
    }

    func cancel() {
        finish(with: .failure(CameraCaptureError.captureCancelled))
    }

    private func finish(with result: Result<Data, Error>) {
        lock.lock()
        guard !hasCompleted else {
            lock.unlock()
            return
        }
        hasCompleted = true
        lock.unlock()
        completion(result)
    }
}

nonisolated private enum CameraCaptureError: LocalizedError, Sendable {
    case cameraUnavailable
    case cannotConfigureInput
    case cannotConfigureOutput
    case sessionNotRunning
    case invalidImage
    case captureCancelled

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            "この端末ではカメラを使用できません。"
        case .cannotConfigureInput, .cannotConfigureOutput:
            "カメラを初期化できませんでした。"
        case .sessionNotRunning:
            "カメラの準備が完了していません。"
        case .invalidImage:
            "撮影した画像を読み込めませんでした。"
        case .captureCancelled:
            "撮影を中止しました。"
        }
    }
}

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @Binding var rotationAngle: CGFloat

    func makeUIView(context: Context) -> CameraPreviewLayerView {
        let view = CameraPreviewLayerView()
        view.setSession(session)
        view.onRotationAngleChanged = { angle in
            if rotationAngle != angle {
                rotationAngle = angle
            }
        }
        return view
    }

    func updateUIView(_ view: CameraPreviewLayerView, context: Context) {
        view.setSession(session)
        view.onRotationAngleChanged = { angle in
            if rotationAngle != angle {
                rotationAngle = angle
            }
        }
        view.updateRotation()
    }
}

@MainActor
private final class CameraPreviewLayerView: UIView {
    var onRotationAngleChanged: ((CGFloat) -> Void)?
    private var lastRotationAngle: CGFloat?

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configurePreviewLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePreviewLayer()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateRotation()
    }

    func updateRotation() {
        guard let previewLayer = layer as? AVCaptureVideoPreviewLayer else {
            AppLogger.camera.fault("カメラプレビューレイヤーの型が不正です")
            return
        }

        let angle = switch window?.windowScene?.effectiveGeometry.interfaceOrientation {
        case .portrait:
            CGFloat(90)
        case .portraitUpsideDown:
            CGFloat(270)
        case .landscapeLeft:
            CGFloat(180)
        case .landscapeRight:
            CGFloat(0)
        default:
            CGFloat(90)
        }

        if let connection = previewLayer.connection,
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        guard lastRotationAngle != angle else { return }
        lastRotationAngle = angle
        Task { @MainActor [weak self] in
            self?.onRotationAngleChanged?(angle)
        }
    }

    func setSession(_ session: AVCaptureSession) {
        guard let previewLayer = layer as? AVCaptureVideoPreviewLayer else {
            AppLogger.camera.fault("カメラプレビューレイヤーへセッションを設定できません")
            return
        }
        previewLayer.session = session
    }

    private func configurePreviewLayer() {
        guard let previewLayer = layer as? AVCaptureVideoPreviewLayer else {
            AppLogger.camera.fault("カメラプレビューレイヤーを初期化できません")
            return
        }
        previewLayer.videoGravity = .resizeAspectFill
    }
}
