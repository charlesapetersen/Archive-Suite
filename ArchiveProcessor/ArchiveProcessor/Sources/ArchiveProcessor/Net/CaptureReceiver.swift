import Foundation

/// A receiver that accepts captured pages from a phone companion and funnels them into
/// `CaptureSession.ingest(...)`, acking only on a durable (non-nil) result. `CaptureServer` (direct
/// HTTP over `NWListener`) is the LAN receiver; `FileRelayReceiver` (a watched shared directory) is the
/// relay receiver the Google Drive backend later generalizes. Every receiver upholds the
/// "never lose a photo" contract: it acks / deletes a source object only after `ingest` returned non-nil.
protocol CaptureReceiver: AnyObject, Sendable {
    func start()
    func stop()
}

/// Which single receiver a session runs under the CI/test override `LIVECAPTURE_TRANSPORT` only. There is
/// no user-facing transport setting (A5 removed the picker): production runs LAN + Drive together, chosen
/// in `CaptureSession.start()`. String-backed — appending cases is safe; never rename an existing rawValue.
enum CaptureTransport: String {
    case lan        // CaptureServer — direct HTTP on the LAN
    case fileRelay  // FileRelayReceiver — a local shared directory (the offline contract fixture)
    case cloud      // Google Drive relay
}
