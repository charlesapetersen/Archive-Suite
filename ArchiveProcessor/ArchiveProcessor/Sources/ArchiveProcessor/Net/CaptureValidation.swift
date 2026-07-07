import Foundation

/// Shared validation for the phone→Mac capture protocol. Group ids become path components in the
/// session/staging folders, so both receivers (`CaptureServer`, `FileRelayReceiver`) must restrict them
/// to a safe charset (no path separators, no "..") to prevent traversal/overwrite outside the session
/// dir — `CaptureSession.ingest` interpolates the group id straight into a path with no validation of
/// its own. One shared predicate means the two receivers can't drift.
enum CaptureValidation {
    static func isSafeGroupId(_ s: String) -> Bool {
        guard s.count <= 128, !s.contains("..") else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}
