import SwiftUI
import AVFoundation

/// Full-screen QR scanner for pairing. Calls `onCode` once with the first QR payload it reads.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.metadataDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (String) -> Void
        private var handled = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !handled,
                  let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  obj.type == .qr, let value = obj.stringValue else { return }
            handled = true
            DispatchQueue.main.async { self.onCode(value) }
        }
    }

    final class ScannerVC: UIViewController {
        weak var metadataDelegate: AVCaptureMetadataOutputObjectsDelegate?
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var bgObserver: NSObjectProtocol?
        private var fgObserver: NSObjectProtocol?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    // Denied (now or earlier) used to leave a black sheet with nothing on it.
                    if granted { self.configure() } else { self.showUnavailable(Self.deniedText, settings: true) }
                }
            }
            bgObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.global(qos: .userInitiated).async { if self.session.isRunning { self.session.stopRunning() } }
            }
            fgObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.global(qos: .userInitiated).async { if !self.session.isRunning { self.session.startRunning() } }
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                showUnavailable("This device's camera can't be used to scan. Close this and enter the details by hand instead.", settings: false)
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(metadataDelegate, queue: .main)
                output.metadataObjectTypes = [.qr]
            }
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            previewLayer = preview
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        static let deniedText = "Camera access is off, so the Mac's QR code can't be scanned. Allow it in Settings, or close this and enter the details by hand."

        /// A message (and, for a denial, a way to Settings) in place of the preview that can't run.
        private func showUnavailable(_ text: String, settings: Bool) {
            let label = UILabel()
            label.text = text
            label.textColor = .white
            label.textAlignment = .center
            label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            let stack = UIStackView(arrangedSubviews: [label])
            stack.axis = .vertical
            stack.spacing = 16
            stack.alignment = .center
            if settings {
                var config = UIButton.Configuration.filled()
                config.title = "Open Settings"
                stack.addArrangedSubview(UIButton(configuration: config, primaryAction: UIAction { _ in
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }))
            }
            stack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -16),
            ])
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if let bg = bgObserver { NotificationCenter.default.removeObserver(bg) }
            if let fg = fgObserver { NotificationCenter.default.removeObserver(fg) }
            DispatchQueue.global(qos: .userInitiated).async { if self.session.isRunning { self.session.stopRunning() } }
        }
    }
}
