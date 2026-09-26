import Foundation
import ArchiveCore

/// Ensures a `.archive-suite-root.json` RootMarker exists at the store root.
///
/// Idempotent: if the marker already decodes, returns it unchanged (preserves the
/// GUID across launches and moved installs). If missing, creates it through
/// ArchiveCore's coordinated, read-back-confirmed writer. If present but corrupt,
/// throws rather than silently minting a new GUID (which would break durable links).
enum RootMarkerStore {

    enum MarkerError: Error, Sendable {
        case corruptRootMarker(URL)
    }

    static func ensureMarker(at root: URL, kind: RootKind) throws -> RootMarker {
        do {
            return try RootMarker.ensure(at: root, kind: kind, name: root.lastPathComponent)
        } catch let error as RootMarkerError {
            throw markerError(for: error)
        }
    }

    private static func markerError(for error: RootMarkerError) -> MarkerError {
        switch error {
        case let .malformed(url, _), let .unreadable(url, _), let .readOnly(url, _, _):
            MarkerError.corruptRootMarker(url)
        }
    }
}
