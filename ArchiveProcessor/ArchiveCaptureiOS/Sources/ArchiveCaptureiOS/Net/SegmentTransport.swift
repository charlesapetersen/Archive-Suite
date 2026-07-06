import Foundation

/// The narrow phone→Mac transfer surface the durable upload queue depends on, abstracted so a
/// non-HTTP transport (the planned Google Drive cloud relay) can be dropped in without touching the
/// queue, retry, dedup, or capture logic. `MacClient` (direct HTTP to the Mac's `CaptureServer`) is
/// the default implementation; `DriveRelayTransport` will be a second one.
///
/// These are exactly the methods `CaptureViewModel` invokes on its stored `client`. Pairing-time
/// reachability classification stays on the concrete `MacClient` for now (it is HTTP-specific); it
/// joins this protocol when the cloud transport needs a generic connect preflight.
///
/// Contract every implementation MUST uphold (the "never lose a photo" invariant): `postPhoto`
/// returns `true` ONLY once the Mac holds the bytes durably (idempotent on `(group, seq)`), so the
/// queue marks an item UPLOADED — and drops the phone's only copy — solely on a confirmed `true`.
protocol SegmentTransport {
    /// Deliver one page's JPEG with its grouping + minimal-tag metadata. `true` = durably received.
    func postPhoto(jpeg: Data, group: String, seq: Int, type: String,
                   priority: String?, year: Int?, month: Int?, device: String,
                   replaces: String?) async -> Bool

    /// Signal that a document segment is complete and carry its tags (no image bytes). Idempotent.
    func segmentComplete(group: String, priority: String?, year: Int?, month: Int?) async -> Bool

    /// Signal the capture session is finished (flush any still-open segment on the Mac).
    func sessionComplete() async -> Bool

    /// Best-effort notice that the phone is re-pairing, so the Mac can re-show its pairing QR.
    func sessionDisconnect() async -> Bool
}

extension MacClient: SegmentTransport {}
