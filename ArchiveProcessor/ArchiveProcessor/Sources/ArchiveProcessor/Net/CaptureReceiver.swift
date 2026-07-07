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

/// Which receiver the Live Capture session runs. Persisted via `DefaultsKeys.liveTransport`
/// (String-backed — appending cases is safe; never rename an existing rawValue, per the CLAUDE.md
/// shared-hotspot rule for persisted enums).
enum CaptureTransport: String {
    case lan        // CaptureServer — direct HTTP on the LAN (default; behavior unchanged)
    case fileRelay  // FileRelayReceiver — a local shared directory (the offline contract fixture)
    case cloud      // Google Drive relay (not yet built)
}
