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

    /// The companion protocol has no migration aliases: an omitted value means Unrated, while a
    /// present value must be one of its three canonical Quality tokens. Q0 is Mac-internal only.
    static func isWireQuality(_ raw: String?) -> Bool {
        guard let raw else { return true }
        return ["Q1", "Q2", "Q3"].contains(raw)
    }
}
