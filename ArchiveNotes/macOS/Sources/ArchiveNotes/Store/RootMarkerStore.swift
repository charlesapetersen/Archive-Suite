import Foundation
import ArchiveCore

/// Ensures a `.archive-suite-root.json` RootMarker exists at the store root.
///
/// Idempotent: if the marker already decodes, returns it unchanged (preserves the
/// GUID across launches and moved installs). If missing, writes a fresh marker
/// atomically. If present but corrupt (non-empty, fails decode), throws rather
/// than silently minting a new GUID (which would break every durable link).
enum RootMarkerStore {

    enum MarkerError: Error, Sendable {
        case corruptRootMarker(URL)
    }

    static func ensureMarker(at root: URL, kind: RootKind) throws -> RootMarker {
        let markerURL = root.appendingPathComponent(RootMarker.filename)
        let fm = FileManager.default

        if fm.fileExists(atPath: markerURL.path) {
            guard let data = fm.contents(atPath: markerURL.path) else {
                throw MarkerError.corruptRootMarker(markerURL)
            }

            // Empty file: treat as absent and write fresh.
            if data.isEmpty {
                return try writeFresh(at: markerURL, root: root, kind: kind)
            }

            // Non-empty: must decode or it's corrupt.
            do {
                return try JSONDecoder().decode(RootMarker.self, from: data)
            } catch {
                throw MarkerError.corruptRootMarker(markerURL)
            }
        }

        return try writeFresh(at: markerURL, root: root, kind: kind)
    }

    private static func writeFresh(at url: URL, root: URL, kind: RootKind) throws -> RootMarker {
        let marker = RootMarker(
            guid: UUID(),
            name: root.lastPathComponent,
            kind: kind,
            createdAt: Date()
        )
        let data = try JSONEncoder().encode(marker)
        try data.write(to: url, options: [.atomic])
        return marker
    }
}
