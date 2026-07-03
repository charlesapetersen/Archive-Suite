import AVFoundation
import UIKit

/// Back-camera photo capture for the capture screen. Session work runs on a dedicated serial queue;
/// the JPEG data is delivered back on the main thread.
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.archiveprocessor.capture.camera")
    private var configured = false
    private var hasVideoInput = false
    /// Completions keyed by AVFoundation's per-request unique ID so overlapping captures never collide
    /// (a shared single completion could be overwritten by a rapid second tap → a silently dropped page).
    /// Only ever touched on `queue`, so there's no cross-queue data race.
    private var completions: [Int64: (Data?) -> Void] = [:]

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
            hasVideoInput = true
        }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()
        configured = true
    }

    private func startRunning() { if !session.isRunning { session.startRunning() } }

    /// Capture a full-resolution JPEG; `completion` is called on the main thread (nil on failure).
    func capturePhoto(_ completion: @escaping (Data?) -> Void) {
        queue.async {
            // Require a live video connection: capturing without one throws NSInvalidArgumentException
            // (a hard crash) rather than failing gracefully, so convert that to completion(nil).
            guard self.configured, self.hasVideoInput,
                  self.photoOutput.connection(with: .video)?.isActive == true else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            let settings = AVCapturePhotoSettings()
            self.completions[settings.uniqueID] = completion
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        let id = photo.resolvedSettings.uniqueID
        // Confine all access to `completions` to `queue` — the delegate fires on AVFoundation's private queue.
        queue.async {
            let completion = self.completions.removeValue(forKey: id)
            DispatchQueue.main.async { completion?(data) }
        }
    }
}
