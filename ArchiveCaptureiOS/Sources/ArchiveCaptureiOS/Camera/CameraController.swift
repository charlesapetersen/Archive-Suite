import AVFoundation
import UIKit

/// Back-camera photo capture for the capture screen. Session work runs on a dedicated serial queue;
/// the JPEG data is delivered back on the main thread.
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.archiveprocessor.capture.camera")
    private var configured = false
    private var captureCompletion: ((Data?) -> Void)?

    @Published var authorized = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
            queue.async { self.configureIfNeeded(); self.startRunning() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { self.authorized = granted }
                guard granted else { return }
                self.queue.async { self.configureIfNeeded(); self.startRunning() }
            }
        default:
            DispatchQueue.main.async { self.authorized = false }
        }
    }

    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

    private func configureIfNeeded() {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()
        configured = true
    }

    private func startRunning() { if !session.isRunning { session.startRunning() } }

    /// Capture a full-resolution JPEG; `completion` is called on the main thread (nil on failure).
    func capturePhoto(_ completion: @escaping (Data?) -> Void) {
        queue.async {
            guard self.configured else { DispatchQueue.main.async { completion(nil) }; return }
            self.captureCompletion = completion
            self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        let completion = captureCompletion
        captureCompletion = nil
        DispatchQueue.main.async { completion?(data) }
    }
}
