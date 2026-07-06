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

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { granted in
                guard granted else { return }
                DispatchQueue.main.async { self.configure() }
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
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

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            DispatchQueue.global(qos: .userInitiated).async { if self.session.isRunning { self.session.stopRunning() } }
        }
    }
}
